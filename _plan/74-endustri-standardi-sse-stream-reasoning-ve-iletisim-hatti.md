# 📋 Plan 74: Endüstri Standardı SSE Streaming Ayrıştırması, Düşünce Akışı (Reasoning) Entegrasyonu, Kesilme Teşhisi ve Özelleştirilebilir İletişim Hattı (W3C-Compliant SSE, Reasoning Tokens, Finish Diagnostics & Custom Headers)

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** Orta · **Faz:** 6 (Gelişmiş Ajan Ergonomisi & İletişim Sağlamlığı)  
> **İlgili Planlar:** [09](09-llm-saglayici-soyutlamasi.md), [17](17-yerel-arac-cagrilari-ve-router.md), [22](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md), [30](30-dinamik-llm-saglayicilari-ozel-endpointler-ve-baglam-limiti.md), [42](42-orchestrator-loop-dekompozisyonu-ve-llm-formatlayici.md), [56](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md), [61](61-llm-baglam-surekliligi-hata-turlerinde-kayit-ve-stream-butunlugu.md), [73](73-arac-katmani-sertlestirme-kapsulleme-ve-hata-ayristirma.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

Rubik'in LLM iletişim ve akış (streaming) katmanında, modern LLM sağlayıcıları (InferX, vLLM, Ollama, OpenRouter, Groq, DeepSeek) ve ters proxy'ler (Nginx, Cloudflare, Envoy, Traefik) karşısında ortaya çıkan 4 kritik zafiyet tespit edilmiştir:

### 1.1. W3C Uyumsuz SSE Ayrıştırması ve CRLF (`\r\n\r\n`) Akış Felci (`client.rb:22-42`)
- **Mevcut Durum:** [`Rubik::LLM::SSEParser`](file:///home/aristo/Projects/rubik/lib/rubik/llm/client.rb#L21-L75) sabit olarak `@terminator = "\n\n"` aramaktadır.
- **Kritik Zafiyet:** Standart HTTP/1.1 proxy'leri ve web sunucuları SSE event'lerini `\r\n\r\n` (CRLF CRLF) ile sonlandırır. Ruby'de `"\r\n\r\n".index("\n\n")` değeri `nil` döner!
- **Sonuç:** Gelen akış boyunca `parser.feed` hiçbir event üretemez (`events: 0`). Akış kapandığında `flush` tüm ham akışı tek bir blok olarak yığar. Bu blokta onlarca `data: {...}` birleştiği için `JSON.parse` patlar (`JSON::ParserError`) ve sessizce `nil` döner. Model ne kadar uzun veya kaliteli yanıt verirse versin Rubik **0 adet chunk** toplar ve kullanıcıya yanıltıcı biçimde `"Empty response from model"` hatası verir.

### 1.2. Reasoning / Thinking Tokenlarının Yok Sayılması (`formatter.rb:146`)
- **Mevcut Durum:** [`OpenAIFormatter#parse_stream_event`](file:///home/aristo/Projects/rubik/lib/rubik/llm/formatter.rb#L135-L180) yalnızca `delta["content"]` alanını okur.
- **Kritik Zafiyet:** DeepSeek-R1, Qwen-2.5/3.5-Coder (düşünce modunda) ve akıl yürüten frontier modeller, düşüncelerini `delta["reasoning_content"]`, `delta["reasoning"]` veya `delta["thought"]` alanından stream eder.
- **Sonuç:** Model akıl yürütürken Rubik bu tokenları tamamen göz ardı eder (`text_delta: nil`). Model düşünmeyi bitirdiğinde doğrudan araç çağrısı yapmazsa veya token tavanına çarparsa, Rubik'in `content` alanı boş kalır ve modelin cevabı "boş yanıt" olarak işaretlenir.

### 1.3. `finish_reason: "length"` ve Sessiz Kesilme Körlüğü
- **Mevcut Durum:** Model `max_output_tokens` (varsayılan 4096) sınırına çarpıp kesildiğinde sağlayıcı `finish_reason: "length"` döner.
- **Kritik Zafiyet:** Model henüz `content` üretmeye fırsat bulamadan veya tool-call JSON'ı yarım kaldığı için elendiğinde, Rubik bunun bir token bütçesi aşımı olduğunu kullanıcıya bildirmez; arka arkaya 2 kez tekrarlanınca `"Empty response from model"` hatası basarak kullanıcıyı yanıltır.

### 1.4. Yapılandırma Düğmeleri (Config Knobs) ve Özel HTTP Başlıkları (Custom Headers) Eksikliği
- **Mevcut Durum:**
  - Streaming timeout katı bir şekilde 60 saniyedir (`opts[:timeout] || 60`); büyük modellerde Time-To-First-Token (TTFT) gecikmelerinde patlayabilir.
  - Özel HTTP başlıkları (Custom Headers) global olarak config'den ayarlanamaz (`config["llm"]["headers"]` desteği yoktur); Anthropic ve Ollama sağlayıcıları ise instance veya çağrı seviyesinde özel başlıkları kabul etmez.

---

## 🏛️ 2. Mimari Tasarım ve Çözüm Bileşenleri

```
                        ┌─────────────────────────────────────────────────────────┐
                        │        Plan 74: Resilient LLM Communication Bus         │
                        └────────────────────────────┬────────────────────────────┘
                                                     │
         ┌───────────────────────────┬───────────────┴───────────────┬───────────────────────────┐
         ▼                           ▼                               ▼                           ▼
┌──────────────────┐       ┌───────────────────┐           ┌───────────────────┐       ┌───────────────────┐
│ 1. Robust SSE    │       │ 2. Reasoning Flow │           │ 3. Truncation Diag│       │ 4. Config & Head. │
├──────────────────┤       ├───────────────────┤           ├───────────────────┤       ├───────────────────┤
│ • Universal CRLF │       │ • reasoning_delta │           │ • finish_reason   │       │ • stream_timeout  │
│   & LF detection │       │ • thought stream  │           │   "length" alert  │       │ • open_timeout    │
│ • Comment filter │       │ • live REPL pulse │           │ • Elm-style token │       │ • global & per-req│
│ • Multi-line data│       │ • non-empty guard │           │   budget guidance │       │   custom headers  │
└──────────────────┘       └───────────────────┘           └───────────────────┘       └───────────────────┘
```

---

## ⚙️ 3. Planlanan İyileştirmeler ve Kod Değişiklikleri

### 3.1. W3C Standartlarına Uyumlu Evrensel `SSEParser`
[`lib/rubik/llm/client.rb`](file:///home/aristo/Projects/rubik/lib/rubik/llm/client.rb)
- `feed` metodu: `\r\n\r\n`, `\n\n` ve `\r\r` çift satır sonlarını regex veya çift sonlandırıcı taramasıyla atomik olarak yakalar.
- Çok satırlı SSE bloklarında (`data: line1\ndata: line2`), satırlar standart gereği `\n` ile birleştirilir.
- SSE yorum satırları (`: ping`, `: keep-alive`) doğrudan süzülür.
- `flush` metodu: Buffer'da kalan tamamlanmamış/bozuk parçaları güvenle temizler; yapay concatenated JSON blokları üretmez.

### 3.2. Düşünce Akışı (`reasoning_content`) ve Model Düşünce Entegrasyonu
- [`lib/rubik/llm/provider.rb`](file:///home/aristo/Projects/rubik/lib/rubik/llm/provider.rb):
  `Chunk` sınıfına `reasoning_delta` (attr_reader) ve `reasoning_delta?` eklenir.
- [`lib/rubik/llm/formatter.rb`](file:///home/aristo/Projects/rubik/lib/rubik/llm/formatter.rb):
  `OpenAIFormatter#parse_stream_event`:
  ```ruby
  reasoning = delta["reasoning_content"] || delta["reasoning"] || delta["thought"]
  reasoning_text = reasoning && !reasoning.to_s.empty? ? reasoning.to_s : nil
  ```
  `choices: []` olan heartbeat veya usage chunk'ları `nil` dönmek yerine usage verisini korur.
- [`lib/rubik/orchestrator/stream_manager.rb`](file:///home/aristo/Projects/rubik/lib/rubik/orchestrator/stream_manager.rb):
  `reasoning_delta?` tespit edildiğinde `@loop.on_step&.call(type: :llm_thought_delta, delta: chunk.reasoning_delta, ...)` yayınlanır.
- [`lib/rubik/llm/chunk_assembler.rb`](file:///home/aristo/Projects/rubik/lib/rubik/llm/chunk_assembler.rb):
  Tüm akış boyunca biriken `reasoning_delta` metinleri `Response#thought` alanına eklenir.
- [`lib/rubik/orchestrator/loop.rb`](file:///home/aristo/Projects/rubik/lib/rubik/orchestrator/loop.rb):
  Eğer `text_resp.empty?` ve `tool_calls.empty?` ancak model anlamlı bir `thought` üretmişse:
  Kullanıcıya/Modele "Empty response" demek yerine:
  `"Your reasoning was completed, but no action or final response was provided. Please call a tool or provide your final output."` yönlendirmesi yapılır.

### 3.3. `finish_reason: "length"` Kesilme Teşhisi (Elm-Style Diagnostics)
[`lib/rubik/orchestrator/loop.rb`](file:///home/aristo/Projects/rubik/lib/rubik/orchestrator/loop.rb)
- Eğer yanıt boş kalmışsa ve `res.raw` içinde `finish_reason == "length"` veya `"max_tokens"` tespit edilmişse:
  Doğrudan rehberlik içeren empatik bir hata döndürülür:
  ```text
  ⚠️ Model çıktısı maksimum token sınırına (max_output_tokens: 4096) ulaştığı için tamamlanamadan kesildi.
  Çözüm: Çıktı token bütçesini artırmak için şu komutu çalıştırabilirsiniz:
    !config set llm.default_max_output_tokens 8192
  ```

### 3.4. Yapılandırma Düğmeleri (Config Knobs) & Özel HTTP Başlıkları (Custom Headers)
- [`lib/rubik/config/defaults.rb`](file:///home/aristo/Projects/rubik/lib/rubik/config/defaults.rb):
  ```ruby
  "llm" => {
    "stream" => true,
    "stream_timeout" => 120,
    "open_timeout" => 15,
    "default_max_output_tokens" => 4096,
    "capture_reasoning" => true,
    "headers" => {}
  }
  ```
- [`lib/rubik/llm/registry.rb`](file:///home/aristo/Projects/rubik/lib/rubik/llm/registry.rb):
  Global `config["llm"]["headers"]` başlıkları tüm sağlayıcılara aktarılır.
- [`lib/rubik/llm/openai_compatible.rb`](file:///home/aristo/Projects/rubik/lib/rubik/llm/openai_compatible.rb), [`anthropic.rb`](file:///home/aristo/Projects/rubik/lib/rubik/llm/anthropic.rb), [`ollama.rb`](file:///home/aristo/Projects/rubik/lib/rubik/llm/ollama.rb):
  Tüm sağlayıcılar `opts[:headers]` ve instance başlıklarını birleştirir:
  `req_headers.merge!(opts[:headers]) if opts[:headers].is_a?(Hash)`
  Timeout değerleri config knob'larından dinamik okunur (`opts[:timeout] || @stream_timeout || 120`).

---

## 🧪 4. Test ve Kalite Güvencesi

Yeni/Güncellenecek Testler:
1. `test/unit/test_sse_parser_and_stream_resilience.rb`:
   - `\r\n\r\n` (CRLF CRLF) standardında gelen akışın hatasız ayrıştırılması.
   - `\n\n` (LF LF) ve karma satır sonu akışlarının doğrulanması.
   - Çok satırlı `data:` ve SSE yorum satırlarının (`: ping`) testi.
   - Bozuk akış sonlandırma (`flush`) testleri.
2. `test/unit/test_reasoning_stream_and_finish_diagnostics.rb`:
   - `delta["reasoning_content"]` ve `delta["reasoning"]` ayrıştırma ve akış testleri.
   - Model yalnızca akıl yürüttüğünde akıllı nudge yönlendirmesi.
   - `finish_reason: "length"` durumunda Elm-tarzı teşhis mesajı testi.
   - `choices: []` heartbeat/usage chunk'larının hatasız geçişi.
3. `test/unit/test_llm_custom_headers_and_config_knobs.rb`:
   - Global `config["llm"]["headers"]` ve sağlayıcı özel başlıklarının HTTP isteklerine yansıması.
   - Çağrı anında `opts[:headers]` ezme (override) testi.
   - `stream_timeout` ve `open_timeout` yapılandırma testleri.
4. Tam Regresyon Test Süiti (`rake test`):
   - Tüm testlerin (1095+ test) %100 yeşil kalması.

---

## 📋 5. Uygulama Adımları Özeti

1. **Adım 1:** `defaults.rb` içinde yeni LLM yapılandırma düğmelerini (`stream_timeout`, `open_timeout`, `headers`) tanımla.
2. **Adım 2:** `client.rb` içinde `SSEParser`'ı W3C tam uyumlu hale getir (`\r\n\r\n` ve `\n\n` desteği).
3. **Adım 3:** `provider.rb`, `formatter.rb`, `stream_manager.rb` ve `chunk_assembler.rb` içinde `reasoning_content` desteğini ekle.
4. **Adım 4:** `loop.rb` içinde `finish_reason: "length"` teşhisini ve reasoning nudge mantığını devreye al.
5. **Adım 5:** Sağlayıcılara (`OpenAICompatible`, `Anthropic`, `Ollama`) `opts[:headers]` ve config timeout entegrasyonunu bağla.
6. **Adım 6:** Kapsamlı testleri yaz, çalıştır ve doğrula.
