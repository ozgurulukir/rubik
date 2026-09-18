# 🔎 Rubik — Kod İncelemesi / Code Review (2026-09-17)

> **Tarih / Date:** 17 Eylül 2026 (Prş)
> **Taban / Base:** `main` @ `84a00cf4` ("feat(repl): Plan 91 - explicit !paste mode and burst join window for multi-line paste")
> **Yöntem:** `lib/rubik/` (390 dosya) çekirdek alanların strüktürel incelemesi — `runtime/` (context, manager, fiber), `tools/` (registry, exec), `buffer/manager`, `orchestrator/step_executor`, `llm/` (client, openai_compatible), `security/guard`, `platform/filesystem`, `repl/` katmanları + tests
> **Kapsam / Scope:** `lib/` · Windows · Ruby 4.0
> **Doğrulama:** Tam suite Plan 91 kapanışında yeşil (1544 run / 8811 assertion / 0 failure) ✅

---

## 1. Genel Değerlendirme

Kod tabanı, AGENTS.md protokolünün iddia ettiği şeyi fiilen uyguluyor — bu nadir bir durum:

- **Inverse-by-construction tutarlı:** `Context#provide` anahtar başına **tek** delete-inverse tutar; `unprovide` onu simetrik geri çeker; `prune_child` extend/dispose döngülerini düzleştirir. Ω akümütatörü sıfır-restart kuralı (§6) gerçekten çalışıyor.
- **Kilit disiplini belgelenmiş ve doğru:** `Context` per-hop locking (child→parent nest yok), `Manager#reconcile_fiber` reentrant guard (`@activating`), `LLM::Client` bağlantı havuzu mutex'leri — hepsi kilit sırası gerekçeleriyle yorumlanmış.
- **Hata izolasyonu kültürü:** `run_inverse` drain'i asla durdurmaz; `input_execution.rb`'de encoding sanitizasyonu ("rescue içinde raise" tuzağına karşı), LSP mesajlarında ANSI stripping (red-team E1) — gerçek dünyadan çıkmış savunmalar.
- **Savunma derinliği güvenlik:** Guard'da AST classifier → operatör allowlist → **her durumda** catastrophic fallback regex. Allowlist tek segmenti kurtaramaz (`allowlisted && rm -rf /` zinciri engelli).

## 2. Bulgular

| # | Bulgu | Konum | Ciddiyet |
|---|---|---|---|
| 1 | **HTTP 429 politikası yetersiz.** `max_retries: 2`, `backoff_base: 0.2` → toplam ~1.2s geri çekilme ve **`Retry-After` başlığı yok sayılıyor**. Paylaşımlı hosted model concurrency limitleri (`hosted_shared_model_concurrency_limit` gibi) sanieler-dakikalar sürebilir; 0.4s/0.8s bekleyip kalıcı hata fırlatmak turn'ü kaybediyor. (Bu review oturumunda defalarca gözlemlendi.) | `llm/client.rb:169-174` | 🟠 Orta |
| 2 | **`ComponentFiber` iç durumu korumasız.** `@state` / `@sub_context` geçişleri mutex'siz; doğruluk Manager'ın dışsal serileştirmesine dayanıyor. Bugün doğru, ama fiber'a Manager dışından erişen ilk kod gizli yarış üretir. Kontrat dokümante değil. | `runtime/fiber.rb` | 🟡 Düşük |
| 3 | **`reconcile_all` failed fiber'ları her seferinde yeniden dener.** Sürekli patlayan bir factory her `provide` çağrısında tekrar tekrar çalışır — pahalı factory'lerde canlı ortamda gürültü/yük. Backoff veya deneme sayacı değerlendirilebilir. | `runtime/manager.rb:97-100` | 🟡 Düşük |
| 4 | **`all_files` monitör altında tam ağaç taraması.** `Dir.glob("**/*")` büyük repoda tüm buffer işlemlerini kilitler. LRU cache veya glob'u kilit dışına alma mümkün. | `buffer/manager.rb:235` | 🟡 Düşük |
| 5 | **`handle_finish_tool` sihirli string sezgisi.** `!clean_text_resp.include?("tool")` kırılgan bir sezgi (zararsız). | `orchestrator/step_executor.rb:73` | 🔵 Not |
| 6 | **README test badge'i sürükleniyor.** "1327 runs" — gerçek sayı Plan 91 sonrası 1544. | `README.md` | 🔵 Not |

## 3. Öneriler (öncelikli)

