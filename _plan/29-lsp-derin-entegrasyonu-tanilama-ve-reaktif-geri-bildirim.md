# 29 — LSP Derin Entegrasyonu, Gerçek Zamanlı Tanılama (Diagnostics) ve Reaktif Geri Bildirim Mimarisi

**Durum:** 📋 **Planlandı** · **Zorluk:** Zor · **Öneri kaynağı:** Kullanıcı Geri Bildirimi & Mimari İstişare · **Faz:** 5 (Reaktif Çalışma Zamanı & Akıllı Geri Bildirim)  
**İlgili Planlar:** [06 — AST Semantik İndeks](06-ast-semantik-indeks.md) · [08 — Hata Ayrıştırma ve Teşhis](08-hata-ayristirma-teshis.md) · [18 — Tree-sitter & LSP](18-tree-sitter-ast-ve-lsp-entegrasyonu.md) · [22 — LLM Durumsal Farkındalık](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md) · [27 — Tampon Auto-Apply](27-tampon-kirli-durum-hatirlatici-ve-akilli-ping-sistemi.md) · [28 — Reaktif Bağlam](28-olay-gudumlu-reaktif-baglam-ast-ve-akilli-calisma-alani-agaci.md) · [Index](index.md)

---

## 🎯 1. Problem & Neden LSP? (LSP'den Ne Kazanacağız?)

