# Plan 90 — Token Bütçe Otonomisi: Otomatik Devam (Auto-Continue), Thinking Bütçe İzolasyonu ve Akıllı Tavan

> **Durum:** ✅ **Tamamlandı**  
> **Zorluk:** Orta–İleri  
> **Faz:** 9  
> **Öneri Bölümü:** LLM Orkestrasyonu, Akıl Yürütme (Reasoning) & İletişim Hattı  
> **İlgili Planlar:** [09](09-llm-saglayici-soyutlamasi.md), [10](10-tool-calling-orkestrasyon.md), [42](42-orchestrator-loop-dekompozisyonu-ve-llm-formatlayici.md), [61](61-llm-baglam-surekliligi-hata-turlerinde-kayit-ve-stream-butunlugu.md), [74](74-endustri-standardi-sse-stream-reasoning-ve-iletisim-hatti.md), [85](85-tool-call-context-netlik-ve-cross-model-devam-surekliligi.md)

---

## 🎯 1. Motivasyon ve Sorun Tanımı

Kullanıcılar karmaşık kodlama veya analiz görevlerinde şu kesinti hatasıyla karşılaşmaktadır:
```text
Görev tamamlanamadı: ⚠️ Model çıktısı maksimum token sınırına (max_output_tokens: 16384) ulaştığı için tamamlanamadan kesildi.
Çözüm: Çıktı token bütçesini artırmak için şu komutu çalıştırabilirsiniz:
  !config set llm.default_max_output_tokens 32768
```

### 🔍 Kök Neden Analizi (Root Causes)

1. **LLM API'lerinin "Hard Cutoff" Doğası:**
   - LLM API'lerine (OpenAI, Anthropic, Gemini, DeepSeek vb.) gönderilen `max_tokens` / `max_output_tokens` parametresi model için bir "planlama hedefi" değildir. API tarafındaki bir güvenlik şalteridir.
   - Autoregressive modeller kaçıncı tokende olduklarını bilmezler. Token sayısı sınıra ulaştığı an API üretimi aniden keser ve `finish_reason: "length"` (Anthropic: `"max_tokens"`) bayrağı basar.
2. **Akıl Yürüten (Reasoning / Thinking) Modellerde Bütçe Yutulması (Token Starvation):**
   - Claude 3.7 Thinking, o1, o3-mini, Gemini Flash Thinking, DeepSeek-R1 gibi modellerde düşünce süreci (`thought` / `reasoning_content`) ve asıl çıktı (`content` / `tool_calls`) aynı `max_output_tokens` havuzunu paylaşır.
   - Model 16.384 token boyunca yalnızca düşünürse, asıl cevaba veya tool çağrısına tek bir token kalmadan tavan dolar (`text_resp.empty? && tool_calls.empty? && finish_reason == "length"`).
3. **Erken Pes Etme ve Kullanıcıya Yüklenen Manuel İş:**
   - `Loop#process_step_response` bu kesintiyi görünce görevi hemen başarısız ilan edip kullanıcıdan elle `!config set ...` komutu çalıştırmasını bekler. Otonom bir ajanın bu kesintiyi kendiliğinden yönetmesi gerekir.
4. **Yarım Kalan Metin/Kodun Hatalı Şekilde "Başarılı" Sayılması:**
   - Eğer model uzun bir kod yazarken cümlenin veya dosyanın ortasında kesildiyse (`!text_resp.empty? && finish_reason == "length"`), mevcut kod bunu `turn_result(success: true)` sayarak yarım ve bozuk kodu kullanıcıya tamamlanmış gibi sunar.
5. **Thinking Bütçe Ayrımı ve Prompt Şartlandırmasının Eksikliği:**
   - Anthropic (`thinking: { budget_tokens: ... }`) ve OpenAI (`reasoning_effort`) API'leri düşünme bütçesini sınırlama olanağı sunar ancak Rubik'te bu parametreler dinamik yönetilmemektedir.
   - Sistem isteminde `<output_budget>` bulunmadığı için model ne kadar bütçesi olduğunu bilmez ve uzun girişler yazabilir.

---

## 🏗️ 2. Mimari Çözüm ve Fazlar