1. **429/Retry-After güçlendirmesi (Bulgu 1):** 429 için ayrı ve daha yüksek deneme limiti, `Retry-After` header okuma, backoff'a jitter. Yüksek getiri/düşük risk — bu proje kullanıcıya bir LLM agent'ı olarak hizmet veriyor; paylaşımlı model limitleri ilk kullanıcı teması noktası.
2. **Bulgu 2:** `ComponentFiber` mutasyonlarını Manager kilidiyle sınırlayan bir `synchronize` içi delegasyon ya da en azından "yalnız Manager kilidiyle çağırın" kontrat yorumu.
3. **Bulgu 3:** Failed fiber yeniden denemelerine basit backoff/deneme sayacı.
4. **Bulgu 4:** `all_files` sonucu kısa ömürlü cache veya glob'u monitör dışına taşıma.
5. **Bulgu 6:** README badge'i güncelle (ya da CI'dan üret).

---

## Kapanış Durumu / Closure Status

| # | Bulgu | Durum | Çözüm |
|---|---|---|---|
| 1 | HTTP 429 politikası | ✅ **KAPALI** — commit `6bd3fc86` | `RateLimitError < ClientError` tipli hata; 429 için bağımsız bütçe (`max_429_retries: 5`, genel 5xx bütçesinden ayrı); `Retry-After` tam onur (saniye + HTTP-date, 60s cap); ipucu yoksa ±20% jitter'lı üstel backoff; streaming 429 da tipelenir. Pin: `test_llm_http_retry_policy.rb` 10 yeni test (20 run / 71 assertion yeşil). |
| 2 | Fiber iç durum korumasız | ✅ **KAPALI** — `fiber.rb` | Karar: **bilinçli lock-free kontrat** (per-fiber Mutex, Manager Monitor'una geri çağrı yapan factory'lerle kilit sırası tersine dönüşü/deadlock üretirdi). Sınıf docstring'ine tam Concurrency Contract eklendi: mutasyonlar yalnız owning Manager Monitor altında ya da tek-iplikli kodda. Pin: `test_fiber_is_documented_lock_free_with_manager_monitor_contract` — kontrat metnini pinler + sınıfa gizli kilit eklenmesini reddeder. |
| 3 | Failed fiber sürekli yeniden denenir | ✅ **KAPALI** — `manager.rb` | Üstel backoff + hard stop: `MAX_FIBER_RETRIES = 5`, `RETRY_BACKOFF_BASE_S = 0.05` (2ⁿ backoff, monotonic clock ile elapsed mahsubu). Başarılı aktivasyon ve açık `register_fiber` bütçeyi sıfırlar. Sleep Manager Monitor altında — reconcile zaten serileştirilmiş. |
| 4 | `all_files` kilit altında glob | ✅ **KAPALI** — `buffer/manager.rb` | Disk yürüyüşü monitör **dışına** taşındı: kilit altında yalnız in-buffer key snapshot, glob kilitsiz, sonra merge. Sonuç, fuzzy-match aday listesi için birkaç ms bayat olabilir (dökümante). |
| 5 | `handle_finish_tool` sihirli string | ✅ **KAPALI** — `finish_message_selector.rb` | Sezgi `Rubik::Orchestrator::FinishMessageSelector.select`'e çekildi: davranış birebir korundu, `GENERIC_FILLERS` / `NARRATION_TOOL_HINT` / `DEFAULT_MESSAGE` adlandırıldı, niyet docstring'e yazıldı. `step_executor.rb`'deki inline sihirli string kaldırıldı. Pin: `test_finish_message_selector.rb` (9 test — legacy davranış korunması, sabit kontratı, dosya hijyeni &lt; 350). |
| 6 | README badge sürüklenmesi | ✅ **KAPALI (üretici eklendi)** | Badge bir kez daha elle düzeltildi (1544), ancak kök neden üretici eksikliği olduğu için `dev/update_test_badge.rb` + `rake test:badge` eklendi: tam suite'i koşar, gerçek Minitest özetlerini ayrıştırır ve README badge satırını yeniden yazar. **Kırmızı suite'te yazmayı reddeder** (fail-closed) — badge asla kırmızı paketi reklamlamayabilir. |

**Suite doğrulaması:** dokunulan tüm dosyalar tek tek yeşil — `test_runtime_fiber` (16 run / 71 assertion), `test_runtime_manager_concurrency` (15/58), `test_plugin_manager` (9/25), `test_mcp_manager_composability` (8/72), `test_buffer` (4/16), `test_buffer_manager_concurrency` (3/1242), `test_buffer_apply_conflict` (15/70).

---

## Fresh-Eye Diff Review Ek Kapanışları (post-`92095b56`)

