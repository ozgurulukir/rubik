# 50 — Varsayılan LLM Stream İletişimi, Canlı Token Akışı ve Çift Yönlü İptal Mimarisi

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Onaylandı (Review Tamamlandı)** · **Zorluk:** Orta · **Faz:** 5 (LLM Ergonomisi & Canlı Akış)  
> **İlgili Planlar:** [01](01-proje-iskeleti-ve-konfigurasyon.md), [02](02-repl-cekirdegi.md), [03](03-dosya-tamponu-snapshot-undo.md), [07](07-dil-adaptor-cercevesi.md), [12](12-guvenlik-diff-onay.md), [13](13-sandbox-izolasyon.md), [18](18-tree-sitter-ast-ve-lsp-entegrasyonu.md), [29](29-lsp-derin-entegrasyonu-tanilama-ve-reaktif-geri-bildirim.md), [40](40-coklu-calisma-alani-ve-ek-kok-dizin-erisim-yonetimi.md), [45](45-spatiotemporal-oz-evrilen-calisma-zamani-ve-otonom-adaptor-sentezi.md), [49](49-tam-kapsamli-cross-platform-ve-windows-uyumluluk-mimarisi.md)  
> **Kapsam:** `lib/rubik/config.rb`, `lib/rubik/orchestrator/loop.rb`, `lib/rubik/repl/shell.rb`, `lib/rubik/repl/step_formatter.rb`, `lib/rubik/llm/provider.rb`, `lib/rubik/llm/formatter.rb`, `CONFIG.md`, `COMMANDS.md`

---

## 🎯 1. Hedef ve Gerekçe

Rubik mimarisinde [`BaseProvider#stream_chat`](../lib/rubik/llm/provider.rb), [`OpenAICompatible`](../lib/rubik/llm/openai_compatible.rb), [`Anthropic`](../lib/rubik/llm/anthropic.rb), [`Ollama`](../lib/rubik/llm/ollama.rb) ve [`Router#stream_chat`](../lib/rubik/llm/router.rb) ile SSE/NDJSON streaming motoru hazır bulunmaktadır. Ancak REPL serbest metin döngüsü varsayılan olarak bloklayıcı batch (`#complete`) modunda çalışmakta; model cevabının tamamı bitene kadar ekranda `⏳ Thinking...` ifadesi bekletilip cevap topluca basılmaktadır.

Bu plan, **LLM stream modunu varsayılan (default: `stream: true`)** yaparak ve **Stream vs. Batch** ayrımını dokümante ederek şu temel kazanımları hedefler:

1. **Sıfır Algılanan Gecikme (0s Time-To-First-Token - TTFT):** Modelin ürettiği her token delta'sı anında terminale akıtılır; kullanıcı sistemin çalıştığını ve ilk düşüncelerini anında görür.
2. **Anında Ctrl+C İptal Çevikliği & Token Tasarrufu:** İstenmeyen bir kod üretimi veya döngü fark edildiğinde, Ctrl+C akışı milisaniyeler mertebesinde keser; hem zaman kaybı hem de gereksiz token tüketimi önlenir.
3. **Tool Call JSON Delta Koruması:** Model bir tool çağırdığında (`call_tool`), argüman JSON parçacıkları asla terminale ham metin olarak dökülmez; arka planda toplanıp adım bitiminde biçimlendirilmiş tool banner (`▶ [Step 1/40] write_file (...)`) olarak gösterilir.
4. **Çift Çıktı Önleme Kalkanı (Double-Print Guard):** Stream modunda ekrana canlı akıtılan metnin adım sonunda `res[:output]` olarak ikinci kez basılması engellenir; geçmişe (`@conversation_history`) ve oturum kaydediciye (`@recorder`) eksiksiz işlenir.
5. **Stream vs. Batch Ayrımı ve %50 Maliyet Tasarrufu:** İnteraktif REPL kullanımında streaming'in, çevrimdışı ve toplu görevlerde batch modunun ve özel batch endpoint'lerinin (%50 maliyet indirimi) ne zaman tercih edileceği `CONFIG.md` ve `COMMANDS.md` içinde belgelenir.
6. **Geriye Dönük Yapılandırma:** `config.yml` üzerinden `llm.stream: false` veya `!config set llm.stream false -g` ile istendiğinde klasik bloklayıcı batch moduna dönülebilmesi garanti edilir.