```
 ┌────────────────────────────────────────────────────────────────────────┐
 │                      PLAN 90 - TOKEN BÜTÇE OTONOMİSİ                    │
 └───────────────────────────────────┬────────────────────────────────────┘
                                     │
         ┌───────────────────────────┼───────────────────────────┐
         ▼                           ▼                           ▼
 ┌───────────────────┐       ┌───────────────────┐       ┌───────────────────┐
 │      FAZ A        │       │      FAZ B        │       │      FAZ C & D    │
 │ ContinuationMgr   │       │ Provider Guard    │       │ Prompt Şartlama   │
 │ & Auto-Continue   │       │ & Thinking Bütçe  │       │ & Akıllı Tavan    │
 ├───────────────────┤       ├───────────────────┤       ├───────────────────┤
 │ • Length tespiti  │       │ • Anthropic T=1.0 │       │ • <output_budget> │
 │ • Düşünce kurtarma│       │ • Budget >= 1024  │       │ • Operational Rule│
 │ • Metin dikme     │       │ • o1/o3-mini max_c│       │ • 16k-32k default │
 └───────────────────┘       └───────────────────┘       └───────────────────┘
```

---

### 🎯 Faz A: `ContinuationManager` ve Akıllı Otomatik Devam Mekanizması

Modülerlik ve mimari sınırların korunması için (`orchestrator/loop.rb < 450 LOC` değişmezi), devam mantığı yeni bir işbirlikçiye devredilir:
`lib/rubik/orchestrator/continuation_manager.rb` (`Rubik::Orchestrator::ContinuationManager`).

- **Sorumluluklar:**
  - `auto_continue_count`: Mevcut turdaki devam sayacı (art arda `max_auto_continues` tavanı, varsayılan: `3`).
  - `continuation_buffer`: Kesilen metin parçalarını biriktirme tamponu.
  - `truncation?(finish_reason)`: `["length", "max_tokens"].include?(finish_reason.to_s)`.
  - `handle_truncation(res, text_resp, tool_calls)`:
    - **Durum 1 (Düşünce Süreci Bütçeyi Tüketti):** `text_resp.empty? && tool_calls.empty?`
      - `res.thought` asistan düşüncesi olarak geçmişe güvenle işlenir.
      - Modele yönlendirici kullanıcı mesajı üretilir:
        `"Your thinking phase reached the output token limit before generating a final response or tool call. Do not repeat your reasoning; immediately provide your final response or invoke the necessary tool call concisely."`
      - UI'ya `:auto_continue` bildirimi iletilir: `🔄 Düşünce bütçesi doldu, yanıt doğrudan alınıyor (adım 1/3)...`
    - **Durum 2 (Metin/Kod Ortasında Kesildi):** `!text_resp.empty? && tool_calls.empty?`
      - Parça `continuation_buffer`'a eklenir.
      - Modele kesintisiz devam mesajı üretilir:
        `"Your previous response was cut off because it reached the output token limit. Continue directly and seamlessly from the exact word or code line where you stopped. Do not repeat earlier text or restart."`
      - UI'ya bildirim: `🔄 Çıktı token sınırına ulaştı, kaldığı yerden devam ettiriliyor (adım 1/3)...`
    - **Durum 3 (Kesilmiş Tool Call JSON):**
      - Modele: `"Your tool call was cut off due to the token limit. Please re-invoke the tool call with concise arguments."` iletilir.
    - **Durum 4 (Emniyet Sigortası):**
      - Eğer art arda `max_auto_continues` (3) sınırına ulaşılırsa, devam durdurulur ve Plan 74'teki Elm-tarzı bilgilendirici mesaj döndürülür.
  - `stitch_and_reset(final_text)`:
    - Tamamlanan turda birikmiş parçalar ile son parça birleştirilir (`[continuation_buffer, final_text].join("")`), tampon ve sayaç sıfırlanır.
  - `TurnRecorder` entegrasyonu: `record_turn_outcome!` aşamasında aradaki devam mesajları yerine birleştirilmiş (stitched) nihai asistan metni `conversation_history`'ye aktarılır; böylece gelecekteki turlar ara devam mesajlarıyla kirlenmez.

