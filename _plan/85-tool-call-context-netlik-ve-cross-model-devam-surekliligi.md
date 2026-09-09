# Plan 85 — Tool Bağlam Netliği ve Devam Sürekliliği

> **Durum:** 🟢 Tamamlandı (D-1..D-7 tamamlandı; `rake test` 0 fail, `rubocop` 0 offense)  
> **Zorluk:** Orta–İleri (D-7, `conversation_history`'ye tam tool bağlamı ekleyerek token bütçesi yönetimini kritikleştirir)  
> **Faz:** 7  
> **Öneri Bölümü:** LLM Bağlam Sürekliliği & Formatter Katmanı  
> **İlgili Planlar:** [42](42-orchestrator-loop-dekompozisyonu-ve-llm-formatlayici.md), [61](61-llm-baglam-surekliligi-hata-turlerinde-kayit-ve-stream-butunlugu.md), [74](74-endustri-standardi-sse-stream-reasoning-ve-iletisim-hatti.md)

---

## 🎯 Motivasyon ve Gözlemlenen Sorun

Kullanıcı `internlm/intern-latest` gibi bir modelle görev yürütürken şunu gözlemledi:

1. Model bir ya da iki `Empty response from model` hatası verdi.
2. Kullanıcı `continue` yazdı.
3. **Model sıfırdan başladı**: `list_files` → `read_file` döngüsü tekrar başladı.

### Sorunun Kökleri

Araştırma sonucunda **iki ayrı ama birbirini besleyen sorun** tespit edildi:

#### Sorun 1 — OllamaFormatter: Tool Role Semantik Kaybı

`OllamaFormatter#format_messages` içindeki kritik satır:

```ruby
if role == "tool"
  {
    "role" => "user",   # ← tool → user dönüşümü! Anlam tamamen kayıyor.
    "content" => content  # raw XML string olarak
  }
```

`internlm` ve benzeri küçük/instruction-tuned modeller bu yapıyı görünce
`<tool_result tool="list_files">` içerikli mesajların kullanıcıdan geldiğini
zannedip tool-calling protokolü yerine sohbet metni olarak yorumluyor.
Yeni turn açıldığında bu gürültü, modelin "ne yapıldığını" anlamasını engeller.

#### Sorun 2 — `conversation_history` → `@history` tek yönlü akış: Kök Neden

`TurnRecorder#record_failed_turn!` → `record_turn_outcome!`:

```ruby
def record_turn_outcome!(user_text, assistant_content, ...)
  @conversation_history << { role: "user",      content: user_text }
  @conversation_history << { role: "assistant", content: "[Turn incomplete: Empty response from model]\nPartial progress..." }
```

Shell'in `@conversation_history` dizisi **sadece başarılı ya da yarım kalan turn'ün son
özetini** tutar. Bir run sırasında gerçekleşen tool call'lar (`list_files`, `read_file` vb.)
bu diziye **hiç girmiyor**.

Kök nedeni kodda izledik: `run(text, conversation_history: @conversation_history)` 
(`shell.rb:402`) → `@history` başına `conversation_history` seriliyor (`loop.rb:93-94`).
Turn **içindeki** `@history` tool mesajlarını **zaten taşıyor** (advance stepping bunları
`@history`'ye ekler). Ancak turn bittiğinde `record_turn_outcome!` sadece son `output`'u
`conversation_history`'ye yazıyor; turn içi `@history`'nin zengin ara adımları — tool
mesajları dahil — **dışarı hiç akmıyor**.

Sonuç: `continue` ile açılan yeni `Orchestrator::Loop#run()` çağrısı şunu alıyor:
- `conversation_history`: `[{ user: "dosyaları listele" }, { assistant: "[Turn incomplete: ...]" }]`
- Turn içi `@history` (tool ara adımlarıyla dolu): **Yok**

Model, önceki çalışmayı göremediği için en başından keşfetmeye başlar.

> 🔑 **Kök neden budur:** Modelin `continue`'da "kaldığı yerden devam" edebilmesi için
> gereken **tam tool ara adım bağlamı zaten `@history`'de üretiliyor, ama `conversation_history`'ye
> asla kopyalanmıyor.** Plan 85'in erken tasarımı bunu yalnızca hata sonrası kısa bir
> chronicle ile telafi etmeye çalışıyordu; kök neden çözümü ise **her turn sonunda turn içi
> `@history`'deki tool mesajlarını `conversation_history`'ye kopyalamaktır** (bkz. Boyut C,
> D-7).

#### Sorun 3 — `ActivityLog` Özetinin Yetersiz Aktarımı

`record_failed_turn!` zaten `orchestrator.activity.summary` çağrısı yapıyor ama bu özet
**çok kısa** — "N files read, M files written" gibi sayısal; hangi dosyaların okunduğu,
hangi komutların çalıştırıldığı bilgisi modele geçmez.

---

## 🔬 GitNexus Etki Analizi Özeti

| Sembol | Risk | Etki |
|:---|:---|:---|
| `OllamaFormatter` | **MEDIUM** | 51 downstream; d=1: llm.rb, ollama.rb, anthropic.rb, openai_compatible.rb |
| `record_failed_turn!` | **HIGH** | 5 downstream; 3 execution process (run, run_interactive, read_and_process_line) |
| `OllamaFormatter#format_messages` | UNKNOWN | Polimorfik çağrı — text search ile konfirme gerekli |
| `conversation_history` | UNKNOWN | Plain property — test dosyaları üzerinden konfirme gerekli |
| `ActivityLog#record` | LOW | D-2, `@entries` ekleyerek `record`'u genişletir; yalnızca `StepExecutor` çağırır. `reset!` de güncellenir |
| `Loop#run` / `turn_result` | LOW | D-7, `turn_result` zaten `loop_instance:` + `attr_accessor :history` döndürdüğü için `loop.rb`'ye **dokunmaz**; yalnızca caller `res[:loop_instance].history` üzerinden okur. Geriye uyumlu |
| `Shell#execute_free_text` / turn sonucu işleme | **MEDIUM** | D-7, turn sonucundan `loop_instance.history` okuyup `merge_turn_tool_history!` çağırır; shell.rb satır sınırı (≤ 620) korunmalı |

> ⚠️ **AGENTS.md Uyarısı:** `record_failed_turn!` **HIGH** risk — `execute_free_text` üzerinden
> birden çok execution flow etkiliyor. **D-7** kendi başına MEDIUM-HIGH risklidir (token
> bütçesi ve `conversation_history` boyut büyümesi): uygulama öncesi test kapsamı doğrulanmalı
> ve `merge_turn_tool_history!` içindeki trim/üst-sınır davranışı test edilmelidir.

---

## 📐 Çözüm Mimarisi

Bu plan, **hata sonrası görünürlük yamasının ötesine geçip kök nedeni çözen** 3 boyutlu
bir çözüm uygular. Asıl kazanç Boyut B'dedir: turn içi `@history`'de zaten üretilen zengin
tool bağlamının kalıcı `conversation_history`'ye akıtılması — böylece `continue` modeli
"sıfırdan keşfe" itmez.

```
┌───────────────────────────────────────────────────────────────────────┐
│ BOYUT A — Formatter Netliği (anlam kaybını giderme)                    │
│ lib/rubik/llm/formatter.rb                                            │
│ A1: OllamaFormatter tool mesajlarına [Tool result: X] prefix           │
│ A2: OpenAI tool_native:false opt-in (aynı prefix)                      │
│ Yalnızca instruction-tuned / tool-native olmayan modellerde aktiftir.  │
└───────────────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌───────────────────────────────────────────────────────────────────────┐
│ BOYUT B — Turn İçi @history → conversation_history Akışı ★KÖK NEDEN    │
│ lib/rubik/repl/turn_recorder.rb (loop.rb'ye dokunmadan,               │
│   res[:loop_instance].history üzerinden)                              │
│ Hedef: Turn sonunda @history'deki tool ara adımlarını (role: tool)     │
│   conversation_history'ye kopyalayarak continue'da birebir bağlam      │
│   sağlamak. Boyut C'deki hata özeti bunun üzerine biner.               │
└───────────────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌───────────────────────────────────────────────────────────────────────┐
│ BOYUT C — Hata Sonrası Bağlamlandırma (önceki plan 85 kapsamı)         │
│ lib/rubik/orchestrator/activity_log.rb + repl/turn_recorder.rb        │
│ C1: ActivityLog kronolojik özet (D-2)                                  │
│ C2: record_failed_turn! zenginleştirme (D-3)                           │
│ C3: config.defaults tool_chronicle_* (D-4)                             │
│ Boyut B turn bağlamını kopyalarken, C hata etiketli tutarlı bir        │
│   konuşma kaydı bırakır — ikisi birlikte çalışır.                      │
└───────────────────────────────────────────────────────────────────────┘
```

**Katman sıralaması:** Boyut B olmadan Boyut C yalnızca "özet" verir; Boyut B, devam
sürekliliğinin gerçek kök nedeni olan tam tool bağlamını sağlar. Bu yüzden Boyut B
(D-7) anahtar adımdır; A ve C onu tamamlar.

---

## 📋 Uygulama Adımları

### D-1: OllamaFormatter — Tool Mesaj Prefix'i

**Dosya:** `lib/rubik/llm/formatter.rb`  
**Satır:** 331-335 (OllamaFormatter#format_messages içinde `role == "tool"` dalı)

**Mevcut:**
```ruby
if role == "tool"
  {
    "role" => "user",
    "content" => content
  }
```

**Önerilen:**
```ruby
if role == "tool"
  tool_name = (m[:tool_name] || m["tool_name"]).to_s
  label = tool_name.empty? ? "Tool" : tool_name
  # Prefix ile modelin tool sonucunu kullanıcı mesajıyla karıştırmaması sağlanır.
  # Ollama native tool calling'i olmayan modeller için açık etiket kritik.
  prefixed_content = "[Tool result: #{label}]\n#{content}"
  {
    "role" => "user",
    "content" => prefixed_content
  }
```

**Gerekçe:**
- `role: "tool"` Ollama API'sinde desteklenmez, `role: "user"` zorunludur.
- Raw `<tool_result>` XML'ini etiketsiz göndermek, modelin bu bloğun ne olduğunu
  anlamamasına yol açar.
- `[Tool result: list_files]` prefix'i, instruction-tuned modellerin tool sonuçlarını
  doğru bağlamda okumasını sağlar.
- **Geriye dönük uyumluluk:** `content` hâlâ `<tool_result>` XML'ini içerir; bu sayede
  truncation, status ve duration bilgileri korunur.

---

### D-2: ActivityLog — Kronolojik Tool Listesi

**Dosya:** `lib/rubik/orchestrator/activity_log.rb`

> ⚠️ **Tasarım düzeltmesi (kimliğin gerçek veri yapısına göre):**
> Mevcut `ActivityLog` yalnızca `@tools` (Hash: `name => count`), `@files` (Array) ve
> `@tool_errors` (counter) tutar — **her çağrıyı sırayla saklayan bir `@entries` dizisi
> yoktur**. `@tools` aynı aracı `read_file(x3)` biçiminde birleştirdiği için gerçek
> "kronolojik" sıralama mevcut veriden **üretilemez**. Sonuç, planın önceki hâlinde
> `@entries`'e erişen kodun `NoMethodError` ile çökeceğidir.
>
> Bu iki şekilde çözülür: (a) `record` arayüzünü yalnızca kronoloji bilgisini **de**
> koruyacak şekilde genişletmek (önerilen), ve (b) dönüş formatını yalnızca korunan
> veriyle çalışacak biçimde yazmak.

Mevcut `record` çağrısı aracı adını, args'ı ve status'u alır; sıralı bir kalıcı liste
tutması için genişletilir ve `summary`'nin yanına sıralı anahtar döndüren yardımcı eklenir:

```ruby
def initialize
  @tools = Hash.new(0)
  @files = []
  @tool_errors = 0
  @entries = []            # YENİ: sıralı per-call kronoloji [{ tool:, status: }, ...]
end

def record(tool_name, tool_args, status)
  @tools[tool_name] += 1
  @entries << { tool: tool_name, status: status }   # YENİ: sıra korunur
  path = tool_args["path"] || tool_args[:path]
  @files << path.to_s if path && @files.size < 10 && !@files.include?(path.to_s)
  @tool_errors += 1 if status == :error
rescue StandardError
  nil
end

def reset!
  @tools.clear
  @files.clear
  @tool_errors = 0
  @entries.clear          # YENİ
end

# YENİ: Tüm tool çağrılarını gerçek kronolojik sırada döndürür.
# Model context'ine enjekte için tasarlandı. @entries boşsa "" döner.
def chronological_summary(max_entries: 20)
  return "" if @entries.empty?

  lines = @entries.first(max_entries).map.with_index(1) do |entry, i|
    status_tag = entry[:status] == :error ? " [FAILED]" : ""
    "  #{i}. #{entry[:tool]}#{status_tag}"
  end
  lines << "  ... (#{@entries.size - max_entries} more)" if @entries.size > max_entries
  lines.join("\n")
end
```

**`@entries` yapısı:** `record(tool_name, args, status)` çağrısından üretilen
`{ tool:, status: }` hash'leriyle **eklenme sırasında** doldurulur; `reset!` ile temizlenir.

---

### D-3: TurnRecorder — Zenginleştirilmiş Kesintili Turn Kaydı

**Dosya:** `lib/rubik/repl/turn_recorder.rb`  
**Risk:** HIGH — `execute_free_text` → `run` → `run_interactive` zinciri etkileniyor.
Testler geçmelidir.

`record_failed_turn!` metodu genişletilerek **tool aktivite kronolojisi**
`conversation_history`'ye aktarılır:

> ⚠️ **İki düzeltme (mevcut davranış korunur):**
> 1. Mevcut kod `"Partial progress before this outcome:\n#{summary}"` metnini kullanır.
>    Planın önceki hâli bu metni sessizce `"Partial progress:"`'e çeviriyordu — bu, yeni
>    özellikle ilgisiz ve **her başarısız turn kaydını** değiştirirdi. Aşağıda mevcut metin
>    aynen korunmuştur.
> 2. `summary` zaten `Tools used: ...` satırını içerir; yeni `Tool calls made:` bloğu bunu
>    **tekrarlar**. Amaçlıdır: chronicle, D-2'deki sıralı per-call kaydı sunar (hangi sıra,
>    hangi çağrı `[FAILED]`) — `summary` ise toplam sayılar (`read_file(x3)`) ve dosya
>    dokunuşları için kalır. İkisi farklı bilgi katmanıdır ve bilinçli olarak bir aradadır.

```ruby
def record_failed_turn!(user_text, kind, reason, orchestrator)
  return if @config.fetch("context.log_failed_turns", true) == false

  label = case kind
          when "cancelled" then "[Turn cancelled by user (^C)]"
          when "incomplete" then "[Turn incomplete: #{reason}]"
          else "[Turn failed: #{reason}]"
          end

  # Basit sayısal özet (mevcut — metin aynen korunur)
  summary = if orchestrator.respond_to?(:activity)
              orchestrator.activity.summary(orchestrator.buffer_manager).to_s.strip
            else
              ""
            end

  # YENİ: Kronolojik tool listesi
  chronicle_enabled = @config.fetch("context.tool_chronicle_in_history", true)
  max_entries = @config.fetch("context.tool_chronicle_max_entries", 15).to_i
  tool_chronicle = if chronicle_enabled &&
                      orchestrator.respond_to?(:activity) &&
                      orchestrator.activity.respond_to?(:chronological_summary)
                    chron = orchestrator.activity.chronological_summary(
                      max_entries: max_entries
                    ).strip
                    chron.empty? ? "" : "\nTool calls made:\n#{chron}"
                  else
                    ""
                  end

  parts = []
  parts << label
  parts << "Partial progress before this outcome:\n#{summary}" unless summary.empty?
  parts << tool_chronicle unless tool_chronicle.empty?
  body = "#{parts.first}#{parts[1..].map { |p| "\n#{p}" }.join}"

  record_turn_outcome!(user_text, body)
rescue StandardError
  nil
end
```

**Sonuç olarak `conversation_history`'de şu mesaj belirir:**

```
[Turn incomplete: Empty response from model]
Partial progress before this outcome:
Tools used: list_files, read_file
Tool calls made:
  1. list_files
  2. read_file
  3. read_file
```

---

### D-4: Konfigürasyon — `context.tool_chronicle_*` + `context.merge_turn_*`

**Dosya:** `lib/rubik/config/defaults.rb`  
**Satır sınırı:** < 150 satır (mevcut: 146 satır). D-7'nin iki anahtarıyla mevcut `"context"`
bloğu ~150 satıra dayanır; sınır aşılırsa mevcut blokların inline sıkıştırması yapılır
(ör. çok satırlı değerleri tek satıra alma, gereksiz yorumları kaldırma).

```ruby
"context" => {
  "auto_recover_on_overflow"     => true,
  "log_failed_turns"             => true,
  "tool_chronicle_in_history"    => true,   # D-2/D-3 (hata kronolojisi)
  "tool_chronicle_max_entries"   => 15,     # D-2/D-3
  "merge_turn_tool_history"      => true,   # D-7 (köşe neden: turn içi @history akışı) YENİ
  "merge_turn_tool_max_entries"  => 20      # D-7: turn başına kopyalanacak üst sınır YENİ
}
```

Eğer mevcut `"context"` bloğu yoksa yeni oluşturulur; satır sınırı aşılmaması için
mevcut blokların inline sıkıştırması yapılır.

---

### D-5: OpenAI-Compatible Formatter — `tool_native` Flag (Opsiyonel)

**Dosya:** `lib/rubik/llm/formatter.rb`

Tool-calling desteği olmayan ama OpenAI-compatible endpoint üzerinden çalışan modeller için
`tool_native: false` config flag'ı ile aynı prefix formatı etkinleştirilebilir:

```ruby
class OpenAIFormatter < BaseFormatter
  attr_accessor :tool_native

  def initialize(tool_native: true)
    @tool_native = tool_native
  end

  def format_messages(messages)
    ...
    elsif role == "tool"
      if @tool_native
        # Standart OpenAI tool result formatı (mevcut davranış)
        call_id = extract_call_id(m, "call_default")
        formatted << { "role" => "tool", "tool_call_id" => call_id, "content" => content }
      else
        # Tool-native olmayan modeller için prefix'li user mesajı
        tool_name = (m[:tool_name] || m["tool_name"]).to_s
        label = tool_name.empty? ? "Tool" : tool_name
        formatted << { "role" => "user", "content" => "[Tool result: #{label}]\n#{content}" }
      end
```

**Config:** `providers.<name>.tool_native: false` olarak ayarlanabilir.  
**Varsayılan:** `true` — mevcut davranış korunur. Yalnızca kullanıcı açıkça ayarladığında devreye girer.

> ⚠️ **Eksik tesisat düzeltmesi:** Formatter, provider oluşturma noktasında
> (`lib/rubik/llm/registry.rb` içinde `OpenAICompatibleProvider.new(...)` çağrısı ve
> `lib/rubik/llm/openai_compatible.rb` içindeki varsayılan `OpenAIFormatter.new`) hiçbir
> config okumadan kurulur. Yalnızca formatter sınıfına `tool_native` eklemek, config
> bayrağını **ölü anahtar** hâline getirir. Flag'in gerçekten etkin olması için şu
> tesisat da gerekir:
>
> 1. `openai_compatible.rb` — `initialize`'a `formatter: OpenAIFormatter.new(tool_native: tool_native)`
>    akacak şekilde `tool_native:` anahtar argümanı ekleyin (varsayılan `true`).
> 2. `registry.rb` — `providers.<name>.tool_native` config değerini okuyup
>    `OpenAICompatibleProvider.new(..., formatter: OpenAIFormatter.new(tool_native: tool_native))`
>    olarak geçirin. `tool_native` boşsa/okunamazsa varsayılan `true` kalmalı; hiçbir
>    davranış değişmemeli.
>
> **Not:** Bu adım opsiyoneldir (D-1, D-2, D-3 ana süreklilik akışını zaten çözer).
> Uygulama sırasında önceliklendirilmemiştir; yalnızca kullanıcı ilgili config ile
> açıkça talep ederse yapılmalıdır.

---

### D-6: Test Kapsamı

**Yeni test dosyası:** `test/unit/test_tool_context_continuity.rb`

1. **OllamaFormatter prefix testi:**  
   `role: "tool"`, `tool_name: "list_files"` mesajı → `"[Tool result: list_files]\n<tool_result..."` prefix'i ekleniyor mu?

2. **ActivityLog kronoloji testi:**  
   3 tool kaydedildikten sonra (`record("list_files", {}, :ok)`, `record("read_file", {}, :ok)`,
   `record("read_file", {}, :ok)`) `chronological_summary(max_entries: 2)` doğru kısaltıyor mu?
   (`read_file`'ın iki kez **ayrı satırda** görünmesi — yani `@entries`'in per-call sırayı
   koruduğu — ve `"... (1 more)"` satırı var mı?)

3. **record_failed_turn! zenginlik testi:**  
   Mock orchestrator ile `orchestrator.respond_to?(:activity)` ve
   `activity.respond_to?(:chronological_summary)` doğru olduğunda, dolu chronicle
   `conversation_history`'deki `assistant` mesajına `"Tool calls made:"` satırı ekliyor mu?
   Ayrıca negative senaryo: `chronological_summary` boş/`""` döndürdüğünde
   `"Tool calls made:"` satırı **eklenmemeli**.

4. **config devre dışı testi:**  
   `context.tool_chronicle_in_history: false` ile tool listesi eklenmemeli.

5. **D-5 tool_native: false testi:**  
   `OpenAIFormatter.new(tool_native: false)` ile `role: "tool"` mesajı
   `role: "user"` + prefix olarak çıkmalı.

6. **Davranış koruma (regresyon) testi:**  
   D-3 sonrası, dolu `summary` içeren basit bir başarısız turn kaydında
   `"Partial progress before this outcome:"` metni aynen korunmalı — yani D-3,
   tool chronicle kapalıyken (`tool_chronicle_in_history: false`) mevcut çıktıyı
   birebir üretmeli.

---

### D-7: Turn İçi `@history` → `conversation_history` Akışı — ★ KÖK NEDEN

**Dosyalar:** `lib/rubik/repl/turn_recorder.rb` (ana), `lib/rubik/repl/shell.rb` (tek çağrı noktası)  
**Risk:** MEDIUM-HIGH — `loop.rb`'ye **dokunmaz** (turn içi `@history`'ye `turn_result`'un
zaten döndürdüğü `loop_instance.history` üzerinden erişilir). Asıl risk: her turn sonunda
`conversation_history`'ye yazı eklenir; artık sadece "özgeçmiş özeti" değil, tam ara adım
bağlamı taşır → token bütçesi yönetimi (mevcut Plan 61 D-12 trim `trim_conversation_window!`)
kritik hale gelir.

> 🎯 **Amaç:** Boyut B. `continue`'da modelin "sıfırdan keşfe" başlamasının kök nedeni,
> turn içi `@history`'deki tool ara adımlarının `conversation_history`'ye hiç akmamasıdır.
> Bu adım, turn bittiğinde o zengin bağlamı kalıcı context'e kopyalar.

**Mantık:**
- `Orchestrator::Loop#run` parametre olarak `conversation_history` alır ve bunu `@history`
  başına serer (`loop.rb:93-94`).
- Turn sırasında `advance_step`, her tool çağrısından sonra `@history`'ye `{ role: "tool", ... }`
  (veya formata göre uygun karşılığı) ekler.
- Turn bittiğinde shell `record_turn_outcome!` / `record_failed_turn!` ile **yalnızca son
  output'u** `conversation_history`'ye yazar; tool ara adımlarını atar.
- D-7, turn sonucu döndürüldükten sonra `res[:loop_instance].history`'deki `role: "tool"`
  mesajlarını (ve tool çağrısı taşıyan `assistant` mesajlarını — böylece model hangi tool'u
  çağırdığının bağlamını da görür) `user` niyetini ve ara adımları koruyacak şekilde
  `conversation_history`'ye **kopyalar**.

**Önerilen uygulama (turn_recorder.rb):**

```ruby
# YENİ: Turn sonunda çağrılır. Turn içi @history'deki tool ara adımlarını
# conversation_history'ye kopyalar; hata veya başarı fark etmez.
# Böylece continue'da model turn sırasındaki tüm bağlamı görür.
def merge_turn_tool_history!(turn_history, max_entries: 20)
  return false if turn_history.nil? || turn_history.empty?
  return false unless @config.fetch("context.merge_turn_tool_history", true)

  # Yalnızca tool sonucu taşıyan mesajları filtrele; üst sınırı aşmadan al.
  tool_msgs = turn_history.select do |m|
    role = m[:role] || m["role"]
    role == "tool" || m[:tool_calls] || m["tool_calls"]
  end.first(max_entries)
  return false if tool_msgs.empty?

  @conversation_history.concat(tool_msgs)

  # Token bütçesi: conversation_history artık tam tool sonuçları taşıdığından
  # trim zorunludur — mevcut trim_conversation_window! deseniyle aynı ceiling.
  ceiling = begin
    spec = current_model_spec
    @llm_registry.effective_input_limit_for(spec["provider"], spec["name"])
  rescue StandardError
    nil
  end
  @conversation_history = Rubik::Prompt::ContextCompactor.trim_history_to_budget(
    @conversation_history, ceiling: ceiling, max_entries: MAX_CONVERSATION_ENTRIES
  ) if ceiling
  true
end
```

> **Not:** `ceiling` hesabı, mevcut `trim_conversation_window!` (`turn_recorder.rb:76-78`)
> ile birebir aynı desendir; tekrarlamak yerine isterseniz ortak bir yardımcıya
> çıkarılabilir. `ContextCompactor.trim_history_to_budget`'ın boş `ceiling`'i güvenli
> şekilde yok saydığına testlerde emin olun.

**loop.rb'ye dokunmaya gerek yok (doğrulanmış):** `turn_result` (`loop.rb:340`) zaten
`loop_instance: self` döndürür ve `@history`, `attr_accessor :history` (loop.rb:13) ile
erişime açıktır. Yani `tool_history:` anahtarı eklemeye gerek yoktur — caller, elle
`tool_history` taşımak yerine `res[:loop_instance].history` üzerinden turn içi `@history`'ye
doğrudan erişebilir. Bu, D-7'yi `loop.rb`'de **sıfır değişiklik** gerektiren bir adım yapar:

```ruby
# Shell tarafında (turn sonucunu işleyen yer) — loop.rb'ye dokunmadan:
res = ...  # mevcut run() çağrısı
turn_history = res[:loop_instance]&.history          # gerçek turn içi @history
max_entries = @config.fetch("context.merge_turn_tool_max_entries", 20).to_i
merge_turn_tool_history!(turn_history, max_entries: max_entries) if turn_history
```

**Config on/off:** `context.merge_turn_tool_history: true` varsayılan. Kapatılabilir;
kapatıldığında D-7 hiçbir şey kopyalamaz (yalnızca Boyut C'nin özeti kalır).

**Kod ile çakışma / tekrar:** `record_tool_result` (`lib/rubik/session/recorder.rb:73`)
**replay/session kaydı** için ayrı bir `Session::Recorder` kanalıdır ve `conversation_history`
ile karıştırılmamalıdır. D-7, bu replay kanalına dokunmaz; yalnızca LLM'e gidecek kalıcı
`conversation_history`'ye eklem yapar.

> ⚠️ **Token bütçesi uyarısı:** `conversation_history` artık tam tool sonuçları taşıdığından
> boyutu şişebilir. `trim_history_to_budget` zorunludur ve `context.tool_chronicle_max_entries`
> benzeri bir üst sınır uygulanmalıdır (ör. turn başına en fazla N tool mesajı kopyalanır).
> Aksi hâlde uzun bir run, continue context'ini hızla doldurur.

**D-7 testleri** (D-6'daki `test_tool_context_continuity.rb` dosyasının senaryolarına eklenir):

7. **Turn içi tool history merge:** İçinde `role: "tool"` mesajları barındıran bir
   `turn_history` (gerçek `res[:loop_instance].history` gibi) verildiğinde
   `merge_turn_tool_history!` bu mesajları `conversation_history`'ye ekliyor mu,
   `max_entries` üst sınırını aşmıyor mu ve `trim_history_to_budget` sonrası token
   bütçesine saygı gösteriyor mu?

8. **Config kapalı:** `context.merge_turn_tool_history: false` iken `merge_turn_tool_history!`
   hiçbir şey kopyalamıyor mu?

9. **Replay kanalı izolasyonu:** D-7'nin `Session::Recorder#record_tool_result`
   (replay kanalı) mesajlarına dokunmadığını doğrula — yani D-7 yalnızca
   `conversation_history`'ye yazar, `recorder`'a değil.

---

## 🧪 Kırmızı Çizgiler (Bozulmamalı)

| Kural | Kontrol Noktası |
|:---|:---|
| `defaults.rb` < 150 satır | D-4 sonrası `wc -l` |
| `shell.rb` <= 620 satır | D-7, shell.rb'ye tek bir çağrı noktası ekler (`merge_turn_tool_history!`); kod eklemeyi `turn_recorder.rb`'de tut, shell.rb'ye yalnızca küçük çağrı |
| `conversation_history` token bütçesi | D-7 sonrası `conversation_history` tam tool sonuçları taşıyabilir; `merge_turn_tool_history!` içinde `trim_history_to_budget` + `merge_turn_tool_max_entries` üst sınırı **zorunludur** (model context taşması regresyonu) |
| RuboCop 0 offense | `rubocop lib/rubik/llm/formatter.rb lib/rubik/orchestrator/activity_log.rb lib/rubik/repl/turn_recorder.rb lib/rubik/config/defaults.rb` |
| Tüm testler geçmeli | `rake test` |
| OpenAI/Anthropic formatter davranışı değişmemeli | D-1 yalnızca OllamaFormatter; D-5 opt-in |
| Replay/session izolasyonu | D-7 yalnızca `conversation_history`'ye yazar; `Session::Recorder#record_tool_result` (replay kanalı) değişmez |

---

## 🔄 Uygulama Sırası

> **Not:** Kök neden **d1-7 (Boyut B)**'dir — turn içi `@history`'nin `conversation_history`'ye
> akışı. Erken planın (D-1..D-5) en büyük değeri olan Boyut C hata özeti, D-7'yi **tamamlar**
> ama yerini tutmaz. Güvenli sıra: önce bağımlılıksız D-1/D-2/D-4, sonra kök neden D-7,
> ardından D-3 ve D-5.

```
D-2 (ActivityLog record/reset! + chronological_summary) ← Bağımlılık yok; record/reset! uyumluluğu ilk doğrulanır
  → D-4 (config defaults)             ← D-2 ile eş zamanlı; tüm yeni anahtarlar buraya gelir
    → D-7 (turn içi @history akışı)   ← ★ KÖK NEDEN; D-4 config anahtarına bağımlı
      → D-3 (record_failed_turn! genişletme) ← D-2/D-4'e bağımlı; D-7'nin özet tamamlayıcısı
        → D-1 (OllamaFormatter prefix)    ← Bağımsız; herhangi bir sırada olabilir
          → D-5 (tool_native flag)        ← Opsiyonel, son adım
            → D-6 (testler)              ← Her D sonrası kendi testi; D-7 için 7/8/9. senaryolar
```

**Neden D-7 önce:** Boyut C (D-2/D-3) yalnızca hata sonrası **özet** bırakır; model hâlâ
tool ara adımlarını tam göremez. D-7, turn içi `@history`'yi kopyalayarak `continue`'da
birebir bağlam sağlar — asıl "sıfırdan başlama" sorununu çözen tam budur. D-1/D-2/D-4
bağımsız olduğundan paralel/sıralı teslim edilebilir, D-7 onlara çakışmaz.

---

## 📊 Beklenen Çıktı

`internlm/intern-latest` veya benzeri bir modelle:

**Önce (şimdiki durum):**
```
[user]   "dosyaları incele"
[assistant] (boş yanıt → hata)
[user]   "continue"
→ Model: list_files → read_file → ... (sıfırdan başlar)
```

**Sonra — Sadece Boyut C (hata özeti):**
```
[user]   "dosyaları incele"
[assistant] "[Turn incomplete: Empty response from model]
            Partial progress before this outcome:
            Tools used: list_files, read_file
            Tool calls made:
              1. list_files
              2. read_file
              3. read_file"
[user]   "continue"
→ Model: Zaten dosyalara baktım, kaldığım yerden devam ediyorum...
```

**Sonra — D-7 ile (kök neden: tam tool bağlamı `conversation_history`'de):**
```
[user]   "dosyaları incele"
[assistant] "[Turn incomplete: Empty response from model]
            Partial progress before this outcome: ..."
[tool]   list_files → <dosya listesi...>          ← D-7: turn içi @history kopyalandı
[tool]   read_file("a.rb") → <içerik...>
[tool]   read_file("b.rb") → <içerik...>
[user]   "continue"
→ Model: (list_files/read_file sonuçlarını zaten görüyor)
         "a.rb ve b.rb'yi inceledim; b.rb'de şu sorunu buldum, düzeltmeye geçiyorum."
```

Kritik fark: Boyut C yalnızca **sayısal özet** bırakır; D-7, `continue`'da modelin
**gerçek tool çıktılarını görmesini** sağlar — model artık dosyaları yeniden okumak
zorunda kalmaz, gerçek kaldığı yerden devam eder.

---

## 🗂️ Etkilenen Dosyalar

| Dosya | Değişiklik Türü |
|:------|:----------------|
| `lib/rubik/llm/formatter.rb` | D-1: OllamaFormatter tool prefix; D-5: OpenAIFormatter tool_native flag |
| `lib/rubik/orchestrator/activity_log.rb` | D-2: `@entries` kronolojisi + `record`/`reset!` genişletmesi + `chronological_summary` |
| `lib/rubik/repl/turn_recorder.rb` | D-3: `record_failed_turn!` zenginleştirme (mevcut metin korunur); **D-7:** `merge_turn_tool_history!` |
| `lib/rubik/config/defaults.rb` | D-4: `context.tool_chronicle_*` + D-7: `context.merge_turn_tool_history` / `merge_turn_tool_max_entries` |
| `lib/rubik/llm/openai_compatible.rb` | D-5 (opsiyonel): `tool_native:` anahtar argümanı ile formatter teslimatı |
| `lib/rubik/llm/registry.rb` | D-5 (opsiyonel): `providers.<name>.tool_native` config okuyup geçer |
| `lib/rubik/repl/shell.rb` | D-7: turn sonucundan `res[:loop_instance].history` okuyup `merge_turn_tool_history!` çağrısı (satır sayısı kırmızı çizgi ≤ 620) |
| `test/unit/test_tool_context_continuity.rb` | D-6: Yeni test dosyası (9 senaryo: 6 mevcut + D-7 için 7/8/9) |

---

## ✅ Uygulama Sonucu ve Deviation Log

> **Durum:** Uygulandı · **Tarih:** 2026-09-08
> **Doğrulama:** `rake test` 1377 runs / 0 fail · `rubocop` 0 offense

### Uygulanan (plan ile birebir)

| Adım | Kod karşılığı | Sapma |
|:--|:--|:--|
| D-1 OllamaFormatter prefix | `formatter.rb` `role == "tool"` → `[Tool result: <name>]` | Yok |
| D-2 kronolojik aktivite | `activity_log.rb` `@entries` + `chronological_summary(max_entries:)` | Yok |
| D-3 hata kronolojisi | `turn_recorder.rb` `record_failed_turn!` → `Tool calls made:` | `Partial progress before this outcome:` metni korundu (plandaki 1. düzeltme onaylandı) |
| D-4 config | `defaults.rb` `context.tool_chronicle_*` + `merge_turn_tool_*` | `spinner_verbs` varsayılanı kaldırıldı (satır limiti `<150`; davranış nötr — theme nil→DEFAULT_SPINNER_VERBS) ⚠️ |
| D-5 tool_native | `formatter.rb` + `openai_compatible.rb` + `registry.rb` | `p_spec.fetch("tool_native", true)` ile `false` korundu (RuboCop `\|\| true` önerisi reddedildi) |
| D-6 test | `test_tool_context_continuity.rb` | 14 test yazıldı (plan 9 öngörmüştü; edge durumlar eklendi) |
| D-7 @history akışı | `turn_recorder.rb` `merge_turn_tool_history!` + `shell.rb` tek çağrı | `loop.rb`'ye **dokunulmadı** — `res[:loop_instance].history` üzerinden (plan "sıfır değişiklik" iddiası doğrulandı) |

### Kayıtlı Deviation

1. **`spinner_verbs` varsayılanı kaldırıldı** (D-4): `defaults.rb` satır limiti `<150`'yi korumak için `ui.spinner_verbs => []` çıkarıldı. Davranış değişmez (`theme.rb:66` `config&.fetch("ui.spinner_verbs", nil)` → `DEFAULT_SPINNER_VERBS`'e düşer). Kullanıcı bunu manuel bilerek set ediyorsa hâlâ okunur.
2. **D-6 test kapsamı genişledi** (9→14): `merge_turn_tool_history!`'in `max_entries` + trim birlikte davranışı, boş chronicle negative senaryosu ve provider-level `tool_native:false` eklendi.
3. **Plan metni ↔ kod uyumu:** `merge_turn_tool_history!` filtresi `role == "tool"` **ve** `tool_calls'lu assistant` mesajlarını da kopyalar (modelin hangi tool'u çağırdığını görmesi için); plan metni buna göre netleştirildi.