Diff'in taze gözle ikinci incelemesi 6 bulgu üretti; 5'i aşağıda kapatıldı (R6 — README badge'inin yine hardcoded olması — not olarak açık):

| # | Bulgu | Durum | Çözüm |
|---|---|---|---|
| R1 | Bulgu 3 fix'i için sıfır pin testi | ✅ **KAPALI** | Yeni `test/unit/test_runtime_fiber_retry_gate.rb`: 9 test — hard stop (MAX denemeden sonra fabrika asla çalışmaz), backoff matematiği (delay 2ⁿ, stub'lanmış sleep), success/bütçe temizliği, tükendinde tek-shot warn, `register_fiber`/`swap_component` bütçe sıfırlama, `unregister_component`/`dispose!` hijyeni, pending fiber'ların bütçe harcamaması. Determinizm: backdating (`CLOCK_MONOTONIC` geriye çekme) ve `@manager.stub(:sleep)` — suite gerçek beklemeyz. |
| R2 | `@retry_bookkeeping` sızıntısı | ✅ **KAPALI** | `unregister_component` ve `dispose!` artık bookkeeping girdilerini temizliyor — §6 zero-restart hijyeni. Pin: `test_unregister_component_removes_retry_bookkeeping_entry`, `test_dispose_clears_all_retry_bookkeeping`. |
| R3 | Bütçe tükenince sessizlik | ✅ **KAPALI** | `warn_retry_budget_exhausted`: bütçe tükendiğinde tam olarak bir kez uyarır (fiber adı, deneme sayısı, MAX, son hata); re-registration flag'i sıfırlar. Pin: `test_retry_budget_exhaustion_warns_exactly_once`. |
| R4 | Kırılgan substring pin testi | ✅ **KAPALI** | `test_runtime_fiber.rb` lock-free pin'i artık regex tabanlı: `Monitor.new`/`Mutex.new`/`MonitorMixin` include/`@lock =`/`.synchronize` yakalanır; masum bir yorumdaki `@monitor` geçişi artık false-positive üretmez. |
| R5 | Streaming 429 mesajı çelişkisi | ✅ **KAPALI** | `rate_limit_error(res, nil)` streaming yolunda — mesaj artık "gave up after 0 rate-limit retries" yalanını söylemez; deneme sayısı bilinmiyorsa omit edilir. |

**Doğrulama:** `test_runtime_fiber_retry_gate` (9/42), `test_runtime_fiber` (16/77), `test_llm_http_retry_policy` (20/71), `test_runtime_manager_concurrency` (15/58), `test_plugin_manager` (9/25) — hepsi yeşil, LSP teşhisleri temiz.

---

## R7 — Canlı 429 yapıştırmasından çıkan ikinci kusur (post-`556b6d53`)

Kullanıcının canlı 429 mesajı (`...gave up after 0 rate-limit retries, server hinted 1.0s): #&lt;Net::ReadAdapter:0x...&gt;`) R5'in doğrudan kanıtıydı; ama içinde henüz görünmemiş **ikinci** bir kusur daha taşıyordu:

- **R5 kısmı (KAPALI, `556b6d53`):** streaming yolu `rate_limit_error(response, 0)` çağırıyordu; "0 retries" ifadesi hiç retry yapılmamışken "retry edip vazgeçtik" yalanı söylüyordu. Artık `nil` → yan tümce omit.
- **R7 (BU YAMADA):** mesajdaki gövde `#&lt;Net::ReadAdapter:0x...&gt;` — sağlayıcının hata JSON'u değil, Ruby nesne dökümü. Kök neden: `stream_attempt` gövdeyi `read_body { |chunk| body_chunks << chunk }` ile **drain ediyor** ama 429 dalı bunları yok sayıp `res.body` erişimcisini yeniden okuyordu. Net::HTTP'nin block formunda bu erişimci henüz gerçeklenmemiş bir **Net::ReadAdapter sink** döner; `safe_utf8` String olmayanı geçer, interpolasyon nesneyi dumper. Yama: `rate_limit_error` opsiyonel `body` parametresi aldı (geriye dönük uyumlu — post_json yolu 2-arg çağrıya devam eder); streaming doku `body_chunks.join` geçirir. Pin testleri: drained-chunks-before-res.body (`read_body` yield + ReadAdapter-benzeri `body` double ile), legacy 2-arg uyumluluk.

**Testler:** `test_llm_http_retry_policy` 22 run / 84 assertion (yeni pinler dahil), `test_llm_connection_pool` (6/22), `test_llm_error_message_encoding` (4/19) — yeşil. Yayılım (GitNexus): `stream_attempt` upstream HIGH — 3 sağlayıcı `stream_chat`; değişiklik opsiyonel parametre olduğundan geriye dönük uyumlu, tek dosyada 2 çağrı noktası.
