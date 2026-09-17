# 🏛️ Rubik — Mimari İnceleme / Architectural Review (2026 Follow-up)

> **Tarih / Date:** 16 Eylül 2026 (Çrş)
> **Taban / Base:** `main` @ `6d1e5064` ("fix(tools): enforce UTF-8 hygiene across the tool-output and file-read pipeline") — 2026-09-14 review kapanış durumunun üstü (tüm bulgular kapatılmıştı)
> **Yöntem:** Mimari sınır testleri çalıştırması, 23 alanın grid taraması, çekirdek dosya outline incelemesi, EventBus/Coeffect/Config telemetri analizi
> **Kapsam / Scope:** `lib/` (216 dosya, ~28.3k LOC, 23 alan) · `test/` (~28.9k LOC) · Windows · Ruby 4.0
> **Doğrulama:** `bundle exec ruby test/unit/test_architectural_boundaries.rb` → 5 test, 10 assertion, **0 failure** ✅

---

## 1. Mimari Harita (kodla doğrulanmış / verified against code)

```
bin/rubik → REPL::Shell (kompozisyon kökü: Composition.build → Lifecycle.warm_up!)
    ├─ REPL mixin'leri (lifecycle, composition, config_wiring, input_execution, presentation…)
    ├─ Orchestrator::Loop ──ShellDeps façade──→ StepExecutor / BudgetManager / StreamManager / ProviderResolver
    ├─ Runtime::Manager ──→ Context (Ω LIFO inverses + coeffects) ──→ ComponentFiber state machine
    ├─ Tools::Registry (22 built-in, coeffect-gated, tek monoidal teardown inverse'i)
    ├─ LLM (Router → OpenAI/Anthropic/Ollama formatter'ları), AST, LSP, MCP, Sandbox, Security, Plugin
    └─ EventBus, Session, UI, Prompt, Repair, Benchmark
```

**Bağımlılık yönü sağlıklı ve CI'la kilitli.** `orchestrator/runtime/tools/llm` içinden `repl`'e sıfır `require_relative`; `rubik.rb` düz 25-require kompozisyon kökü. Tek bilinçli ters yön (`runtime → orchestrator`, `LoopService.build_loop`) — ajan döngüsünün kendisi reaktif fiber olduğu için protokolle tutarlı.

## 2. Güçlü Yönler ✅

