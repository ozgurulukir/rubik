# Plan: Doğrulanmış MEDIUM Bulgu Düzeltmeleri — 2026-09-25

> **Durum:** ✅ Tamamlandı (2026-09-25)
> **Kaynak:** 4 doğrulama ajanının verdict raporu. Aşağıdakiler **TRUE** (M12/M17 **PARTIAL**, M6 **PARTIAL**).
> **Protokol:** [`AGENTS.md`](../AGENTS.md) §A (Revertible Effects), §5 (Atomic Rollback), §6 (Zero-Restart); güvenlik kapıları (Plan 59/60/79).
> **Kapsam:** M1*, M2*, M3, M4, M5, M6, M7, M9, M11, M12, M13, M15, M17, M19.
> (*M1/M2 HIGH planı W2/W3'te ele alınır; burada çapraz referans.)
> **Zorluk:** Orta · **Faz:** 6 (Sağlamlaştırma + Güvenlik Sıkılaştırma)

## Bağlayıcı kararlar (verdict kaynaklı)
- M10 (sandbox env), M14 (YAML), M18 (TTY) **REFUTED** → iş yok.
- M9 (symlink fail-open) **bilinçli fail-open** yorumu taşıyor; kullanıcı kararı: containment için **fail-closed**, yalnız read-only teşhis yollarında fail-open kalabilir.
- M12: `atomic_write` `platform/filesystem.rb`'de (verdict düzeltmesi), `path.rb` değil; root-prefix bug gerçek.

## İş kalemleri

- **W1 (M9)** `platform/path.rb` `resolved_path_under?` / symlink-aware containment: IO çözümleme hatasında **fail-closed** (containment "unprovable" → erişim reddi). Read-only gösterim için ayrı `best_effort` varyantı korunur. Yazma/çalıştırma karar yolu asla fail-open olmaz.
- **W2 (M12)** `platform/path.rb` `path_under?`: `n_child.start_with?("#{n_parent}/")` prefix karşılaştırması root/drive-root için bozulur. Normalize edilmiş ebeveyn `/` veya `C:/` ise özel-durum; ebeveyn sonundaki ayraç kaldırılır (`chomp("/")`), ardından `child.starts_with?(parent + "/")` veya `File::SEPARATOR` invariantı.
- **W3 (M12)** `platform/filesystem.rb` `atomic_write`: unlink-then-rename (TOCTOU). Aynı dizinde `.tmp.<pid>` oluştur → `fsync` → `File.rename` (POSIX atomik) veya Windows için `File.rename` retry; hedef doğrulaması yazma öncesi yeniden yapılır.
- **W4 (M11)** `security/guard.rb` `verify_path_write!`: trivial `gsub(%r{^\./}, "")` yerine `File.expand_path` + `Platform.normalize_path_raw` ile normalize edilmiş göreli yol kritik-yol eşleşmesine sokulur. `..` ve sembolik kaçışlar eşleşmeden önce çözülür.
- **W5 (M13)** `security/guard.rb` Windows allowlist: `File.basename(arg, ".*").casecmp?(File.basename(token, ".*"))` uzantı-silici ve büyük/küçük-harf-duyarsız → `git` ≈ `git.cmd`/`GIT`. Çözüm: `argv[0]`'ı `Platform.which` ile gerçek yürütülebilir yola çöz ve **kanonik tam yol** karşılaştır; uzantı yalnız `.exe/.cmd/.bat` allowlist eşlemesinde açıkça listelenir.
- **W6 (M13/LOW)** argv-prefix allowlist zincir over-match: allowlist girdileri tam-yol kanonikleştirildikten sonra prefix eşleşmesi yeniden gözden geçirilir; `&&`/pipe zincirleri tek komut gibi eşleşemez (guard fallback ile koupling daraltılır).
- **W7 (M7)** `ast/cache_store.rb`: cache anahtarı `[mtime.to_i, size]` → saniye-altı çözünürlük + içerik hash'i. `mtime.to_f`/`nsec` veya SHA1(content). Aynı-saniye aynı-boyut edit'inde stale hit önlenir.
- **W8 (M4)** `lsp/client.rb` JSON-RPC header parse: tek `Content-Length` header varsayımı → `\r\n` sonuna kadar **tüm** header satırlarını oku (`Content-Type` vb. yankı/duplicate güvenli), boş satırda gövdeye geç.
- **W9 (M5)** `lsp/client.rb`: timeout sonrası `@responses` büyümesi → pending response tablosuna TTL/boyut sınırı; `$/cancelRequest` bildirimi gönderilir. Late reply güvenle atılır (id eşleşmezse discard).
- **W10 (M6)** `lsp/client.rb` path-key: `/`-assumed strip Windows'ta `\` ile uyuşmaz; `path_equal?` fallback gerçek ama birincil anahtar normalizasyonu `Platform.normalize_path_raw` üzerinden yapılır.
- **W11 (M3)** `runtime/task_manager.rb`: `kill_all` teardown inverse eksik. `at_exit` (var) yanında `ctx.on_dispose { kill_all }` kaydedilir; child process ağaçları (kill-tree) teardown'da temizlenir.
- **W12 (M15)** Secret redaction: `lib/` içinde `redact` yok. YENİ `security/redactor.rb` — bilinen secret desenleri (`sk-…`, `ghp_…`, `AKIA…`, `-----BEGIN … PRIVATE KEY-----`, `password=`/`token=`) regex seti ile maskeleme. Audit log, komut echo, diff çıktısı ve captured stdio yollarından geçirilir. Tek giriş noktası `Security::Redactor.redact(str)`.
- **W13 (M17)** `llm/client.rb` retry: exponential backoff'a **jitter** + toplam wall-clock cap. `llm/anthropic.rb`: flat `read_timeout` yerine **idle-reset** (her chunk'ta timeout yenilenir) → sessiz uzun stream abort olmaz.
- **W14 (M19)** `ui/ui.rb` re-registration spinner leak: dispose inverse yalnız ilk kayıtta kuruluyor ve eski renderer'ı closure'lıyor. Re-register'da eski spinner kill edilir; inverse `ctx.get("ui") || renderer` aktif referansa bağlanır.

