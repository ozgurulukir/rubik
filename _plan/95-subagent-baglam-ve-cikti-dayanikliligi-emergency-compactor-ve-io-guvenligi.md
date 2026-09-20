# Plan 95 — Alt-Ajan Bağlam ve Çıktı Dayanıklılığı, Emergency Compactor Entegrasyonu ve Savunmacı I/O Mimarisi

> **Durum:** ✅ **Tamamlandı**  
> **Zorluk:** İleri Düzey (Zor)  
> **Faz:** 9 (Ajan Zekası & Çoklu Ajan Mimarisi)  
> **Öneri Bölümü:** Çoklu Ajan Orkestrasyonu, Bağlam Sıkıştırma, Tool I/O Güvenliği, Reaktif Bekleme  
> **İlgili Planlar:** [10](10-tool-calling-orkestrasyon.md), [32](32-agentic-tool-cagrilari-yapilandirilmis-io-ve-akilli-baglam-kirpma.md), [35](35-baglam-sikistirma-token-tahmini-ve-otomatik-truncation-politikasi.md), [42](42-orchestrator-loop-dekompozisyonu-ve-llm-formatlayici.md), [52](52-yerlesik-arac-hizlandirma-native-offload-ve-lazy-hash.md), [63](63-dis-degerlendirme-tavsiye-triyaji-ve-davranis-koruyucu-iyilestirmeler.md), [94](94-alt-ajan-hiyerarsisi-ve-izole-baglam-orkestrasyonu-invoke-subagent.md), [AGENTS.md](../AGENTS.md)

---

## 🎯 1. Motivasyon ve Gerçek Dünya Olayı (Opencode-Personal Vakası)

Rubik'in Plan 94 ile inşa edilen alt-ajan (`invoke_subagent` / `Subagent::Supervisor` / `Subagent::Instance`) mimarisinin gerçek bir monorepo ortamında (`opencode-personal`) çalıştırılması sırasında kritik sistemik zayıflıklar ve asimetriler tespit edilmiştir:

### 🔍 Tespit Edilen Vakalar ve Aksaklıklar:
1. **7.4 MB Tek Satır JSON ile Bağlamın Zehirlenmesi (Context Poisoning):**
   - Alt ajanlar (`subagent-1` ve `subagent-3`), kod tabanında `grep_search` aracıyla arama yaparken `.ua/.trash-1786753720/assembled-graph.json` dosyasıyla eşleşmiştir.
   - Bu dosya, tek bir satırında **7.467.429 karakter (7.4 MB)** barındıran devasa bir graph dump'ıdır.
   - `GrepSearchTool` ve `NativeSearch` (ripgrep) eşleşen satırı herhangi bir karakter sınırı olmadan ham haliyle dönmüş; `subagent-1`'e 7.4 MB, `subagent-3`'e iki eşleşmeyle **14.9 MB** metin aktarılmıştır.
2. **EmergencyCompactor'ın Subagent'ta Devre Dışı Kalması:**
   - Ana ajan döngüsü (`Loop`), olası bir `context_length_exceeded` hatasında `EmergencyCompactor.compact!` ve `auto_recover_on_overflow` ile kendini kurtarabilirken; `Subagent::Instance` izole bir iş parçacığı olarak yazılırken bu mekanizmaya bağlanmamıştır (`unwired`).
   - `Subagent::Instance` ne `context_limit` değerini bilmekte, ne adım öncesi `ContextCompactor` çalıştırmakta, ne de hata anında `EmergencyCompactor` ile hafızayı boşaltabilmektedir. 15 MB'lık geçmiş LLM API'sine gönderildiğinde süreç kilitlenmiş veya düşmüştür.
3. **Subagent Tool Çıktı Güvenlik Duvarı Eksikliği:**
   - Ana döngüdeki `StepExecutor`, bir tool ne kadar büyük çıktı üretirse üretsin bunu `Rubik::Tools::Truncator.truncate` ile 12.000 karaktere budamaktadır. Ancak `Subagent::Instance#dispatch_subagent_tool` metodu doğrudan `raw.to_s` dönerek devasa çıktıları filtresizce alt ajanın `@history` dizisine eklemiştir.