---

## 💡 2. Stream vs. Batch Kıyaslaması ve Endpoint Ayrımı

| Kriter | 🌊 Stream Modu (`llm.stream: true` - Varsayılan) | 📦 Batch Modu (`llm.stream: false`) |
| :--- | :--- | :--- |
| **Gecikme (TTFT)** | **Sıfır gecikme (0s)** — İlk token üretildiği an terminale akar. | **Yüksek gecikme** — Yanıtın tamamı üretilene kadar beklenir. |
| **Kullanım Amacı** | Canlı REPL oturumları, anlık kodlama, interaktif eşli programlama. | Arka plan betikleri, CI/CD pipeline'ları, toplu analiz görevleri. |
| **İptal / Kontrol** | Ctrl+C ile milisaniyede durdurulabilir; gereksiz token tüketimi kesilir. | İstek başladıktan sonra yanıt bitene kadar HTTP bağlantısı bloklanır. |
| **Özel Endpoint'ler & Maliyet** | Standart chat completion / messages streaming endpoint'leri kullanılır. | **Özel Batch Endpoint'leri:** OpenAI Batch API, Anthropic Message Batches gibi endpoint'ler **%50'ye varan maliyet indirimi** ve daha yüksek rate limit kotaları sunar. |
| **Hata İzolasyonu** | Token akışı sırasında kopma olursa kısmi yanıt yakalanır. | Yanıt tek seferde atomik JSON olarak alınır veya başarısız olur. |

---

## 🏛️ 3. Mimari Tasarım ve Canlı Akış Köprüsü

```
                                [ Kullanıcı Girdisi ]
                                          │
                                          ▼
                               ┌─────────────────────┐
                               │     REPL::Shell     │
                               └──────────┬──────────┘
                                          │ llm.stream: true (Varsayılan)
                                          ▼
                         ┌─────────────────────────────────┐
                         │       Orchestrator::Loop        │
                         └────────────────┬────────────────┘
                                          │ @provider.stream_chat(history) { |chunk| }
                                          ▼
              ┌─────────────────────────────────────────────────────────┐
              │                   LLM::Router / Provider                │
              └───────────────────────────┬─────────────────────────────┘
                                          │
                     ┌────────────────────┴────────────────────┐
                     ▼                                         ▼
         [ Text / Thought Delta ]                     [ Tool Call Delta ]
         (chunk.text_delta?)                          (chunk.tool_use_delta?)
                     │                                         │
                     ▼                                         ▼
         `on_step(type: :chunk)`                     Deltaları Biriktir
         `@output.print delta`                       (Ham JSON Basılmaz!)
         (Canlı Ekrana Basma & Flush)                          │
                     │                                         ▼
                     │                               Adım Bitince Tool Exec
                     │                               (Banner + Obs Göster)
                     ▼                                         │
         Nihai Metin Bittiğinde                                ▼
         (Double-print guard devrede,                 Buffer / Test / Diag
          res[:output] tekrar basılmaz)               Sonraki Adıma Geç
```

---

## ⚙️ 4. Uygulama Adımları ve Kodlama Spesifikasyonları