## Commit planı (conventional)
1. `fix(platform): fail closed on symlink containment and fix root prefix` (W1, W2)
2. `fix(platform): make atomic_write rename-only to close TOCTOU` (W3)
3. `fix(security): normalize paths and canonicalize Windows allowlist` (W4, W5, W6)
4. `fix(ast): sub-second mtime plus content hash cache key` (W7)
5. `fix(lsp): robust header framing, response TTL, cancel and path keys` (W8, W9, W10)
6. `fix(runtime): tear down task trees via kill_all inverse` (W11)
7. `feat(security): central secret redactor for logs, echo, diff and stdio` (W12)
8. `fix(llm): jittered retries and idle-reset stream timeout` (W13)
9. `fix(ui): kill stale spinner on re-registration` (W14)

## Test haritası
- W1/W2/W3 → `test/unit/test_path_containment.rb` (yeni), `test/unit/test_write_file_path_validation.rb`.
- W4/W5/W6 → `test/unit/test_security_guard.rb`, `test/unit/test_security_guard_classifier.rb`.
- W7 → `test/unit/test_ast_cache_store.rb` (same-second same-size edit).
- W8/W9/W10 → `test/unit/test_lsp_client.rb` (çok-header, timeout+cancel, Windows anahtar).
- W11 → `test/unit/test_task_manager.rb` (kill_all inverse).
- W12 → `test/unit/test_redactor.rb` (yeni) + audit/echo/diff entegrasyon pinleri.
- W13 → `test/unit/test_llm_retry.rb`, provider recovery pinleri.
- W14 → `test/unit/test_ui_registration.rb`.

