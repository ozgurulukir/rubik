# 17 — Yerel (Native) LLM Function Calling ve Model Yönlendirme

**Zorluk:** Zor · **Öneri kaynağı:** §7.5 · **Faz:** 3 (Zekâ & Entegrasyon)  
**İlgili Planlar:** [09 — LLM Sağlayıcı](09-llm-saglayici-soyutlamasi.md) · [10 — Tool-Calling](10-tool-calling-orkestrasyon.md) · [16 — Genişletilmiş Araç Seti](16-genisletilmis-arac-seti-ve-planlama.md) · [Index](index.md)

## Amaç

Model ile iletişimde metin içi Markdown JSON ayrıştırması (` ```json `) yerine OpenAI, Anthropic ve Ollama'nın yerleşik (native) **Function/Tool Calling API** protokollerine geçmek; görev karmaşıklığına göre modeller arası dinamik geçiş (model routing) ve akışkan çıktı (token streaming) sağlamak.

## Görevler (kolaydan zora)

1. `Rubik::LLM::BaseProvider` için native tool tanım dönüştürücü: `Tools::Registry` şemalarını OpenAI `{"type": "function", "function": ...}` ve Anthropic `{"name": ..., "input_schema": ...}` formatlarına serileştirme.
2. `OpenAIProvider#complete` güncellemesi: `tools` ve `tool_choice: "auto"` parametrelerinin gönderilmesi; yanıt içindeki `tool_calls` dizisinin yapılandırılmış nesne olarak ayrıştırılması.
3. `AnthropicProvider#complete` güncellemesi: `tools` listesinin iletilmesi; `content` blokları içindeki `tool_use` bloklarının yakalanması ve `system` parametresiyle eşleştirilmesi.
4. `OllamaProvider#complete` güncellemesi: Ollama 0.3+ tool-calling API desteğinin ve JSON format zorlamasının eklenmesi.
5. Model Yönlendirme (Model Router):
   - Hafif görevler (sözdizimi düzeltme, formatlama): Hızlı/ucuz model (Ollama / GPT-4o-mini).
   - Ağır görevler (mimari tasarım, planlama, çoklu dosya onarımı): Güçlü model (Claude 3.5 Sonnet / GPT-4o).
6. Akışkan Çıktı (Streaming UI): Uzun yanıtlar ve düşünme adımları için Server-Sent Events (SSE) / Chunked HTTP okuma ve terminale anlık akıtma.

## Kabul Kriterleri

- [ ] OpenAI ve Anthropic sağlayıcılarında `tool_calls` doğrudan API yanıtından okunur; metin ayrıştırma hataları (regex/json parse failure) sıfıra iner.
- [ ] Model aynı anda birden fazla bağımsız araç çağrısı (`parallel tool calls`) yaparsa orkestratör bunları sırayla uygular ve toplu geri besler.
- [ ] Model yönlendirme aktifken basit syntax düzeltmeleri konfigüre edilen hızlı modele otomatik delege edilir.

## Bağımlılıklar

- [Plan 09 (LLM Sağlayıcı Soyutlaması)](09-llm-saglayici-soyutlamasi.md)
- [Plan 10 (Tool-Calling Orkestrasyonu)](10-tool-calling-orkestrasyon.md)
- [Plan 16 (Genişletilmiş Araç Seti)](16-genisletilmis-arac-seti-ve-planlama.md)

## Test Stratejisi

- Birim: OpenAI ve Anthropic native tool calling JSON yanıtlarını simüle eden mock sağlayıcı testleri.
- Entegrasyon: Paralel araç çağrısı dizisi içeren uçtan uca senaryolar.