4. **Ripgrep `--hidden` Bayrağının Çöp Dizinleri Taraması:**
   - `NativeSearch`, gizli dotfile konfigürasyonlarını yakalamak için `--hidden` bayrağı ile çalışmaktadır. Ancak `Scanner::DEFAULT_IGNORES` içinde `.ua`, `.trash*`, `.turbo`, `.sst` gibi çöp ve geçici dizinler bulunmadığı için ripgrep bu devasa veri yığınlarını taramıştır.
5. **Supervisor Erken Vazgeçişi (Premature Abandonment) & `status` vs `wait`:**
   - Ana ajan (init-0), alt ajanları izlemek için `manage_subagents(action: "status", timeout: 40)` çağırmıştır.
   - Ancak `action: "status"` metodu `timeout` parametresini yutmuş ve 0.1 milisaniyede bloke olmadan dönmüştür. Ana ajan 40 saniye beklediğini sanırken 30 saniyede 8 kez anlık sorgu atmış ve 76. saniyede "alt ajanlar takıldı / bitmedi" diyerek vazgeçmiştir.
   - Oysa `subagent-2` o sırada çalışmaya devam etmiş, 25 adımın tamamını bitirmiş ve OpenTUI spinner mimarisinin kök neden analizini kusursuz bir rapor olarak transkriptine yazmıştır; ancak ana ajan bunu fark edememiştir.

---

## 🏛️ 2. Mimari Tasarım ve Değişmezler (Invariants)

Bu plan, alt-ajanların ve araç katmanının **veri patlamalarına karşı bağışık (immune to data explosions)**, **bağlam farkında** ve **orkestrasyonda deterministik** olmasını sağlar.

```
                  ┌─────────────────────────────────────────────────────────┐
                  │                 [init-0] ROOT SUPERVISOR                │
                  │   Passes: context_limit, config, event_bus to Subagents │
                  └────────────────────────────┬────────────────────────────┘
                                               │
                                               ▼ spawn(context_limit, config)
                  ┌─────────────────────────────────────────────────────────┐
                  │               [subagent-N] SUBAGENT INSTANCE            │
                  ├─────────────────────────────────────────────────────────┤
                  │ 1. Proactive: ContextCompactor.needs_compaction?        │
                  │ 2. Tool Firewall: Truncator.truncate(max: 12.000 chars) │
                  │ 3. Reactive Recovery: rescue context_overflow =>        │
                  │       EmergencyCompactor.compact!(@history) -> RETRY    │
                  │ 4. HTTP Safety: read_timeout: 90s (No Zombie Hang)      │
                  └────────────────────────────┬────────────────────────────┘
                                               │ executes tool
                                               ▼
                  ┌─────────────────────────────────────────────────────────┐
                  │                   DEFENSIVE TOOL LAYER                  │
                  ├─────────────────────────────────────────────────────────┤
                  │ • NativeSearch: Line-level hard cap (max 500 chars/line)│
                  │ • GrepSearchTool: Output budget cap (max 30.000 chars)  │
                  │ • Scanner: Prunes .ua/**, .trash*/**, .turbo/**, .sst/**│
                  └─────────────────────────────────────────────────────────┘
```

---

## 🛠️ 3. Uygulama Fazları ve Adım Adım Yol Haritası

### Faz A: Subagent Seviyesinde Bağlam Farkındalığı & Emergency Compactor Entegrasyonu
**Hedef:** Alt ajanların ana ajanla aynı bağlam dayanıklılığına ve acil durum sıkıştırma reflekslerine sahip olması.

1. **`Subagent::Instance#initialize` Genişletmesi (`lib/rubik/orchestrator/subagent/instance.rb`):**
   - `context_limit:` ve `config:` parametrelerini kabul et.
   - `@context_limit = (context_limit || 32_768).to_i`
   - `@config = config`
   - `Supervisor#spawn` içinden bu parametreleri ebeveyn bağlamından/yapılandırmasından devral (`inherit`).
