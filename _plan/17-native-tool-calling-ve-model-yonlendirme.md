# 17 — Yerel (Native) LLM Function Calling ve Yapılandırılabilir Model Yönlendirme (Router)

**Durum:** ✅ **Tamamlandı** · **Zorluk:** Zor · **Öneri kaynağı:** §7.5 · **Faz:** 3 (Zekâ & Entegrasyon)  
**İlgili Planlar:** [09 — LLM Sağlayıcı](09-llm-saglayici-soyutlamasi.md) · [10 — Tool-Calling](10-tool-calling-orkestrasyon.md) · [16 — Genişletilmiş Araç Seti](16-genisletilmis-arac-seti-ve-planlama.md) · [Index](index.md)

## Amaç

Model ile iletişimde metin içi Markdown JSON ayrıştırması (` ```json `) yerine OpenAI, Anthropic ve Ollama'nın yerleşik (native) **Function/Tool Calling API** protokollerine geçmek; görev karmaşıklığına göre modeller arası dinamik geçiş (model routing) ve yapılandırılabilir (`fast`, `advanced`, `default`) rol mimarisi sağlamak.

## Tamamlanan Görevler

1. `Rubik::LLM::Response`: Yerel `tool_calls` dizisini ve `has_tool_calls?` metodunu destekleyecek şekilde güncellendi.
2. `OllamaProvider#complete`: `tools` formatlayıcısı eklendi; `/api/chat` yanıtındaki `message.tool_calls` bloklarını yapılandırılmış `tool_calls` nesnesine dönüştürme sağlandı.
3. `OpenAIProvider#complete`: `tools` şeması gönderimi ve `choices[0].message.tool_calls` ayrıştırması eklendi.
4. `AnthropicProvider#complete`: `tools` (`input_schema`) dönüştürücüsü ve `content` içindeki `tool_use` bloklarının parse edilmesi sağlandı.
5. `Rubik::LLM::Router`:
   - Yapılandırılabilir model rolleri (`default`, `fast`, `advanced`).
   - Otomatik görev sınıflandırma (`:auto` modunda mimari/planlama kelimelerinde `:advanced`, sözdizimi/diagnostik kelimelerinde `:fast`).
   - Manuel (`manual`) ve otomatik (`auto`) yönlendirme modları.
6. `Rubik::Config`: `models` ve `router` hiyerarşisi, `model_spec(role)`, `set_model_spec(role, ...)` ve immutable `deep_dup` / `deep_merge` mekanizması.
7. REPL `!model` Komutu Geliştirmesi:
   - `!model` (mevcut roller ve yönlendirme modunu listeler).
   - `!model set <default|fast|advanced> <provider/name>` (rol modelini günceller).
   - `!model route <auto|manual>` (yönlendirme modunu değiştirir).
8. `Orchestrator::Loop`: Native `tool_calls` desteği ve regex fallback uyumu birleştirildi.

## Kabul Kriterleri

- [x] OpenAI, Anthropic ve Ollama sağlayıcılarında `tool_calls` doğrudan API yanıtından okunur; metin ayrıştırma hataları sıfıra iner.
- [x] Model aynı anda birden fazla bağımsız araç çağrısı yaparsa orkestratör bunları sırayla uygular ve toplu geri besler.
- [x] Model yönlendirme aktifken basit syntax düzeltmeleri konfigüre edilen hızlı modele (`fast`), mimari/planlama görevleri gelişmiş modele (`advanced`) otomatik delege edilir.
- [x] `!model set` ve `config.yml` üzerinden model eşlemeleri dinamik olarak güncellenir.

## Bağımlılıklar

- [Plan 09 (LLM Sağlayıcı Soyutlaması)](09-llm-saglayici-soyutlamasi.md)
- [Plan 10 (Tool-Calling Orkestrasyonu)](10-tool-calling-orkestrasyon.md)
- [Plan 16 (Genişletilmiş Araç Seti)](16-genisletilmis-arac-seti-ve-planlama.md)

## Test Kapsamı

- `test/unit/test_native_tool_calling_and_router.rb`: Native tool calling akışı, Router rol seçimi, manuel mod, dinamik `!model set` ve `!model route` komutları birim testleri.
