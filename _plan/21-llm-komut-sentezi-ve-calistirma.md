# 21 — LLM REPL Komut Yürütümü, Dinamik Araç Sentezi ve Kapsamlı Katmanlama (Overlay Runtime)

**Durum:** ✅ **Tamamlandı** · **Zorluk:** Zor · **Öneri kaynağı:** Kullanıcı Yönergesi & `AGENTS.md` (§3) · **Faz:** 5 (Kendi Kendini Geliştirme & Simetrik REPL)  
**İlgili Planlar:** [02 — REPL Çekirdeği](02-repl-cekirdegi.md) · [10 — Tool-Calling](10-tool-calling-orkestrasyon.md) · [14 — Eklenti Sistemi](14-eklenti-sistemi.md) · [20 — Spatiotemporal Composability](20-spatiotemporal-composability-eklenti-dongusu.md) · [Index](index.md)

## Amaç

1. **Simetrik REPL Operatörlüğü:** İnsan geliştiricinin REPL içinde çalıştırabildiği tüm ünlem (`!`) komutlarını (`!test`, `!diff`, `!undo`, `!context`, `!lint`, `!format`, `!model`, `!sh` vb.) LLM'in bir araç (`exec_repl_command`) vasıtasıyla doğrudan yürütebilmesini sağlamak.
2. **Dinamik Komut ve Araç Sentezi:** Ajanın ihtiyaç duyduğunda yeni ünlem (`!`) komutları veya native tool'lar yazabilmesi (`synthesize_command`), bunları güvenli şekilde test edip canlı çalışma zamanına (Overlay Runtime) ekleyebilmesi.
3. **Kapsamlı Depolama ve Katmanlama Mimarisi:**
   - **Geçici / Oturum Kapsamı (`:session`):** In-memory kaydedilen ve görev bittiğinde LIFO ile geri alınan araçlar.
   - **Proje Kapsamı (`:project`):** Repo içindeki `.rubik/commands/` altında saklanan ve git ile takımla paylaşılan projeye has komutlar.
   - **Global Kapsam (`:global`):** Kullanıcının ev dizinindeki `~/.rubik/commands/` altında saklanan ve tüm projelerde geçerli olan evrensel araçlar.

## Tamamlanan Görevler

1. `Rubik::Runtime::OverlayStorage`:
   - `.rubik/commands/*.rb` ve `~/.rubik/commands/*.rb` dizin yapısı, otomatik dizin oluşturma, kalıcı kaydetme ve REPL açılışında otomatik yükleme (`load_all`).
2. `Rubik::Tools::ExecReplCommandTool` (`exec_repl_command`):
   - Modelin `!diff`, `!status`, `!test`, `!context scan`, `!model set fast <target>` gibi komutları çağırıp çıktıyı birebir yakalayabilmesi.
   - İç içe recursive plan/goal çağrılarının bloke edilmesi.
3. `Rubik::Tools::SynthesizeCommandTool` (`synthesize_command`):
   - Canlı ortamda `name`, `description`, `scope` (`session` | `project` | `global`) ve `code` alarak sözdizimini doğrulama, hedef depoya yazma ve REPL Shell'e sıcak kaydetme (hot-registration).
4. `Rubik::REPL::Shell` Entegrasyonu:
   - `!commands` komutu (tüm yerleşik ve sentezlenmiş katman komutlarını listeleme).
   - `build_tool_registry` içine `exec_repl_command` ve `synthesize_command` araçlarının varsayılan olarak dahil edilmesi.

## Kabul Kriterleri

- [x] LLM, `exec_repl_command("!diff")` veya `exec_repl_command("!test")` veya `exec_repl_command("!model set fast ollama/qwen2.5-coder:7b")` çağrısı yaparak REPL durumunu okur ve günceller.
- [x] LLM yeni bir `!db_seed` veya `!docker_build` komutu sentezlediğinde, komut anında REPL'de insan kullanıcı tarafından da çalıştırılabilir hale gelir.
- [x] `:project` kapsamındaki komutlar `.rubik/commands/` klasörüne, `:global` kapsamındaki komutlar `~/.rubik/commands/` klasörüne yazılır ve bir sonraki `rubik` açılışında otomatik yüklenir.
- [x] Hatalı veya sözdizimi bozuk sentezlenen komutlar yakalanır ve mevcut çalışma ortamını bozmaz.

## Bağımlılıklar

- [Plan 02 (REPL Çekirdeği)](02-repl-cekirdegi.md)
- [Plan 10 (Tool-Calling Orkestrasyonu)](10-tool-calling-orkestrasyon.md)
- [Plan 20 (Spatiotemporal Composability)](20-spatiotemporal-composability-eklenti-dongusu.md)

## Test Kapsamı

- `test/unit/test_repl_command_execution_and_synthesis.rb`: REPL `!diff`, `!status`, `!model set`, `!context scan` komutlarının LLM tarafından yürütümü; `session` ve `project` kapsamlarında komut sentezi, kalıcı dosya kaydı, yeni `Shell` oturumunda otomatik yükleme ve sözdizimi hata koruma testleri.