2. **Adım Öncesi Proaktif Sıkıştırma (`Proactive Compaction`):**
   - `Subagent::Instance#execute_steps_with_provider` döngüsünde, her adım başında `inject_step_warning_if_needed` sonrasında:
   ```ruby
   evaluate_subagent_context_compaction!
   ```
   - Eğer token tahmini bütçeyi aşıyorsa `Rubik::Prompt::ContextCompactor.compact_history` çalıştırılarak `@history` in-place güncellensin.
3. **Sağlayıcı Çağrısında Reaktif Kurtarma (`EmergencyCompactor`):**
   - `Subagent::Instance#invoke_provider_with_recovery`:
   ```ruby
   retry_attempted = false
   begin
     invoke_provider(opts)
   rescue StandardError => e
     auto_recover = @config ? @config.fetch("context.auto_recover_on_overflow", true) : true
     if !retry_attempted && auto_recover && e.message =~ /context|context_length|maximum context|prompt is too long|token limit|too many tokens/i
       retry_attempted = true
       compact_cfg = @config ? @config.fetch("context", {}) : {}
       Rubik::Prompt::EmergencyCompactor.compact!(@history, context_limit: @context_limit, config: compact_cfg)
       retry
     end
     raise e
   end
   ```
4. **HTTP Okuma Zaman Aşımı Koruması:**
   - Subagent LLM çağrılarına `timeout: 90` ve `open_timeout: 15` verilsin; sağlayıcı yanıt vermediğinde thread sonsuza dek asılı kalmasın.

---

### Faz B: Subagent Tool Çıktı Güvenlik Duvarı (`Truncator`)
**Hedef:** Hiçbir araç çıktısının subagent'ın prompt hafızasını şişirememesi.

1. **`Subagent::Instance#dispatch_subagent_tool` Güncellemesi:**
   - Ham çıktıyı `Rubik::Tools::Truncator.truncate` ile sınırla:
   ```ruby
   def dispatch_subagent_tool(tool, name, args)
     return "Tool '#{name}' is not available in subagent toolset." unless tool

     raw = tool.execute(args)
     out_str = raw.respond_to?(:output) ? raw.output.to_s : raw.to_s
     max_chars = (@config&.fetch("tools.max_output_chars", 12_000) || 12_000).to_i
     max_lines = (@config&.fetch("tools.max_output_lines", 300) || 300).to_i
     trunc = Rubik::Tools::Truncator.truncate(out_str, max_chars: max_chars, max_lines: max_lines)
     trunc[:text]
   rescue StandardError => e
     "Tool execution error: #{e.class}: #{e.message}"
   end
   ```
2. Bu güvenlik duvarı sayesinde `GrepSearchTool` 7.4 MB dönse dahi subagent hafızasına en fazla 12.000 karakter girebilir.

---

### Faz C: Grep ve Native Search Koruma Katmanı (Pre-Emptive Output Sanitization)
**Hedef:** Tek satırlık dev veri dosyalarının (JSON dump, minified JS, source map, lockfile) araç çıktısını patlatmasını kaynağında engellemek.

1. **Ripgrep Akış Düzeyinde Satır Budama (`lib/rubik/tools/native_search.rb`):**
   - `NativeSearch.parse_line(raw)` içinde `match[3]` (satır içeriği) için:
   ```ruby
   content = scrub_utf8(match[3])
   if content.length > 500
     content = "#{content[0..500]}... [line truncated, #{content.length} chars total]"
   end
   ```
   - Böylece 7.4 MB'lık bir satır daha Ruby nesnelerine ayrışmadan önce 500 karaktere indirgenir.
2. **Toplam Çıktı Bütçesi ve Kotası (`lib/rubik/tools/builtins/grep.rb`):**
   - `MAX_LINE_CHARS = 500`
   - `MAX_OUTPUT_CHARS = 30_000` (Yaklaşık 30 KB)
   - `matches` toplanırken toplam içerik boyutu `MAX_OUTPUT_CHARS` sınırına ulaştığında tarama durdurulur:
   ```ruby
   if total_chars >= MAX_OUTPUT_CHARS
     lines << "... [Grep output capped at #{MAX_OUTPUT_CHARS / 1024}KB to protect context window. Narrow search via 'path' or 'extension']"
     break
   end
   ```
