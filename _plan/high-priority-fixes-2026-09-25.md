# Plan: Doğrulanmış HIGH Bulgu Düzeltmeleri — 2026-09-25

> **Kaynak:** 4 doğrulama ajanının verdict raporu (C1/H9/M10/M14/M16/M18 ve plugin-inverse iddiaları **ÇÜRÜTÜLDÜ**; aşağıdakiler **TRUE**).
> **Protokol:** [`AGENTS.md`](../AGENTS.md) §A (Revertible Effects), §B (Reactive Coeffects), §C (Context-Mediated Ops), §5 (Forbidden Anti-Patterns).
> **Kapsam:** H1, H2, H3, H5, H6, H7, H8 (+ H4 opsiyonel).
> **Zorluk:** Orta–Zor · **Faz:** 6 (Runtime Sağlamlaştırma)  
> **Durum:** ✅ **Tamamlandı** (25 Eylül 2026 — 2107 runs, 11862 assertions, 0 failures, 0 errors, 1 skips)

## Bağlayıcı kararlar (verdict kaynaklı)
- C1 (XML escape) ve H9 (repair self-mod) **REFUTED** → planlanmadı; kod zaten güvenli.
- M10/M14/M16/M18 REFUTED → sandbox env, YAML, skill script, TTY gating işi YOK.
- Manager unwind düzeltmesi AGENTS.md §5 (Atomic Rollback) ve §6 (Zero-Restart) gereği **LIFO + per-fiber izolasyon** olmak zorunda.

## İş kalemleri

