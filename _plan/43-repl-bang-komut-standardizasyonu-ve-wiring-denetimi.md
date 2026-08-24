# 📋 Plan 43: REPL Bang Komutlarının Standardizasyonu, Tutarlı Alt Komut Mimarisi ve Uçtan Uca Wiring Denetimi

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** ✅ **Tamamlandı** · **Zorluk:** Orta · **Faz:** 5 (CLI/REPL Ergonomisi & Tutarlılık)  
> **İlgili Planlar:** [02](02-repl-kabugu-ve-etkilesimli-arayuz.md), [25](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md), [37](37-kademeli-verbosity-ayarlari-ve-canli-ajan-izleme.md), [40](40-coklu-calisma-alani-ve-ek-kok-dizin-erisim-yonetimi.md), [41](41-repl-komut-modulerizasyonu-domain-driven-command-decoupling.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

### Mevcut Durum & Tutarsızlıklar (Inconsistencies)
1. **`!config` Belirsizliği (Vagueness & Implicit Grammar):**
   - `!config` bazen fiilsiz örtük (`!config key val`, `!config key`), bazen fiilli (`!config set key val`, `!config get key`), bazen özel anahtarlı (`!config path`) çalışmaktadır.
   - Bu durum `gh config`, `npm config` veya `kubectl config` gibi endüstri standardı CLI araçlarının sunduğu açık (explicit) ve öngörülebilir `set / get / list / path` hiyerarşisine uymamakta; anahtar çakışması ve kazara mutasyon riski taşımaktadır.
2. **Alt Komut ve Yardım Metinleri Tutarsızlığı:**
   - Bazı komutlarda (`!lsp`, `!workspace`, `!session`) `list / status / add / remove` gibi açık alt komutlar kullanılırken, bazı komutlarda (`!steps`, `!context`, `!autoapply`) argüman yapısı farklılaşmaktadır.
3. **Akıllı Yönlendirme (Smart Suggestions) Eksikliği:**
   - Kullanıcı `!config lsp.enabled true` veya `!lsp go` gibi eksik fiilli girdiğinde genel `Usage: ...` yerine, kullanıcının niyetini anlayan net ve rehberlik eden hata mesajları dönmelidir.
4. **Uçtan Uca Wiring Kontrolü:**
   - Tüm 39 komutun alt sistemlerle (`Buffer::Manager`, `Security::Guard`, `LSP::Manager`, `AST::Graph`, `Session::Manager`, `Config`) canlı senkronizasyonunun ve `YAML::Store` kalıcılığının doğrulanması.

---

## 🏛️ 2. Standart REPL Komut Hiyerarşisi

Tüm komutlar `Explicit Verb > Optional Target > Optional Flags` standardına kavuşturulacaktır:

```
                               ┌──────────────────────────────────────────────────┐
                               │           Standart Rubik REPL Komutları          │
                               └────────────────────────┬─────────────────────────┘
                                                        │
         ┌──────────────────┬──────────────────┬────────┴─────────┬──────────────────┬──────────────────┐
         ▼                  ▼                  ▼                  ▼                  ▼                  ▼
  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
  │   !config    │   │  !workspace  │   │     !lsp     │   │   !session   │   │   !context   │   │   !buffer    │
  ├──────────────┤   ├──────────────┤   ├──────────────┤   ├──────────────┤   ├──────────────┤   ├──────────────┤
  │ • set        │   │ • list       │   │ • status     │   │ • list       │   │ • status     │   │ • diff       │
  │ • get        │   │ • add        │   │ • start      │   │ • resume     │   │ • compact    │   │ • apply      │
  │ • list       │   │ • remove     │   │ • stop       │   │ • save       │   │ • stats      │   │ • undo       │
  │ • path       │   │ • status     │   │ • diag       │   │ • replay     │   │              │   │ • rollback   │
  │ • reset      │   │              │   │ • restart    │   │ • info       │   │              │   │ • autoapply  │
  └──────────────┘   └──────────────┘   └──────────────┘   └──────────────┘   └──────────────┘   └──────────────┘
```

---

## ⚙️ 3. Modül Bazında Standardizasyon Detayları

### 3.1 `Rubik::REPL::Commands::Workspace` ([`workspace.rb`](../lib/rubik/repl/commands/workspace.rb))
- **`!config` Sözdizimi:**
  - `!config set <key> <value> [--project|--global]` -> Belirtilen anahtara değeri atar ve kaydeder.
  - `!config get <key>` -> Belirtilen anahtarın mevcut değerini gösterir.
  - `!config list [filter]` -> Tüm yapılandırmayı veya filtrelenen bölümü (örn: `!config list lsp`) ağaç/liste formatında gösterir.
  - `!config path` -> Global ve proje yapılandırma dosyalarının disk yollarını gösterir.
  - **Akıllı Hata Yakalama:** Kullanıcı `!config lsp.enabled true` (fiilsiz) yazdığında:
    ```text
    [Rubik::Config] Geçersiz kullanım.
      • Ayar yapmak için : !config set lsp.enabled true
      • Değer okumak için: !config get lsp.enabled
    ```
- **`!workspace` / `!roots` Sözdizimi:**
  - `!workspace list` (varsayılan)
  - `!workspace add <path> [--rw] [--project|--global]`
  - `!workspace remove <path> [--project|--global]` (alias: `rm`)
  - `!workspace status`

### 3.2 `Rubik::REPL::Commands::Lsp` ([`lsp.rb`](../lib/rubik/repl/commands/lsp.rb))
- **`!lsp` Sözdizimi:**
  - `!lsp status` (varsayılan)
  - `!lsp start <lang>` -> Dil sunucusunu başlatır (`!lsp start go`).
  - `!lsp stop [lang]` -> Belirtilen veya tüm sunucuları durdurur.
  - `!lsp restart [lang]` -> Sunucuyu yeniden başlatır.
  - `!lsp on` / `!lsp enable` -> `lsp.enabled` ayarını `true` yapar.
  - `!lsp off` / `!lsp disable` -> `lsp.enabled` ayarını `false` yapar ve sunucuları kapatır.
  - `!lsp diag [file]` -> Canlı teşhisleri gösterir.
  - `!lsp servers` -> Desteklenen tüm dil sunucularını ve kurulu/eksik durumlarını listeler.
- **Doğrudan Komutlar:**
  - `!diagnostics [file]` (LSP canlı teşhisleri)
  - `!symbols <query>` (AST sembol araması)
  - `!outline <file>` (Dosya anahattı)
  - `!refs <symbol>` (Referans ve çağrı yerleri)
  - `!ast <file|symbol>` (AST inceleme)

### 3.3 `Rubik::REPL::Commands::Buffer` ([`buffer.rb`](../lib/rubik/repl/commands/buffer.rb))
- `!diff [path]` -> Tampondaki farkları gösterir.
- `!apply [path]` -> Tampondaki değişiklikleri diske yazar, AST ve bağlamı senkronize eder.
- `!undo` -> Son tampon işlemini geri alır.
- `!rollback <snapshot_id>` -> Belirtilen anlık görüntüye döner.
- `!autoapply <status | manual | on_test | on_finish | always> [--project|--global]`

### 3.4 `Rubik::REPL::Commands::Session` ([`session.rb`](../lib/rubik/repl/commands/session.rb))
- `!history [limit]`
- `!session list`
- `!session resume [id]`
- `!session save [name]`
- `!session info`
- `!replay <file>`

### 3.5 `Rubik::REPL::Commands::Agent` ([`agent.rb`](../lib/rubik/repl/commands/agent.rb))
- `!plan <task>`
- `!goal <task>`
- `!steps [status | default <n> | goal <n> | plan <n>] [--project|--global]`
- `!verbosity [status | quiet | normal | verbose | debug | 0..3] [--project|--global]`
- `!verbose` (hızlı verbose toggle)
- `!model [name]` (varsayılan modeli gösterir veya değiştirir)
- `!provider [name]` / `!providers` (sağlayıcı listeleme ve geçiş)
- `!context <status | compact | stats>`
- `!test [args]` / `!lint [args]` / `!format [args]` / `!sh <cmd>`

### 3.6 `Rubik::REPL::Commands::System` ([`system.rb`](../lib/rubik/repl/commands/system.rb))
- `!help [command]`
- `!commands`
- `!status`
- `!runtime [all | fibers | services]`
- `!fibers` / `!services`
- `!clear` / `!reset`
- `!quit` / `!exit`

---

## 🔍 4. Uçtan Uca Wiring & Entegrasyon Kontrol Listesi

1. **`Config <-> Subsystems` Senkronizasyonu:**
   - `!config set workspace.additional_roots` -> `Buffer::Manager` ve `Context::Scanner` kökleri anında güncellenir.
   - `!config set workspace.allow_external_writes` -> `Buffer::Manager.allow_external_writes` güncellenir.
   - `!config set lsp.enabled` -> `LSP::Manager.enabled?` senkronize olur.
   - `!config set ui.verbosity` -> `Shell` ve `StepFormatter` anında tepki verir.
2. **`YAML::Store` İşlem Güvenliği:**
   - Tüm `--project` ve `--global` kayıtları atomik, kilitli ve şema doğrulamalı olarak yazılır.
3. **Spatiotemporal Runtime Bağlantısı:**
   - `!runtime`, `!fibers`, `!services` komutları `@runtime_manager` üzerindeki aktif/bekleyen fiber ve koefektleri kayıpsız raporlar.

---

## 🧪 5. Test ve Doğrulama Planı

1. **`test/unit/test_repl_standardized_commands.rb`:**
   - Her modülün alt komutlarının (`set`, `get`, `list`, `path`, `start`, `stop`, `status` vb.) eksiksiz test edilmesi.
   - Geçersiz alt komut ve argümanlarda akıllı yönlendirme mesajlarının doğrulanması.
2. **Geriye Dönük Regresyon Testi:**
   - Tüm 258 testin %100 yeşil kalmasının sağlanması.

---

## 🚀 6. Uygulama ve Onay Akışı

1. **Aşama 1 (Hazırlık):** Kullanıcı planı inceler ve onay verir.
2. **Aşama 2 (Çoklu Ajan İcrası):** Reviewer $\rightarrow$ Executor $\rightarrow$ Auditor adımları sırayla çalıştırılır.
3. **Aşama 3 (Doğrulama & Push):** Testler tamamlandıktan sonra kullanıcıya sunulur ve onay ile pushlanır.