3. **Pure-Ruby Arama Koruması (`collect_disk_matches` / `append_string_lines`):**
   - Diskten veya bellekten satır satır taranırken 50 KB'tan uzun satırlar ya da binary karakterler içeren satırlar hemen budanır.

---

### Faz D: Tarama & Ripgrep Dizin İzolasyonu (Trash/Cache Pruning)
**Hedef:** Gizli veya çöp dizinlerin ripgrep `--hidden` ile taranmasının önlenmesi.

1. **`Rubik::Context::Scanner::DEFAULT_IGNORES` Genişletmesi (`lib/rubik/context/scanner.rb`):**
   - Aşağıdaki desenler varsayılan yok sayma listesine eklenir:
     - `".ua/**"`
     - `".trash*/**"`
     - `"**/.trash*/**"`
     - `".turbo/**"`
     - `".sst/**"`
     - `".next/**"`
     - `".nuxt/**"`
2. **`NativeSearch.prune_globs` Senkronizasyonu:**
   - `prune_globs`, `DEFAULT_IGNORES`'taki desenleri ripgrep `-g !<desen>` argümanlarına çevirir. Böylece ripgrep `--hidden` bayrağı aktif olsa bile bu dizinleri tamamen atlar.

---

### Faz E: `ManageSubagentsTool` Reaktif Senkronizasyon & UX İyileştirmesi
**Hedef:** Ana ajanın alt ajanları kontrol ederken yanlış yönlenmesini ve erken pes etmesini engellemek.

1. **`action: "status"` İçinde `timeout` Desteği (`lib/rubik/tools/builtins/subagent.rb`):**
   - `manage_subagents(action: "status", conversation_id: id, timeout: 40)` çağrıldığında:
   ```ruby
   timeout = (args["timeout"] || args[:timeout]).to_i
   if timeout.positive? && inst.running?
     sup.wait_for([id], timeout: timeout)
     # Durum wait sonrasında güncellenmiş nesneden tekrar okunur
     inst = sup.get(id)
   end
   ```
2. **Eğitici Durum ve Yönlendirme Mesajı (`Guidance`):**
   - Eğer subagent `:running` durumundaysa, dönen JSON yanıtına rehberlik alanı eklenir:
   ```json
   "guidance": "Subagent is actively working (step 3/25). DO NOT poll 'status' in a loop. Call 'wait' with timeout to block until completion, or wait for eventbus notification."
   ```
3. **Transkript Son Satır Güvenliği:**
   - Alt ajan tamamlandığında veya bütçe tükendiğinde transkript dosyasının diske tam yazıldığından (`save_transcript!`) ve `result` özetinin eksiksiz kaydedildiğinden emin olunur.

---

## 🧪 4. Doğrulama ve Test Stratejisi

### Yeni Birim Testleri:
1. `test/unit/test_subagent_context_resilience.rb`:
   - Alt ajana devasa tool çıktısı üretildiğinde `Truncator`'ın bunu 12.000 karaktere budadığını doğrula.
   - Alt ajanın `@history` dizisi bağlam sınırını aştığında `ContextCompactor`'ın proaktif olarak devreye girdiğini test et.
   - Mock sağlayıcı `context_length_exceeded` hatası fırlattığında `EmergencyCompactor`'ın geçmişi küçülterek başarılı bir `retry` gerçekleştirdiğini doğrula.
2. `test/unit/test_grep_output_limits.rb`:
   - Tek satırı 5 MB olan yapay bir test dosyasında `GrepSearchTool` ve `NativeSearch` çalıştır; dönen satırın 500 karakterle sınırlandığını ve uyarının eklendiğini teyit et.
   - 100 eşleşmeli bir aramada toplam çıktının 30 KB tavanını aşmadığını doğrula.