---

### 🧠 Faz B: Sağlayıcı Seviyesinde Thinking Bütçe İzolasyonu ve API Kısıtları

Sağlayıcı API'lerinin katı kuralları bulunmaktadır; bu kurallara uyulmadığında API 400 Bad Request fırlatır:

1. **Anthropic (`lib/rubik/llm/anthropic.rb`):**
   - **Kural 1 (Temperature Zorunluluğu):** Anthropic API'sinde `thinking` etkinleştirildiğinde `temperature` **MUTLAKA 1.0 olmalıdır** (veya istekten silinmelidir). Başka bir değer (örn. `0.0` veya `0.7`) doğrudan `400 invalid_request_error` üretir!
   - **Kural 2 (Minimum Bütçe):** `budget_tokens` en az `1024` olmalı ve `max_tokens` değerinden kesinlikle küçük olmalıdır.
   - **Formül:**
     ```ruby
     if thinking_enabled && max_tokens > 2048
       budget = [[(max_tokens * thinking_ratio).to_i, 1024].max, max_tokens - 1024].min
       payload[:thinking] = { type: "enabled", budget_tokens: budget }
       payload.delete(:temperature) # veya payload[:temperature] = 1.0
     end
     ```
   - Böylece düşünme bütçesi toplam bütçenin en fazla `%50`'sini alabilir; asıl cevaba garanti alan kalır.

2. **OpenAI / OpenRouter (`lib/rubik/llm/openai_compatible.rb`):**
   - **`max_completion_tokens` Kuralı:** `o1`, `o1-mini`, `o1-preview`, `o3`, `o3-mini` gibi akıl yürüten modeller `max_tokens` yerine `max_completion_tokens` parametresini şart koşar. Model adı eşleşiyorsa veya yapılandırmada belirtilmişse `payload[:max_completion_tokens] = max_tokens` olarak gönderilir.
   - **`reasoning_effort`:** `opts[:reasoning_effort] || config.fetch("llm.reasoning_effort", "medium")` parametresi payload'a eklenir.
   - `o1`/`o3` modellerinde `temperature` gönderilmez (desteklenmez).

3. **Yapılandırma Düğmeleri (`lib/rubik/config/defaults.rb`):**
   ```ruby
   "llm" => {
     "auto_continue_on_length" => true,
     "max_auto_continues" => 3,
     "thinking_budget_ratio" => 0.5,
     "reasoning_effort" => "medium"
   }
   ```

---

### 📋 Faz C: Prompt Seviyesinde Çıktı Şartlandırması (Output Budget Conditioning)

`lib/rubik/prompt/context_builder.rb`:
- `<system_context>` içerisine `<output_budget limit="#{max_output_tokens}" unit="tokens" />` etiketi eklenir.
- `build_operational_rules_xml` içine 6. kural eklenir:
  > *"6. Output Budget & Execution Conciseness: You have a generation budget of #{max_output_tokens} tokens per turn. Keep explanations focused and prioritized; emit tool calls early rather than writing extensive preambles. Structure your output so that reasoning and code changes fit comfortably within this budget."*

---

### ⚡ Faz D: Akıllı ve Dinamik Üst Sınırlar (Smart Max Tokens Catalog)

`lib/rubik/llm/registry.rb`:
- `DEFAULT_MAX_OUTPUT_TOKENS` tablosundaki yapay küçük değerler modern frontier modellerin gerçek kapasitelerine göre güncellenir:
  - `anthropic`: 16_384 (Claude 3.7 Sonnet / 3.5 Sonnet)
  - `openai`: 16_384 (GPT-4o, o3-mini)
  - `gemini`: 16_384 (Gemini 2.5 Flash / Pro)
  - `deepseek`: 16_384 (DeepSeek-V3 / R1)
  - `ollama`: 8_192
  - `default`: 8_192
- Kullanıcı dilediğinde `!config set llm.default_max_output_tokens` ile ezmeye devam edebilir.

---

### 🧪 Faz E: Test Paketi ve Doğrulama

1. `test/unit/test_orchestrator_continuation_manager.rb`:
   - `ContinuationManager` birim testleri (durum geçişleri, buffer biriktirme, metin dikme, reset).
