# 21 — LLM REPL Komut Yürütümü, Dinamik Araç Sentezi ve Kapsamlı Katmanlama (Overlay Runtime)

**Zorluk:** Zor · **Öneri kaynağı:** Kullanıcı Yönergesi & `AGENTS.md` (§3) · **Faz:** 5 (Kendi Kendini Geliştirme & Simetrik REPL)  
**İlgili Planlar:** [02 — REPL Çekirdeği](02-repl-cekirdegi.md) · [10 — Tool-Calling](10-tool-calling-orkestrasyon.md) · [14 — Eklenti Sistemi](14-eklenti-sistemi.md) · [20 — Spatiotemporal Composability](20-spatiotemporal-composability-eklenti-dongusu.md) · [Index](index.md)

## Amaç

1. **Simetrik REPL Operatörlüğü:** İnsan geliştiricinin REPL içinde çalıştırabildiği tüm ünlem (`!`) komutlarını (`!test`, `!diff`, `!undo`, `!context`, `!lint`, `!format`, `!model`, `!sh` vb.) LLM'in bir araç (`exec_repl_command`) vasıtasıyla doğrudan yürütebilmesini sağlamak.
2. **Dinamik Komut ve Araç Sentezi:** Ajanın ihtiyaç duyduğunda yeni ünlem (`!`) komutları veya native tool'lar yazabilmesi, bunları güvenli şekilde test edip canlı çalışma zamanına (Overlay Runtime) ekleyebilmesi.
3. **Kapsamlı Depolama ve Katmanlama Mimarisi:**
   - **Geçici / Oturum Kapsamı (`:session`):** `ctx.extend()` içinde anlık denenen, görev bittiğinde LIFO ile geri alınan izole araçlar.
   - **Proje Kapsamı (`:project`):** Repo içindeki `.rubik/commands/` veya `.rubik/plugins/` altında saklanan, git ile takımla paylaşılan projeye has komutlar.
   - **Global Kapsam (`:global`):** Kullanıcının ev dizinindeki `~/.rubik/commands/` veya `~/.rubik/plugins/` altında saklanan ve tüm projelerde geçerli olan evrensel araçlar.

---

## Mimari Tasarım

```text
                        ┌──────────────────────────────────────────────┐
                        │        SIMETRIK REPL & OVERLAY RUNTIME       │
                        └──────────────────────┬───────────────────────┘
                                               │
                       ┌───────────────────────┴───────────────────────┐
                       ▼                                               ▼
     ┌───────────────────────────────────┐           ┌───────────────────────────────────┐
     │      KOMUT YÜRÜTÜMÜ (LLM -> !)    │           │      DİNAMİK KOMUT/TOOL SENTEZİ   │
     ├───────────────────────────────────┤           ├───────────────────────────────────┤
     │ • `exec_repl_command("!test")`    │           │ • `synthesize_command` / Tool DSL │
     │ • `exec_repl_command("!diff")`    │           │ • Dry-run test `ctx.extend()`     │
     │ • `exec_repl_command("!undo")`    │           │ • Atomik Rollback on verification │
     └───────────────────────────────────┘           └───────────────────────────────────┘
                                                       │
                               ┌───────────────────────┴───────────────────────┐
                               ▼                                               ▼
                     ┌───────────────────┐                           ┌───────────────────┐
                     │   PROJE KAPSAMI   │                           │   GLOBAL KAPSAM   │
                     │ (.rubik/commands) │                           │ (~/.rubik/commands│
                     └───────────────────┘                           └───────────────────┘
```

---

## Görevler (kolaydan zora)

1. `Rubik::Tools::ExecReplCommandTool` (`exec_repl_command`):
   - LLM'in REPL içindeki tüm kayıtlı `!` komutlarını parametreleriyle birlikte çağırmasını sağlayan araç.
   - Çıktıyı yakalayıp LLM'e geri besleme (örneğin `!test` çalıştırıp derleyici/test sonucunu doğrudan alma).
2. Katmanlı Komut ve Araç Deposu (`Rubik::Runtime::OverlayStorage`):
   - `.rubik/commands/*.rb` (proje) ve `~/.rubik/commands/*.rb` (global) dosyalarını tarama ve otomatik keşif.
3. Dinamik Sentezleyici Aracı (`Rubik::Tools::SynthesizeCommandTool`):
   - LLM'in yeni bir REPL komutu veya aracı oluşturması (`name`, `description`, `scope: :session | :project | :global`, `code`).
   - Sentezlenen kodu önce `ctx.extend()` alt bağlamında syntax ve dry-run testine tabi tutma.
   - Doğrulama geçerse hedef klasöre (`.rubik/` veya `~/.rubik/`) kalıcı yazma ve `Runtime::Manager` ile sıfır kesintili sıcak yükleme (`swap_component`).
4. Güvenlik ve Kapsam Koruması:
   - Sentezlenen komutların `Rubik::Security::Guard` denetiminden geçirilmesi; tehlikeli sistem çağrılarının engellenmesi.
5. REPL Komutları:
   - `!commands` (kayıtlı tüm yerleşik, proje ve global komutları kaynaklarıyla listeler).

---

## Kabul Kriterleri

- [ ] LLM, `exec_repl_command("!diff")` veya `exec_repl_command("!test")` çağrısı yaparak insan operatörün gördüğü REPL çıktısını birebir alır.
- [ ] LLM yeni bir `!db:seed` veya `!format:all` komutu sentezlediğinde, komut anında REPL'de `!db:seed` olarak insan kullanıcı tarafından da çalıştırılabilir hale gelir.
- [ ] `:project` kapsamındaki komutlar `.rubik/commands/` klasörüne, `:global` kapsamındaki komutlar `~/.rubik/commands/` klasörüne yazılır ve bir sonraki `rubik` açılışında otomatik yüklenir.
- [ ] Hatalı veya sözdizimi bozuk sentezlenen komutlar `ctx.extend()` içinde elenir ve mevcut çalışma ortamını bozmaz.

---

## Bağımlılıklar

- [Plan 02 (REPL Çekirdeği)](02-repl-cekirdegi.md)
- [Plan 10 (Tool-Calling Orkestrasyonu)](10-tool-calling-orkestrasyon.md)
- [Plan 20 (Spatiotemporal Composability)](20-spatiotemporal-composability-eklenti-dongusu.md)

---

## Test Stratejisi

- Birim: `ExecReplCommandTool` komut yürütümü ve yakalanan çıktılar.
- Entegrasyon: LLM'in `synthesize_command` ile yeni bir komut üretip hemen ardından `exec_repl_command` ile bunu başarıyla çalıştırması senaryosu.