3. `test/unit/test_scanner_trash_ignores.rb`:
   - `.ua/assembled-graph.json` ve `.trash-123/file.txt` içeren geçici bir dizinde `Scanner` ve `NativeSearch` çalıştır; bu dosyaların kesinlikle taranmadığını ve eşleşmediğini doğrula.
4. `test/unit/test_manage_subagents_blocking_status.rb`:
   - Çalışan bir alt ajan için `manage_subagents(action: "status", timeout: 2)` çağrıldığında gerçekten belirtilen süre kadar bloke olup ajanın tamamlanmasını beklediğini doğrula.

### Kabul Kriterleri:
- [x] Devasa tek satırlık veri dosyaları subagent bağlamını şişiremez (Max 500 karakter/satır, Max 12.000 karakter/tool).
- [x] Subagent, context overflow hatalarından `EmergencyCompactor` ile tek hamlede otomatik kurtulur.
- [x] `.ua` ve `.trash*` dizinleri ripgrep ve yerel tarayıcı tarafından tamamen atlanır.
- [x] `manage_subagents` status çağrılarındaki `timeout` parametresi bloke edici bekleme sağlar.
- [x] `bundle exec rubocop` 0 ihlal verir.
- [x] Tüm testler %100 yeşil (0 failure, 0 error) tamamlanır.

---

## 🏁 5. Nihai Uygulama Sonucu ve Doğrulama Raporu

Plan 95 başarıyla tamamlanmış ve 5 sütunun tamamı eksiksiz devreye alınmıştır:

1. **Subagent Bağlam ve Acil Kurtarma:** `Subagent::Instance`, `config` ve `context_limit` değerlerini devralmakta, her adım öncesinde proaktif `evaluate_subagent_context_compaction!` çalıştırmakta ve sağlayıcı overflow hatalarında `invoke_provider_with_recovery` aracılığıyla `EmergencyCompactor.compact!(@history)` ile 1 defalık kurtarma gerçekleştirmektedir.
2. **Subagent Tool Güvenlik Duvarı:** `dispatch_subagent_tool` metodu tüm araç çıktılarını `Rubik::Tools::Truncator.truncate` ile maksimum 12.000 karaktere ve 300 satıra filtrelemektedir.
3. **Savunmacı Arama (Grep & NativeSearch):** `NativeSearch.parse_line` eşleşen satırları maksimum 500 karakter ile sınırlandırmakta, `GrepSearchTool` toplam 30 KB çıktı bütçesi (`MAX_OUTPUT_CHARS = 30_000`) ve 500 karakter satır sınırı (`MAX_LINE_CHARS = 500`) ile tek satırlık dev graph/JSON dump dosyalarının bağlamı zehirlemesini engellemektedir.
4. **Çöp ve Önbellek Dizin İzolasyonu:** `Scanner::DEFAULT_IGNORES` ve `HARD_PRUNE_ROOTS` içine `.ua/**`, `.trash*/**`, `**/.trash*/**`, `.turbo/**`, `.sst/**`, `.next/**`, `.nuxt/**` eklenmiş; ripgrep `-g !...` filtreleriyle senkronize edilmiştir.
5. **Reaktif Bekleme ve UX Rehberliği:** `ManageSubagentsTool`, `action: "status"` için `timeout` parametresini desteklemekte ve çalışan ajanlar için bloke edici bekleme sunmaktadır; çalışan ve bütçe bekleyen ajanlara özel yol gösterici `guidance` mesajları üretmektedir.

### Doğrulama ve Metrikler:
- **Yeni Birim Testleri:** `test/unit/test_plan95_subagent_resilience_and_defensive_io.rb` (8 test, 48 assertions, 0 failures, 0 errors).
- **Subagent Orkestrasyon Testleri:** `test/unit/test_subagent_orchestration.rb` (32 test, 162 assertions, 0 failures, 0 errors).
- **Tüm Kod Tabanı Test Koşumu:** 1804 runs, 10510 assertions, **0 failures, 0 errors, 1 skips** (100% Yeşil).
- **RuboCop Kod Hijyeni:** Değiştirilen ve yeni oluşturulan 11 dosya üzerinde **0 offenses** (Temiz).