## Uygulama sırası
W12 (en izole, güvenlik) → W1 → W2 → W3 → W4 → W5 → W6 → W7 → W8 → W9 → W10 → W11 → W13 → W14 → tam suite + GitNexus `detect-changes`.

## Kritik tuzaklar
- **W1 fail-closed**: read-only teşhis akışları (path gösterimi) fail-closed olursa UX bozulur → iki varyant net ayrılmalı.
- **W3 rename-only**: Windows'ta `File.rename` hedef var ise hata verebilir → retry/atomic replace politikası platforma göre.
- **W12 redaction**: aşırı-agresif maskeleme diff/hash içeriğini bozar → desenler dar tutulur, test pinleri gerçek secret örnekleriyle.
- **W5 kanonik yol**: `which` bulunamazsa (script, builtin) fallback davranışı fail-closed mı fail-open mı — netleştir; aksi halde yeni bypass.
- **W9 cancel**: bazı LSP sunucu `$/cancelRequest` desteklemez → sessizce yok say.
- Her sembol öncesi **GitNexus impact**; `verify_path_write!`, `path_under?`, `atomic_write`, allowlist match HIGH-risk.

---

## Uygulama ve Doğrulama Raporu (2026-09-25)

### 1. Tamamlanan Değişiklikler
- **W1 & W2 (M9 & M12)**: `lib/rubik/platform/path.rb`
  - `path_under?`: `chomp("/")` ve `File::SEPARATOR` ile root/drive-root prefix karşılaştırması düzeltildi.
  - `resolved_path`: `strict: true` (containment kontrolü için fail-closed) ve `resolved_path_best_effort` (UI/diagnostics için) eklendi.
  - `resolved_path_under?`: IO hatasında fail-closed davranışı uygulandı.
- **W3 (M12)**: `lib/rubik/platform/filesystem.rb`
  - `atomic_write`: TOCTOU unlink kaldırıldı. Temp dosyaya fsync ile yazılıp `File.rename` ile atomik olarak taşınır (Windows için transient lock retry ve fallback mekanizmasıyla).
- **W4, W5, W6 (M11 & M13)**: `lib/rubik/security/guard.rb`
  - `verify_path_write!`: `Platform.normalize_path_raw` ve `File.expand_path` ile normalize edilmiş göreli yol kontrolü yapıldı.
  - Windows allowlist: `Platform.which` ile `canonical_binary_path` üzerinden tam yol kanonizasyonu.
  - Chained command allowlist: `&&`, `;`, `|` ile birbirine bağlanan komutların her birinin ayrı ayrı allowlist'e girmesi zorunlu kılındı.
- **W7 (M7)**: `lib/rubik/ast/cache_store.rb`
  - Cache girdileri `mtime_f` (sub-second) ve dosya SHA1 digest'i ile saklanır. `valid_entry?` aynı-saniye aynı-boyut düzenlemelerinde stale hit üretmez.
- **W8, W9, W10 (M4, M5, M6)**: `lib/rubik/lsp/client.rb`
  - Header framing: Boş satıra kadar tüm HTTP/RPC header satırlarını parse eder (`Content-Length` header sıralamasından bağımsız).
  - Yanıt kuyruğu yönetimi: Timeout durumunda `$/cancelRequest` bildirimi gönderilir; `@responses` boyutu 100 ile sınırlandırılmıştır; geç gelen istenmeyen yanıtlar atılır.
  - Windows yol anahtarı: `Rubik::Platform.normalize_path_raw` ile tutarlı normalizasyon.
- **W11 (M3)**: `lib/rubik/runtime/task_manager.rb`
  - `bind_context`: `@context.on_dispose { kill_all }` LIFO ters kaydı bağlandı; `dispose` alias'ı eklendi.
- **W12 (M15)**: `lib/rubik/security/redactor.rb`
  - Merkezi gizli bilgi maskeleme sınıfı oluşturuldu (`Security::Redactor.redact`).
  - Guard mask_text, Recorder mask_text, DiffViewer render, ProcessDriver stdio yakalama ve REPL komut yankısına entegre edildi.