Mevcut AST çözümleyicilerimiz (`Rubik::AST::Graph` & Extractor'lar) dosya iskeletini ve sembolleri **sözdizimsel (syntax-level)** olarak mükemmel ayrıştırır; ancak derleyici/tip denetleyicisi seviyesinde bilgiye sahip değildir.

Language Server Protocol (LSP) entegrasyonu ile sisteme kazandırılacak **4 temel yetenek**:

```text
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                 LSP İLE KAZANILACAK TEMEL YETENEKLER                             │
├─────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                 │
│  1. Gerçek Zamanlı Kodlama Geri Bildirimi (Live In-Buffer Diagnostics):                         │
│     • Model `write_file` ile tamponda kod yazdığı anda `textDocument/didChange` LSP'ye iletilir.│
│     • Derleyicinin ürettiği tip ve sözdizim hataları (`publishDiagnostics`) anında yakalanır.   │
│     • Model henüz testleri çalıştırmadan veya diske yazmadan önce anında uyarılır:              │
│       <lsp_diagnostics file="src/main.rs" errors="1">                                           │
│         [Error: Line 42] mismatched types: expected `String`, found `&str`                      │
│       </lsp_diagnostics>                                                                        │
│                                                                                                 │
│  2. %100 Kesin Tip ve Tanım Bilgisi (Type-Safe Hover & Definition):                             │
│     • `a.save()` çağrısında `a`'nın hangi tip olduğunu bilerek doğru sınıf tanımına gider.      │
│     • Metot parametre tipleri, struct alanları ve derleyici dokümantasyonunu (`hover`) getirir. │
│                                                                                                 │
│  3. Polimorfizm-Duyarlı Kesin Referanslar (Disambiguated References):                          │
│     • Farklı sınıflarda aynı isimli metotlar (`User#save` vs `Order#save`) varsa, sadece hedef  │
│       tipin çağrıldığı gerçek noktaları listeler (False-positive sıfırlanır).                   │
│                                                                                                 │
│  4. Güvenli Refactoring & Otomatik Yeniden Adlandırma (Workspace Rename):                       │
│     • Bir değişken veya fonksiyon adı değiştirildiğinde tüm projede atomik güncelleme yapar.    │
│                                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## ⚙️ 2. Yapılandırma & Kullanıcı Kontrolü (Config Knobs)

LSP sunucuları (`rust-analyzer`, `clangd` vb.) ağır süreçler olduğu için **kullanıcı tarafından tamamen yapılandırılabilir ve isteğe bağlı (opt-in)** olacaktır:

```yaml
# .rubik/config.yml veya ~/.rubik/config.yml
lsp:
  enabled: false                # Varsayılan: false (Sıfır ek yük, ultra hafif mod)
  auto_start: true              # lsp.enabled: true ise proje diline göre sunucuyu otomatik başlat
  auto_diagnostics: true        # Tampon güncellendiğinde derleyici hatalarını modele anında bildir
  servers:
    go: "gopls"
    rust: "rust-analyzer"
    zig: "zls"
    c: "clangd"
    cpp: "clangd"
    python: "pylsp"
    ruby: "solargraph"
```

### REPL Komut Desteği:
- `!lsp status`: Aktif LSP sunucularını, PID'lerini ve çalışma durumunu gösterir.
- `!lsp on` / `!lsp off`: LSP modunu anında açar / kapatır (kalıcı yapmak için `--project` veya `--global` parametresi alır).
- `!lsp start [lang]` / `!lsp stop [lang]`: Belirli bir dil sunucusunu manuel başlatır / durdurur.
- `!lsp diag [file]`: Belirtilen dosya veya tüm proje için anlık LSP tanılama (hata/uyarı) listesini döker.

---

## 🏛️ 3. Mimari Tasarım & Spatiotemporal Composability ([`AGENTS.md`](../AGENTS.md))

```text
                                  ┌─────────────────────────────┐
                                  │      Rubik REPL / Loop      │
                                  └──────────────┬──────────────┘
                                                 │
                             ┌───────────────────┴───────────────────┐
                             │                                       │
                             ▼                                       ▼
                  ┌────────────────────┐                  ┌────────────────────┐
                  │    BufferManager   │                  │    ContextBuilder  │
                  └──────────┬─────────┘                  └──────────┬─────────┘
                             │ (on write)                            │
                             ▼                                       │
                  ┌────────────────────┐                             │
                  │   LSP::Manager     │◄────────────────────────────┘
                  │  (Child Processes) │ (injects <lsp_diagnostics>)
                  └──────────┬─────────┘
                             │ JSON-RPC 2.0 (stdio)
        ┌────────────────────┼────────────────────┬────────────────────┐
        ▼                    ▼                    ▼                    ▼
   [ rust-analyzer ]     [ gopls ]            [ clangd ]           [ pylsp ]
```

### Invariant & Güvenlik Prensipleri:
1. **Asenkron / Non-Blocking İletişim:** LSP sunucusunun yanıt vermesi veya çökmesi ana REPL döngüsünü veya modelin adımını kilitleyemez.
2. **Akıllı Hibrit Router (Smart Fallback):**
   - LSP açık ve sunucu çalışıyorsa $\implies$ LSP'den kesin derleyici sonucu al.
   - Sunucu yoksa veya hata verirse $\implies$ Anında dahili saf Ruby `AST::Graph`'a geri düş (Graceful Fallback).
3. **Temiz Süreç İzolasyonu (RAII & LIFO Unwind):**
   - REPL kapandığında veya `!lsp stop` dendiğinde LSP süreçleri zombi bırakılmadan temiz şekilde `shutdown` $\to$ `exit` ile sonlandırılır.

---

## 🛠️ 4. Eklenecek Bileşenler ve Görev Listesi

### A. Çekirdek LSP İstemcisi ve Yöneticisi (`lib/rubik/lsp/`)
- [ ] **`Rubik::LSP::Manager` (`lib/rubik/lsp/manager.rb`):**
  - Çoklu dil sunucularını yöneten yaşam döngüsü yöneticisi.
  - Projedeki aktif dillere göre ilgili sunucuları başlatma/durdurma (`ensure_server_for(lang)`).
  - Buffer değişikliklerini sanal olarak LSP'ye bildirme (`did_open`, `did_change`, `did_close`).
  - Asenkron `publishDiagnostics` dinleyicisi ve güncel hata önbelleği (`diagnostics_for(file)`).

### B. Yeni Native Model Araçları (`lib/rubik/tools/builtins.rb`)
- [ ] **`LSPHoverTool` (`lsp_hover`):**
  - Dosyadaki belirli satır ve sütundaki sembolün tam tip imzasını ve dokümantasyonunu döner.
- [ ] **`LSPDiagnosticsTool` (`lsp_diagnostics`):**
  - Dosyadaki tüm aktif derleyici/linter hata ve uyarılarını satır numaralarıyla listeler.
- [ ] **`LSPDefinitionTool` (`lsp_definition`):**
  - Kesin tip çözümlemesi ile sembolün kaynak kod tanımına gider.

### C. Tampon & Model Geri Bildirim Döngüsü Entegrasyonu
- [ ] **`BufferManager` & `Orchestrator::Loop` Hook Entegrasyonu:**
  - `write_file` çağrıldığında `lsp.auto_diagnostics` aktifse tampon içeriği anında LSP sunucusuna gönderilir.
  - Eğer derleyici hatası (compile error) oluştuysa, bir sonraki model adımına `<lsp_diagnostics>` bloğu olarak anında enjekte edilir. Model testi çalıştırmadan önce hatasını fark edip düzeltir.

### D. REPL `!lsp` Komutu & Konfigürasyon
- [ ] `lib/rubik/config.rb` içine `lsp.enabled`, `lsp.auto_diagnostics`, `lsp.servers` default değerlerinin eklenmesi.
- [ ] `lib/rubik/repl/shell.rb` içine `!lsp` komutunun eklenmesi (`status`, `on`, `off`, `diag`, `start`, `stop`).
- [ ] `ContextBuilder.build_system_context` içine LSP durumu ve aktif teşhislerin (`<lsp_status>`, `<lsp_diagnostics>`) eklenmesi.

---

## 🧪 5. Kabul Kriterleri & Test Senaryoları

- [ ] `lsp.enabled: false` olduğunda sistem hiçbir harici süreç başlatmaz ve sıfır ek bellek/CPU tüketir.
- [ ] `!lsp on` veya `!lsp start go` dendiğinde (sistemde `gopls` varsa) sunucu ayağa kalkar, `!lsp status` ile PID ve durum doğrulanır.
- [ ] Model hatalı kod yazdığında (`write_file`), LSP'nin ürettiği hata mesajı test çalıştırılmadan önce `<lsp_diagnostics>` etiketiyle modele geri bildirilir.
- [ ] Sistemde sunucu bulunmadığında (`which` başarısız olduğunda) sistem çökmez, nazik bir uyarı verir ve `AST::Graph`'a fallback yapar.
- [ ] `test/unit/test_lsp_manager_and_diagnostics.rb` birim testleri (Mock JSON-RPC sunucusu ve gerçek süreç testleri) %100 yeşil geçer.