2. `test/unit/test_loop_auto_continue_on_length.rb`:
   - Düşünce bütçesi dolduğunda (`text_resp.empty?`, `finish_reason: length`) otomatik devam ve sonraki adımda başarıyla tamamlama.
   - Metin ortada kesildiğinde (`!text_resp.empty?`, `finish_reason: length`) sonraki adımla metin birleştirme.
   - Art arda 3 kez kesilmede güvenlik sigortasının devreye girmesi.
   - `TurnRecorder` geçmişinde birleştirilmiş temiz metnin kalması.
3. `test/unit/test_thinking_budget_isolation.rb`:
   - Anthropic sağlayıcısının `temperature=1.0` ve `budget_tokens` kurallarına tam uyumu.
   - OpenAI uyumlu sağlayıcıda `o1`/`o3` için `max_completion_tokens` ve `reasoning_effort` aktarımı.
4. `test/unit/test_output_budget_prompt.rb`:
   - `<output_budget>` etiketinin sistem bağlamında doğru üretilmesi.
5. `test/unit/test_module_hygiene.rb`:
   - `loop.rb` satır sayısının 450 tavanının altında kalması (`assert lines < 450`).
   - `continuation_manager.rb` satır sayısının 400 tavanının altında kalması (`assert lines < 400`).
6. `bundle exec rubocop` 0 offenses & `bundle exec rake test:fast` %100 yeşil.

---

## 📋 3. Başarı Kriterleri

- [x] Model token sınırına çarptığında kullanıcıya hemen hata basmak yerine otonom olarak kaldığı yerden devam etmeli.
- [x] Düşünce (reasoning) süreci bütçeyi tükettiğinde model otomatik yönlendirilmeli ve görev aksamamalı.
- [x] Yarım kalan metin parçaları uç uca dikilerek kullanıcıya eksiksiz sunulmalı.
- [x] Anthropic ve OpenAI reasoning API kuralları (temperature, budget_tokens, max_completion_tokens) ihlal edilmemeli.
- [x] `loop.rb` < 450 satır sınırı korunmalı.
- [x] Tüm testler 0 failure, 0 error ile geçmeli, RuboCop 0 offense olmalı.

---

## 🏁 4. Uygulama Sonucu ve Doğrulama

- **Faz A:** `lib/rubik/orchestrator/continuation_manager.rb` oluşturuldu ve `lib/rubik/orchestrator/loop.rb` ile entegre edildi. Kesinti türü (`:thinking_exhausted`, `:text_truncated`, `:tool_truncated`) otonom tespit edilip nudge ile devam ettiriliyor; 3 devam sigortası ve metin dikme (`stitch_response`) eksiksiz çalışıyor.
- **Faz B:** `lib/rubik/llm/anthropic.rb` içinde Claude 3.7 Thinking modelleri için %50 bütçe tavanı ve zorunlu `temperature=1.0` kuralı uygulandı. `lib/rubik/llm/openai_compatible.rb` içinde `o1`/`o3` akıl yürütme modelleri için `max_completion_tokens` ve `reasoning_effort` eşlemesi sağlandı; `temperature` çıkarıldı.
- **Faz C:** `lib/rubik/prompt/context_builder.rb` içine `<output_budget limit="...">` etiketi ve Operasyonel Kural 6 eklendi; `loop.rb` üzerinden bağlam inşa hattına bağlandı.
- **Faz D:** `lib/rubik/llm/registry.rb` içinde varsayılan tavanlar Anthropic (16_384), OpenAI (16_384), DeepSeek (16_384), Gemini (16_384) ve Ollama (8_192) olarak güncellendi.
- **Faz E:** Tüm birim testler (`test_orchestrator_continuation_manager.rb`, `test_loop_auto_continue_on_length.rb`, `test_thinking_budget_isolation.rb`) yazıldı; `rake test:fast` (1538 runs, 8799 assertions, 0 failures, 0 errors) ve `rubocop` (14 files, 0 offenses) %100 yeşil tamamlandı. Line count hijyeni (`loop.rb` 425 satır < 450) korundu.