1. **Protokol sadakati gerçek.** `Runtime::Context` AGENTS.md spesifikasyonunu referans deseni aşarak uyguluyor: per-hop locking + açıkça belgelenmiş kilit sırası (child, parent'a uzanırken kendi monitor'unu bırakıyor; deadlock vakası tam satırda notlanmış), simetrik `unprovide` geri çekmesi, seal sonrası geç inverse icrası (sessiz sızıntı yerine), `prune_child` ile flat extend/dispose döngüleri (Ω baseline'a döner).
2. **Mimari değişmezler prose değil, CI.** Beş guard testi: core→repl require yasağı, kompozisyon kökü dışında ambient global okuma yasağı, lib'de çıplak `Fiber` alias yasağı, işbirlikçilerde çıplak `@loop` ivar erişimi yasağı, Loop→Shell dokunuşlarının gerekçeli allowlist'e indirgenmesi.
3. **Reentrancy ve eşzamanlılık olgunluğu.** `Manager#reconcile_fiber`'da `@activating` işaretleyicisi (factory kendi bağımlılığını yeniden provide ederken), gerekçeli rubocop-disable'lı snapshot iterasyonu, dayanılan yerlerde belgelenmiş reentrant `Monitor` semantiği.
4. **Disiplinli parçalanma.** En büyük dosya ~450 satır; Shell 211 satıra indi; Loop belgelenmiş ShellDeps façade'ı üzerinden devrediyor (§7.1 SURFACE / komut yüzeyi / tur-sonuç sözleşmesi). Test:code oranı >1:1 (28.9k/28.3k), ölçülmüş %64.5 paralel test kazancı.
5. **Çalışan review→plan→uygula→doğrula döngüsü.** Önceki review'un 8 revizyonu her bulgunun commit, pin testi ve kanıtla kapatıldığını belgeliyor (`_plan/`, `_reviews/`, `dev/`). Repodaki en güçlü süreç sinyali bu.

## 3. Yeni Bulgular ⚠️

| # | Bulgu | Ciddiyet |
|---|---|---|
| 1 | **EventBus ateşle-unut log'u, omurga değil.** Lib 9 olay yayınlıyor (`buffer_*`, `config_changed`, `prompt_received`, `ast_warm_failed`) ama lib içinde **sıfır abone** — tüm abonelikler testlerde. ARCHITECTURE.md satır 8 ona "Pub/Sub omurgası" diyor. Ya eklenti/dış gözlemci için uzatma yüzeyi olarak belgelenmeli ya da doküman düzeltilmeli. | 🟡 Düşük |
| 2 | **Üç paralel "bir şey değişti" kanalı.** (a) `Config#on_change` doğrudan callback'ler (ConfigWiring ~12 tutuyor), (b) `EventBus :config_changed`, (c) reaktif coeffect reconcile. İlkel olan yol (c) — bildirilen bağımlılıklar → reconciled fiber; `on_change` pragmatik önek eşleme; EventBus burada atıl. Konsolidasyon ya da açık iş-bölümü dokümanı gerekiyor. | 🟠 Düşük-Orta |
| 3 | **Coeffect anahtarlarında SSOT kayması.** `wire_runtime_context` şu servisleri yayınlıyor: `config`, `events`, `guard`, `sandbox`, `plugin_manager`, `plugin_storage` — hiçbiri `Rubik::Coeffects`'te bildirili değil. Çalışıyor (genel `has?`), ama SSOT modülü iddia ettiği bağımlılık sözleşmesi olarak eksik kalıyor. | 🟡 Düşük |
| 4 | **Metot seviyesi kör noktalar tahmin edilen yerde sürüyor.** `LoopService.build_loop` `shell&.build_tool_registry` ve `shell&.config` fallback'i kullanıyor — §7.1'in statik analizin göremeyeceğini söylediği duck-type sınıfı. Guard testleri `@loop`/`@shell` ivarlarını kapsıyor ama nesneler-arası duck-type fallback'leri değil. | 🟡 Düşük |
| 5 | **Tam `rake test` Windows'ta hâlâ pratik değil** (çalıştırmam timeout'a uğradı; önceki ölçüm: serial ~33 dk, default task ~8 dk). `test:fast`, `test:parallel[4]` gibi hızlı döngüler var; default task hâlâ yavaş serial yol. | 🟠 Orta |
| 6 | **Dil ayrımı:** kanonik dokümanlar (README, ARCHITECTURE) Türkçe; protokol/araç yüzeyi (AGENTS.md, tool şemaları) İngilizce. Uluslararası bir OSS harness için İngilizce kanonik set düşünülebilir. | ℹ️ Bilgi |

## 4. Çözülmüş ve Doğrulanmış (önceki review kalemleri)

- **Ambient root gün batımı:** pratikte tamam — `Rubik.runtime`'ın tek (test) okuyucusu warn-once deprecation köprüsü arkasında; guard testi lib'de sıfır okuma zorunlu tutuyor. ✅
- **Shell/Loop genişliği:** satır-bütçe pin testleriyle sınırlı (300 taban / <350 hedef). ✅
- **Fiber adlandırma çakışması:** alias geriye uyumluluk için korundu + pin testi + ban guard'ı. ✅

## 5. Öneriler (öncelikli)

1. **Tek değişiklik-bildirimi hikâyesi seçin.** (Tavsiye: coeffect reconcile kanonik; `on_change` shell-lokal kablolama için kalsın; EventBus ya aboneyle beslensin ya dış/eplenti gözlem yüzeyi olarak yeniden belgelensin.) Bulgu 2+3 tek küçük PR'da kapanır: `Coeffects` SSOT'una eksik anahtarlar + ARCHITECTURE.md'ye bildirim topolojisi bölümü.
2. **Default `rake test`'i paralel yola çevirin** (pilot flake oranı birkaç hafta CI'da kanıtlandıktan sonra); serial `test:serial` olarak kalsın.
3. **Duck-type fallback guard'ı ekleyin:** sınır testi paketine `LoopService` dışında `shell&.build_*` fallback yasağı (ya da mevcut allowlist deseniyle her biri gerekçelensin).
4. **Opsiyonel:** İngilizce kanonik dokümanlar; Türkçe ikincil.

## Sonuç

Mimari gerçekten iyi durumda: protokol alışılmadık bir titizlikle uygulanmış, değişmezler mekanik olarak zorunlu tutuluyor, ekibin review'la evrim süreci bulguları kanıtla kapatıyor. Kalan iş yapısal borç değil; doküman-hizalama ve test-altyapısı ergonomisi.

---

*Kapanış durumu (2026-09-16): 2026-09-14 review'ının tüm bulgu/önerileri kapalı (Revizyon 9). Bu follow-up'taki 6 bulgu açık — öncelik sırası §5'te.*