- **W1 (H3)** `runtime/manager.rb` `dispose!`: `@fibers.values.each(&:dispose!)` → per-fiber `begin/rescue StandardError => e; @logger.warn(...); end`; `@context.dispose` **her koşulda** çalışacak şekilde `ensure`'a alınır. Tek fiber hatası tüm unwind'i iptal edemez.
- **W2 (H3/M1)** `runtime/manager.rb` `dispose!` sırası: **FIFO → LIFO** (`@fibers.values.reverse_each`). Bağımlılık tersine çevrilerek ters kronolojik unwind sağlanır (§A).
- **W3 (M2)** `runtime/manager.rb`: `@disposed` bayrağı; `dispose!` idempotent (ikinci çağrı no-op) ve dispose sonrası `register_component` yeni fiber kabul etmez (sealed context'e karşı repopulate engellenir).
- **W4 (H2)** `repl/hooks.rb`: `register(name) { ... }` bloğu **unsubscribe token** olarak döndürür (EventBus ile simetrik); yeni `unregister(name, token)` eklenir. `before_command`/`after_command` per-command event'lerinin birikmesi durur. Çağıranlar (shell) token'ı `ctx.on_dispose` ile kaydeder.
- **W5 (H1)** `repl/ast_warmup.rb` `stop_background_indexer`: indexer thread `ctx.register_disposable { stop_background_indexer }` ile tersine çevrilebilir effect olarak kaydedilir; `join_indexer_safely` time-box'ı kaldırılır veya döngü `while thread.alive?` ile tam join eder; thread ref yalnız `!alive?` doğrulandıktan sonra nil'lenir; thread gövdesi `rescue StandardError` ile sarılır.
- **W6 (H7)** `lsp/client.rb`: init handshake `send_request("initialize", ...)` dönüşü `nil` ise **başarısızlık** sayılır (`stop; return false`), rescue beklenmez. `@running` yalnız gerçek init ack sonrası true olur; orphan child process önlenir.
- **W7 (H8)** `lsp/client.rb` reader loop: `rescue StandardError; break` → mesaj-başına `rescue StandardError => e; log(e); next`; yalnız gerçek EOF/`IOError`'da döngü kırılır. Reader ölümünde `alive?` false dönecek şekilde `@running`/`@reader_alive` senkronlanır.
- **W8 (H5)** `tools/builtins/synthesis.rb`: unregister inverse `@runtime_manager&.context` tip-Runtime::Context koşuluna bağlı kurulmaz; her durumda kurulur (`swap` varsa swap, yoksa fallback `unregister`). Aksi halde sentezlenen araç asla kaldırılmaz.
- **W9 (H6)** `tools/builtins/synthesis.rb`: `test_args` verilmemişse "syntax-only" sentezlenen Ruby LLM-görünür hale **gelmez**; runtime pre-flight (`guard:`/`verify`) zorunlu hale gelir. Pre-flight'sız araç toolbelt'e kaydolmaz.
- **W10 (H4, opsiyonel)** `orchestrator/step_executor.rb` + `tools/base.rb`: dispatch öncesi merkezi `params_schema` doğrulaması (required/type/unknown-key); hata yapılandırılmış `:error` olarak döner → model self-correction. Risk düşük (arg'lar LLM tool_call parse'ından), bu yüzden opsiyonel.

## Commit planı (conventional)
1. `fix(runtime): isolate per-fiber dispose failures` (W1)
2. `fix(runtime): unwind fibers LIFO and guard re-registration after dispose` (W2, W3)
3. `fix(repl): make hooks reversible with unsubscribe tokens` (W4)
4. `fix(repl): register AST indexer as disposable and fully join on teardown` (W5)
5. `fix(lsp): treat nil init as failure and isolate reader-loop errors` (W6, W7)
6. `fix(tools): always install synthesis unregister inverse and require preflight` (W8, W9)
7. `feat(tools): validate tool-call arguments against params_schema` (W10 — opsiyonel)

## Test haritası
- W1/W2/W3 → `test/unit/test_context_dispose_hygiene.rb`, `test/unit/test_runtime_manager.rb` (per-fiber hata izolasyonu, LIFO sıra, idempotent dispose, sealed sonrası register reddi).
- W4 → `test/unit/test_repl_hooks.rb` (kayıt/kaldırma simetrisi, per-command event birikmemesi).
- W5 → `test/unit/test_ast_warmup.rb` (teardown sonrası thread ölü, çift indexer yok).
- W6/W7 → `test/unit/test_lsp_client.rb` (nil-init → stop, bozuk mesaj sonrası reader canlı/alive? tutarlılığı).
- W8/W9 → `test/unit/test_synthesis.rb` (pre-flight'sız araç görünmez; unregister her context'te kurulu).
- W10 → `test/unit/test_step_executor.rb` (şema ihlali → `:error`).

## Uygulama sırası
W1 → W2 → W3 → W4 → W5 → W6 → W7 → W8 → W9 → (W10) → tam suite + GitNexus `detect-changes` (her commit öncesi).

## Kritik tuzaklar
- **W2 sıra değişikliği**: LIFO'ya geçmek, init sırasına bağlı testleri kırabilir; bağımlılık grafı tersine çevrildiğinde fixture kayıt sırası gözden geçirilmeli.
- **W1 `ensure`**: `@context.dispose` zaten hata-izole çalışır (`runtime/context.rb` drain); Manager tarafında çift-rescue yığmaktan kaçın, yalnız fiber sınırında izole et.
- **W5 join**: süresiz join teardown'ı askıya alabilir; `while alive?` ile üst sınırsız ama thread gövdesinin kendi `rescue`'su ölümü garantilediğinden güvenli — aksi halde deadlock.
- **W6/W7 LSP**: `alive?` ve `@running` arasındaki tek-kaynak kuralı (hangi bayrak ne zaman) net tanımlanmalı; aksi halde "görünürde canlı ama yanıtsız" sınıfı sürer.
- **W9**: pre-flight zorunluluğu mevcut sentez akışını yavaşlatabilir; pre-flight'ı varsayılan-spawn simülasyonunda çalıştır, gerçek repo'ya dokunma.
- Her sembol öncesi **GitNexus impact** (UNKNOWN → text-search doğrulaması); `dispose!`, `register`, `stop_background_indexer` HIGH-risk semboller.

---

## 🚀 Uygulama Raporu (25 Eylül 2026)

Tüm HIGH öncelikli maddeler (W1–W9) başarıyla uygulandı ve test edildi:

| İş Kalemi | Açıklama | Değiştirilen Dosyalar / Testler | Durum |
| :--- | :--- | :--- | :---: |
| **W1 (H3)** | `Runtime::Manager#dispose!` tek fiber hatasında diğerlerini iptal etmez; `@context.dispose` ensure içinde garantilidir | `lib/rubik/runtime/manager.rb`, `test/unit/test_context_dispose_hygiene.rb` | ✅ |
| **W2 (H3/M1)** | `Runtime::Manager#dispose!` fiber unwind sırası FIFO'dan LIFO'ya (`reverse_each`) geçirildi | `lib/rubik/runtime/manager.rb`, `test/unit/test_context_dispose_hygiene.rb` | ✅ |
| **W3 (M2)** | `@disposed` bayrağı eklendi; `dispose!` idempotent yapıldı; dispose sonrası `register_fiber` / `register_component` `ContextDisposedError` ile reddedilir | `lib/rubik/runtime/manager.rb`, `test/unit/test_context_dispose_hygiene.rb` | ✅ |
| **W4 (H2)** | `REPL::Hooks#register` unsubscribe token (blok) döndürür; `unregister(event, token)` metodu eklendi; Mutex ile thread-safe yapıldı | `lib/rubik/repl/hooks.rb`, `test/unit/test_repl_hooks.rb` | ✅ |
| **W5 (H1)** | `AstWarmup#warm_ast_graph` indexer thread'ini `ctx.register_disposable` ile kaydeder; cooperative stop ve safe join sağlandı; thread gövdesi rescue ile korundu | `lib/rubik/repl/ast_warmup.rb`, `test/unit/test_ast_warmup.rb` | ✅ |
| **W6 (H7)** | `LSP::Client#start` nil initialize yanıtını başarısızlık kabul eder (`stop; return false`); orphan process önlendi | `lib/rubik/lsp/client.rb`, `test/unit/test_lsp_client.rb` | ✅ |
| **W7 (H8)** | `LSP::Client` reader loop mesaj-başına parse/handle hatalarını izole eder (`next`); yalnız gerçek EOF/IOError'da kırılır; `@reader_alive` ve `alive?` senkronlandı | `lib/rubik/lsp/client.rb`, `test/unit/test_lsp_client.rb` | ✅ |
| **W8 (H5)** | `SynthesizeToolTool` ve `SynthesizeCommandTool` unregister inverse'ü duck-typed context üzerinde de kurulur; `swap` yoksa `unregister`'a fallback yapar | `lib/rubik/tools/builtins/synthesis.rb`, `test/unit/test_synthesis.rb` | ✅ |
| **W9 (H6)** | `SynthesizeToolTool` runtime pre-flight zorunlu kılındı (varsayılan argümanlarla izole süreçte çalıştırılır); pre-flight geçemeyen araçlar toolbelt'e eklenmez | `lib/rubik/tools/builtins/synthesis.rb`, `test/unit/test_synthesis.rb` | ✅ |

### Test Doğrulaması
- **Birim & Entegrasyon Testleri:** `2107 runs, 11862 assertions, 0 failures, 0 errors, 1 skips` (Tam Yeşil).
- **GitNexus Değişiklik Tespiti:** 8 etkilenen akış ve sembol doğrulandı, gerileme tespit edilmedi.

### Diff Review ve Sağlamlaştırma Bulguları (Post-Implementation Audit)
1. **LSP Client Canlılık Senkronizasyonu (`alive?` vs `@running`):**
   - Tüm LSP istek/bildirim metotları (`definition`, `references`, `hover`, `did_open`, `did_change`) artık doğrudan `alive?` kontrolü yapmaktadır. Reader thread sonlandığında `@running = false` set edilerek bayraklar tam senkronize edilmiş; sunucu ölümü sonrası askıda bekleme ("görünürde canlı ama yanıtsız") riski tamamen bertaraf edilmiştir.
2. **AST Warmup Bağlam Takibi (`@indexer_disposable_ctx`):**
   - `@indexer_disposable_ctx` ile ters işlem kaydı yapılan bağlam referansı saklanarak aynı bağlamda ardışık `warm_ast_graph` çağrılarında mükerrer disposable birikmesi önlenmiş, yeni bağlam verildiğinde ise ters işlemin temizce kaydedilmesi güvenceye alınmıştır.
3. **Dokümantasyon Eşitlemesi:**
   - [`TOOLS.md`](../TOOLS.md) ve [`SELF_EVOLUTION.md`](../SELF_EVOLUTION.md) dosyalarında `synthesize_tool` için çalışma zamanı ön-doğrulamasının (`pre-flight`) artık zorunlu olduğu ve `test_args` verilmediğinde varsayılan `{}` argümanlarıyla izole süreçte test edildiği belgelenmiştir.
