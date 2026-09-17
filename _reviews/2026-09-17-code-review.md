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

*Kapanış durumu (2026-09-17): Bulgu 1 **KAPALI** (taktiksel iyileştirme): `RateLimitError < ClientError` tipli hata, 429 için bağımsız bütçe (`max_429_retries: 5`, genel 5xx bütçesinden ayrı), `Retry-After` onuruna tam uyum (saniye + HTTP-date, 60s cap), ipucu yoksa ±20% jitter'lı üstel backoff; streaming 429 da tipelenir. Pin: `test_llm_http_retry_policy.rb` 10 yeni test (20 run / 71 assertion yeşil). Kalan 5 bulgu açık — öncelik sırası §3.*