- **W13 (M17)**: `lib/rubik/llm/client.rb`, `lib/rubik/llm/anthropic.rb`, `lib/rubik/llm/openai_compatible.rb`
  - `post_json`: Retry backoff'a `(0.8 + (0.4 * rand))` jitter + `max_wall_clock: 120` sınırı eklendi.
  - `post_stream_json`: `idle_timeout` desteği eklendi; her chunk okumasında timeout sıfırlanır (Net::HTTP read_timeout).
  - `AnthropicProvider` ve `OpenAICompatibleProvider`: `stream_chat` içinde `idle_timeout` parametresi desteklendi.
- **W14 (M19)**: `lib/rubik/ui.rb`
  - UI re-registration (`RenderService.register`): Yeniden kayıt anında eski renderer'ın çalışan spinner'ı `existing_renderer.spinner&.kill` ile anında durdurulur; omega akümülatörü sızıntısı önlenir.

### 2. Doğrulama ve Test Sonuçları
- `test/unit/test_redactor.rb`: 8 runs, 25 assertions, 0 failures, 0 errors.
- `test/unit/test_path_containment.rb`: 7 runs, 12 assertions, 0 failures, 0 errors.
- `test/unit/test_security_guard.rb`: 13 runs, 60 assertions, 0 failures, 0 errors.
- `test/unit/test_command_allowlist.rb`: 22 runs, 54 assertions, 0 failures, 0 errors.
- `test/unit/test_ast_persistent_cache.rb`: 16 runs, 124 assertions, 0 failures, 0 errors.
- `test/unit/test_lsp_client.rb`: 8 runs, 31 assertions, 0 failures, 0 errors.
- `test/unit/test_task_manager.rb`: 19 runs, 94 assertions, 0 failures, 0 errors.
- `test/unit/test_llm_retry.rb`: 4 runs, 27 assertions, 0 failures, 0 errors.
- `test/unit/test_llm_http_retry_policy.rb`: 22 runs, 84 assertions, 0 failures, 0 errors.
- `test/unit/test_ui_registration.rb`: 5 runs, 10 assertions, 0 failures, 0 errors.
- `test/unit/test_module_hygiene.rb`: 11 runs, 80 assertions, 0 failures, 0 errors (tüm satır sınırları korundu).
- `bundle exec rubocop` (değiştirilen/yeni dosyalar): 8 files inspected, no offenses detected.
- GitNexus `detect-changes`: 21 files, 93 symbols, 53 affected execution flows analiz edildi.

### 3. Diff Review & Post-Implementation Audit (2026-09-25)
- **Kapsam:** `e32e0631..HEAD` commit aralığı ve tüm 26 değişen dosya bağımsız diff incelemesine tabi tutuldu.
- **Bulgular & Düzeltmeler:**
  1. `test/unit/test_path_containment.rb`: `SystemDrive` çevre değişkeni sondaki ayraca karşı `chomp('/')` ile sağlamlaştırıldı (`C://` biçim bozukluğu riski giderildi).
  2. `lib/rubik/llm/client.rb`: Operatör önceliği ve rubocop guard clause boş satır gereksinimleri giderildi; `rate_limit_retries` isimlendirmesi standartlaştırıldı; `max_wall_clock: 120` değeriyle 60s Retry-After tavanı altında kalan isteklerin güvenle işlenmesi sağlandı.
  3. `test/unit/test_llm_retry.rb`: Kullanılmayan blok parametreleri (`_terminator`, _state) düzeltildi ve minitest/rubocop kurallarına tam uyum sağlandı.
- **Genel Değerlendirme:** Tüm mimari değişmezler (AGENTS.md spatiotemporal composability, revertible effects, reactive coeffects, atomic rollbacks) ve güvenlik kapıları eksiksiz olarak doğrulanmıştır. Plan durumu **✅ Tamamlandı ve Doğrulandı** olarak onaylanmıştır.