### 4.1. `Rubik::Config` Varsayılan Yapılandırma Standartı
[`lib/rubik/config.rb`](file:///C:/Github/rubik/lib/rubik/config.rb) dosyasında `DEFAULT_CONFIG` içine `llm` bloğu eklenir:

```ruby
DEFAULT_CONFIG = {
  "llm" => {
    "stream" => true
  },
  "model" => { ... },
  ...
}.freeze
```

- `Config#load_merged_config` ve şema doğrulayıcı `validate_schema` içinde `llm.stream` alanı `true` veya `false` boolean değeri olarak işlenir.
- `config.fetch("llm.stream", true)` çağrısı varsayılan olarak `true` döner.

---

### 4.2. `Orchestrator::Loop` Canlı Stream ve Tool Call Birleştirme Motoru
[`lib/rubik/orchestrator/loop.rb`](file:///C:/Github/rubik/lib/rubik/orchestrator/loop.rb) dosyası aşağıdaki mimariyle güncellenir:

1. **Streaming Kontrolü ve Akış Başlatma:**
   ```ruby
   def send_llm_request_with_recovery(opts)
     streaming_enabled = if opts.key?(:stream)
                           opts[:stream] == true
                         elsif @config
                           @config.fetch("llm.stream", true) != false
                         else
                           true
                         end

     effective_opts = opts.key?(:on_retry) ? opts : opts.merge(on_retry: llm_retry_notifier)

     if streaming_enabled && @provider.respond_to?(:stream_chat)
       execute_streaming_request(effective_opts)
     else
       execute_batch_request(effective_opts)
     end
   end
   ```

2. **Canlı Akış ve Chunks Biriktirme (`execute_streaming_request`):**
   ```ruby
   def execute_streaming_request(opts)
     accumulated_chunks = []
     streamed_text = false
     retry_attempted = false

     begin
       res = @provider.stream_chat(@history, opts) do |chunk|
         accumulated_chunks << chunk
         if chunk.text_delta? && !chunk.text_delta.to_s.empty?
           streamed_text = true
           @on_step&.call(
             type: :chunk,
             delta: chunk.text_delta,
             step: @step_count,
             max_steps: @max_steps
           )
         end
       end

       if res.is_a?(Enumerator) && accumulated_chunks.empty?
         res.each do |chunk|
           accumulated_chunks << chunk
           if chunk.text_delta? && !chunk.text_delta.to_s.empty?
             streamed_text = true
             @on_step&.call(
               type: :chunk,
               delta: chunk.text_delta,
               step: @step_count,
               max_steps: @max_steps
             )
           end
         end
       end

       @on_step&.call(type: :chunk_end, step: @step_count, max_steps: @max_steps) if streamed_text
       build_response_from_chunks(accumulated_chunks, streamed_text: streamed_text)
     rescue Rubik::LLM::ClientError, StandardError => e
       auto_recover = @config ? @config.fetch("context.auto_recover_on_overflow", true) : true
       if !retry_attempted && auto_recover && e.message =~ /context|context_length|maximum context|prompt is too long|token limit|too many tokens/i
         retry_attempted = true
         Rubik::Prompt::EmergencyCompactor.compact!(@history)
         @on_step&.call(type: :emergency_compact, reason: e.message, step: @step_count, max_steps: @max_steps)
         retry
       else
         raise e
       end
     end
   end
   ```

3. **`Chunk`lardan `Response` İnşası (`build_response_from_chunks`):**
   - Text delta'ları birleştirilir: `text = accumulated_chunks.map(&:text_delta).compact.join`.
   - Tool delta'ları birleştirilir: `tool_use_delta` parçacıkları indekslerine göre JSON argüman dizgisine eklenir.
   - Son `usage` nesnesi ayıklanır.
   - Üretilen `Response` nesnesine `streamed: streamed_text` meta bilgisi atanır.

---

### 4.3. `REPL::Shell` Canlı Ekrana Basma ve Çift Yazdırma Önleme (Double-Print Guard)
[`lib/rubik/repl/shell.rb`](file:///C:/Github/rubik/lib/rubik/repl/shell.rb) dosyası `execute_free_text` metodu:

1. **`on_step` Callback Genişletmesi:**
   ```ruby
   streamed_in_session = false

   on_step_handler = lambda do |step_info|
     case step_info[:type]&.to_sym
     when :chunk
       streamed_in_session = true
       @output.print step_info[:delta]
       @output.flush if @output.respond_to?(:flush)
     when :chunk_end
       @output.puts ""
       @output.flush if @output.respond_to?(:flush)
     else
       formatted = formatter.format(step_info)
       if formatted && !formatted.empty?
         @output.puts formatted
         @output.flush if @output.respond_to?(:flush)
       end
     end
   end
   ```

2. **Çift Yazdırma Önleme (Double-Print Guard):**
   ```ruby
   if res[:ok]
     @recorder&.record_assistant_response(res[:output], tokens: res[:tokens])
     @conversation_history << { role: "user", content: text }
     @conversation_history << { role: "assistant", content: res[:output].to_s }
     @conversation_history = @conversation_history.last(20)

     # Yalnızca stream kapalıysa veya metin canlı akıtılmadıysa toplu basılır:
     if !streamed_in_session && !res[:output].to_s.empty?
       @output.puts res[:output]
     end

     if @buffer_manager.dirty?
       @output.puts "\n[Rubik] In-memory buffer updated. Type `!diff` to view, `!apply` to save."
     end
   else
     @output.puts "Görev tamamlanamadı: #{res[:error]}"
   end
   ```

---

### 4.4. `REPL::StepFormatter` Uyarlaması
[`lib/rubik/repl/step_formatter.rb`](file:///C:/Github/rubik/lib/rubik/repl/step_formatter.rb):
- `:chunk` ve `:chunk_end` tipleri için `nil` döner (Shell tarafından doğrudan ham akışla yönetilir).
- Tool call banner'ları (`:tool_call`) ve tool gözlemleri (`:tool_result`) standart estetik görünümünü korur.

---

### 4.5. Dokümantasyon Güncellemeleri (`CONFIG.md` & `COMMANDS.md`)

1. **[`CONFIG.md`](file:///C:/Github/rubik/CONFIG.md):**
   - Yapılandırma şablonuna `llm.stream: true` eklenir.
   - **Stream vs. Batch Kılavuzu:**
     - **Streaming Modu (`stream: true`):** Canlı REPL oturumları, 0s ilk token süresi, Ctrl+C ile anında kesme.
     - **Batch Modu (`stream: false`):** Çevrimdışı ve toplu işlemler için bloklayıcı mod.
     - **Özel Batch Endpoint'leri:** OpenAI Batch API ve Anthropic Message Batches gibi asenkron toplu işleme sistemlerinde **%50 maliyet indirimi** ve yüksek kota avantajları detaylı anlatılır.

2. **[`COMMANDS.md`](file:///C:/Github/rubik/COMMANDS.md):**
   - `!config set llm.stream false -g` komutu ile klasik batch moduna geçiş örneği.
   - `!config set llm.stream true -g` ile varsayılan canlı akışa dönüş.
   - `!config get llm.stream` ile durum sorgulama.

---

## 🧪 5. Test ve Kalite Güvencesi

1. **`test/unit/test_orchestrator_stream.rb` (Yeni Test):**
   - `Orchestrator::Loop`'un `stream: true` ile chunk delta'larını canlı ilettiğini ve tool_call'ları doğru topladığını doğrulayan mock testler.
   - Tool calling sırasında `type: :chunk` çağrılmadığını, yalnızca adım bitiminde `type: :tool_call` oluşturulduğunu doğrulama.
2. **`test/unit/test_repl_stream.rb` (Yeni Test):**
   - `Shell#execute_free_text` sırasında canlı stream çıktısını, double-print guard'ın çalıştığını ve Ctrl+C kesme durumunu doğrulayan birim testleri.
3. **`test/unit/test_config.rb`:**
   - `DEFAULT_CONFIG["llm"]["stream"]` değerinin `true` olduğunu doğrulama.
4. **Genel Başarı Ölçütü:**
   - Mevcut 513+ testin tamamı kırılmadan %100 yeşil (0 failure, 0 error) olarak çalışmalıdır.

---

## 📊 6. Uygulama Adımları ve Kontrol Listesi

- [x] **Adım 1:** `lib/rubik/config.rb` içinde `DEFAULT_CONFIG["llm"]["stream"] = true` tanımlanması.
- [x] **Adım 2:** `lib/rubik/orchestrator/loop.rb` içinde `execute_streaming_request` ve `build_response_from_chunks` akış motorunun entegre edilmesi.
- [x] **Adım 3:** `lib/rubik/repl/shell.rb` içinde `:chunk` / `:chunk_end` canlı akışı ve double-print guard mekanizmasının uygulanması.
- [x] **Adım 4:** `lib/rubik/repl/step_formatter.rb` içinde stream event uyarlamalarının yapılması.
- [x] **Adım 5:** `CONFIG.md` ve `COMMANDS.md` dokümanlarına Stream vs. Batch, batch endpoint'leri ve %50 maliyet tasarrufu kılavuzunun eklenmesi.
- [x] **Adım 6:** `test/unit/test_orchestrator_stream.rb` ve `test/unit/test_repl_stream.rb` testlerinin yazılması ve tüm testlerin (`bundle exec rake test`) %100 yeşil koşulması.
