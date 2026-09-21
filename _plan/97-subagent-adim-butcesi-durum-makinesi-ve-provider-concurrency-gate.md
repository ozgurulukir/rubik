# Plan 97 — Subagent Adım Bütçesi (88 Steps), Durumsal Farkındalık Durum Makinesi (`:budget_exhausted`) ve Sağlayıcı Concurrency Gate Mimarisi

> **Durum:** ✅ **Tamamlandı**  
> **Zorluk:** Orta–Zor  
> **Faz:** 9 (Ajan Zekası & Çoklu Ajan Mimarisi)  
> **Öneri Bölümü:** Çoklu Ajan Orkestrasyonu, Adım Bütçesi Skalası, Yaşam Döngüsü Durum Dürüstlüğü, LLM Sağlayıcı Eşzamanlılık Koruması  
> **İlgili Planlar:** [10](10-tool-calling-orkestrasyon.md), [31](31-agentic-adim-butcesi-ve-dinamik-genisletme.md), [94](94-alt-ajan-hiyerarsisi-ve-izole-baglam-orkestrasyonu-invoke-subagent.md), [95](95-subagent-baglam-ve-cikti-dayanikliligi-emergency-compactor-ve-io-guvenligi.md), [96](96-init-0-subagent-orkestrasyon-baglami-ve-high-snr-toolbelt-mimarisi.md), [AGENTS.md](../AGENTS.md)

---

## 🎯 1. Motivasyon ve Kök Neden Analizi (Root Cause Analysis)

Rubik ana oturumu (`.rubik/sessions/session_20260921_103938_2472_459.jsonl`) ve alt-ajan transkriptleri (`.rubik/subagents/subagent-{17..21}/transcript.jsonl`) incelendiğinde, kök ajan (`init-0`) tarafından başlatılan kodlayıcı alt ajanların görevlerini tamamlayamamasının ve repoda hiçbir kalıcı değişiklik bırakamamasının arkasında şu sistemsel kök nedenler tespit edilmiştir:

### 🔍 Kritik Bulgular:

1. **Adım Bütçesi Tavanı Yetersizliği (15-25 Adım vs. Çok Dosyalı Görevler):**
   - [`Budget::DEFAULT_MAX_STEPS`](file:///C:/Github/rubik/lib/rubik/orchestrator/subagent/budget.rb) değeri 15 adım, `Supervisor` varsayılan tavanı ise 25 adımdır.
   - `init-0` alt ajanlara geniş kapsamlı (6-8 dosya ve 7 karmaşık güvenlik/mimari bulgusu içeren) görevler devretmiştir (`init-0` kısıtlanmamalıdır; model özgürce kapsamlı görevler verebilmelidir).
   - Alt ajanlar 20-25 adımlık bütçelerinin tamamını sadece `read_file`, `list_files` ve `grep_search` ile kod tabanını okuyup anlamak için tüketmiş; dosya düzenleme (`write_file`, `replace_file_content`) ve test (`run_tests`, `apply_buffer`) aşamasına hiç geçemeden bütçeleri tükenmiştir.

2. **Yanıltıcı Durum Makinesi ve Sessiz Sonlanma (`:completed` Halüsinasyonu):**
   - [`Instance#pause_and_await_budget_expansion!`](file:///C:/Github/rubik/lib/rubik/orchestrator/subagent/instance.rb) metodu içinde alt ajan bütçesi dolunca durum `:waiting_budget` olmakta ve 60 saniyelik bir `wait_timeout` işletilmektedir.
   - Eğer `init-0` 60 saniye içinde (örneğin uzun bir LLM stream yanıtı üretirken veya diğer ajanları beklerken) `extend_budget` çağırmazsa, alt ajan **kendini sessizce `@state = :completed` durumuna alarak sonlandırmaktadır**:
     ```ruby
     if @state == :waiting_budget
       @state = :completed
       @result = "Subagent reached step budget (#{@budget.max_steps} steps) and concluded after waiting for init-0."
       false
     ```
   - Bu durum `manage_subagents(action: "wait")` ve `action: "list"` tarafından `COMPLETED` olarak raporlanmakta; üst ajan alt ajanın başarılı olduğunu sanmakta, oysa alt ajan hiçbir kod yazmadan bütçe yetersizliğinden ötürü yarım kalmıştır.

3. **60 Saniyelik Bekleme Süresinin Kısalığı:**
   - Çoklu ajan ortamlarında bir üst ajan veya LLM provider düşünme/üretim turu 60-90 saniye sürebilmektedir. 60 saniye sonra hemen sonlanmak, ajanın kurtarılabilirlik şansını yok etmektedir.

4. **Sağlayıcı Eşzamanlılık Tıkanması (Provider Concurrency & 90s Read Timeout):**
   - 5 alt ajan aynı anda başlatıldığında hepsi eşzamanlı olarak dış LLM sağlayıcısına (`model.inferx.net`) büyük token hacimli istekler göndermiş; bu durum sağlayıcı tarafında kuyruk şişmesine ve `subagent-18`'in `Rubik::LLM::ClientError: read timeout after 90s calling model.inferx.net` hatasıyla çökmesine (`:failed`) yol açmıştır.
   - Alt ajan thread eşzamanlılığı (`max_concurrency: 10`) ile dış ağa yapılan LLM istek eşzamanlılığı ayrıştırılmamıştır.

---

## 🏛️ 2. Mimari Tasarım ve Değişmezler (Invariants)

```
                            ┌──────────────────────────────────────────────┐
                            │          SUBAGENT RUNTIME ORCHESTRATION      │
                            └──────────────────────┬───────────────────────┘
                                                   │
                       ┌───────────────────────────┴───────────────────────────┐
                       ▼                                                       ▼
     ┌───────────────────────────────────┐                   ┌───────────────────────────────────┐
     │   GENİŞLETİLMİŞ ADIM BÜTÇESİ      │                   │     PROVIDER CONCURRENCY GATE     │
     │   (DEFAULT_MAX_STEPS = 88)        │                   │     (provider_concurrency = 2)    │
     ├───────────────────────────────────┤                   ├───────────────────────────────────┤
     │ • 88 adım varsayılan bütçe        │                   │ • Thread::SizedQueue tabanlı gate │
     │ • invoke_subagent(max_steps: N)   │                   │ • LLM isteklerinde semafor        │
     │ • 75% bütçe uyarısı reaktif (66)  │                   │ • 90s Read Timeout bağışıklığı    │
     └───────────────────────────────────┘                   └───────────────────────────────────┘
                                                   │
                                                   ▼
                               ┌───────────────────────────────────────┐
                               │   DURUMSAL DÜRÜSTLÜK DURUM MAKİNESİ   │
                               │   (:waiting_budget -> :budget_exhaust)│
                               ├───────────────────────────────────────┤
                               │ • Bütçe bitti: :waiting_budget (180s) │
                               │ • Timeout oldu: :budget_exhausted 🛑  │
                               │ • Asla sahte :completed OLMAZ         │
                               │ • High-SNR Teşhis & Kurtarma Mesajı   │
                               └───────────────────────────────────────┘
```

### Temel Değişmezler:
1. **Durumsal Dürüstlük İlkesi (State Truthfulness):** Bir alt ajan yalnızca ve yalnızca görevini tamamladığı zaman (araç çağrısız metin sonucu veya tamamlanma onayı) `:completed` durumuna geçebilir. Bütçesi bittiği ve zaman aşımına uğradığı için duran bir ajan ASLA `:completed` olamaz; durumu `:budget_exhausted` olmak zorundadır. Terminal durumda duran ajan için branch buffer birleştirmesi veya buffer disk auto-apply kesinlikle çalıştırılmaz.
2. **Sağlayıcı Koruma Kapısı (Provider Concurrency Gate):** Sistemde aynı anda 10 subagent thread'i aktif olsa dahi, dış LLM sağlayıcısına aynı milisaniyede giden aktif HTTP istek sayısı `subagents.provider_concurrency` (varsayılan: `2`) ile sınırlandırılır. Diğer ajanlar OS thread seviyesinde kuyrukta bekler, böylece rate limit ve timeout önlenir. Token alma/bırakma işlemi `ensure` bloğu ile sızıntısız ve deadlock-free garantilenir.
3. **88 Adım Konfigürasyonu ve Skala Senkronizasyonu:** `DEFAULT_MAX_STEPS` kodu karmaşıklaştırmadan 88'e çıkarılır; `invoke_subagent` üzerinden dinamik geçiş desteklenir. `DEFAULT_GRANT_STEPS` ise 20 olarak ayarlanır.
4. **Modül Hijyeni ve Satır Sınırı (Ceiling Invariant):** `lib/rubik/tools/builtins/subagent.rb` dosyasının satır sayısı tavanı `< 350`dir (şu an 348 satır). Faz B eklemeleri yapılırken dosya içi küçük refactoring ile satır sayısı ~335-340 seviyesine çekilmelidir. Benzer şekilde `supervisor.rb` (< 350) ve `notices.rb` (< 150) sınırları korunmalıdır.

---

## 🛠️ 3. Uygulama Fazları ve Yol Haritası

### Faz A: Bütçe Skalasının Genişletilmesi (Default 88 Steps) & Dinamik Bütçe Parametresi
**Hedef:** Alt ajanlara keşif + düzenleme + test döngüsünü rahatça tamamlayabilecekleri 88 adımlık geniş bir alan tanımak.

1. **`Rubik::Orchestrator::Subagent::Budget` (`lib/rubik/orchestrator/subagent/budget.rb`):**
   - `DEFAULT_MAX_STEPS = 88` olarak güncellenir.
   - `DEFAULT_GRANT_STEPS = 20` olarak ayarlanır.
2. **`lib/rubik/config/defaults.rb`:**
   - `"subagents" => { "default_max_steps" => 88, "provider_concurrency" => 2, "budget_wait_timeout" => 180, ... }` olarak ayarlanır.
3. **`Supervisor#initialize` & `Supervisor#spawn` (`lib/rubik/orchestrator/subagent/supervisor.rb`):**
   - `@default_max_steps = (config&.fetch("subagents.default_max_steps", 88) || 88).to_i`.
   - `spawn` çağrısında `max_steps` parametresi öncelikli alınır, yoksa `@default_max_steps` (88) kullanılır.
   - `Supervisor#extend_budget(id, steps = Budget::DEFAULT_GRANT_STEPS)` ile senkronize edilir.
4. **`Notices.extend_budget_hint` (`lib/rubik/orchestrator/subagent/notices.rb`):**
   - `def extend_budget_hint(id, steps: 20)` olarak güncellenir.
5. **`SubagentTools` (`invoke_subagent` şeması - `lib/rubik/tools/builtins/subagent.rb`):**
   - `invoke_subagent` araç şemasında hem array elemanları içindeki `max_steps` hem de root `max_steps` parametrelerinde `(default: 88)` açıklaması netleştirilir.

---

### Faz B: Durumsal Dürüstlük Durum Makinesi (`:budget_exhausted`) & Timeout Yönetimi
**Hedef:** Bütçesi tükenen alt ajanın sahte `:completed` olmasını engellemek ve amaca uygun durum/teşhis üretmek.

1. **`Instance#pause_and_await_budget_expansion!` (`lib/rubik/orchestrator/subagent/instance.rb`):**
   - Parametre imzası: `def pause_and_await_budget_expansion!(wait_timeout = nil)`
   - Timeout çözümleme: `timeout = wait_timeout || (@config.respond_to?(:fetch) ? @config.fetch("subagents.budget_wait_timeout", 180) : 180) || 180`
   - Zaman aşımına uğrandığında:
     ```ruby
     @monitor.synchronize do
       @budget_cond.wait(timeout) if @state == :waiting_budget
       if @state == :waiting_budget
         @state = :budget_exhausted
         @result = "Subagent reached step budget (#{@budget.max_steps} steps) and halted: task was NOT completed. Budget expansion was not received from init-0."
         false
       else
         @state = :running
       end
     end
     ```
2. **Durum Makinesi Genişletmesi (`instance.rb`):**
   - `running?`: `@state == :running || @state == :waiting_input || @state == :waiting_budget`
   - `active?`: `[:pending, :running, :waiting_input, :waiting_budget, :canceling].include?(@state)` (`:budget_exhausted` aktif değil, durmuş terminal durumdur).
   - `grant_budget!`: Terminal durumlar listesine `:budget_exhausted` eklenir:
     `return false if [:completed, :failed, :disposed, :canceling, :budget_exhausted].include?(@state)`
     (Thread timeout olup ensure bloğundan context cleanup yapıldığı için durmuş subagent diriltilemez; yeni subagent başlatılmalıdır).
3. **`Supervisor#handle_subagent_completion` Güvencesi:**
   - `merge_branch_buffer` ve `auto_apply_subagent_buffer` yalnızca `inst.state == :completed` iken çalışır. `:budget_exhausted` durumunda eksik kod diske asla uygulanmaz.
4. **`manage_subagents` Araç Çıktıları (`lib/rubik/tools/builtins/subagent.rb`):**
   - `action: "wait"`:
     - Eğer durum `budget_exhausted` ise:
       `• [subagent-X] 'Role' (type) - BUDGET_EXHAUSTED`
       `  Result: Subagent reached step budget (88 steps) and halted: task was NOT completed...`
       `  Guidance: Task was not completed (step budget exhausted). Inspect transcript or spawn a new subagent.`
     - Eğer durum `waiting_budget` ise:
       `• [subagent-X] 'Role' (type) - WAITING_BUDGET (88/88 steps)`
       `  Guidance: Subagent paused at step budget. Call manage_subagents(action: 'extend_budget', conversation_id: 'subagent-X', steps: 20) to resume.`
   - `action: "status"`:
     - `inst.state == :budget_exhausted` durumunda net guidance alanı eklenir.
   - **Önemli Hijyen Kuralı:** `lib/rubik/tools/builtins/subagent.rb` içindeki mevcut yardımcı metotlar (symbolize_keys, normalize_spec) sıkılaştırılarak toplam satır sayısı 335-340 bandında tutulur, 350 satır sınırı asla ihlal edilmez.
5. **`Notices` Modülü (`lib/rubik/orchestrator/subagent/notices.rb`):**
   - `user_line`:
     `elsif notice[:state] == "budget_exhausted"` -> `"🛑 [Subagent Budget Exhausted] [#{notice[:id]}] '#{notice[:role]}' - BUDGET_EXHAUSTED (task incomplete)"`
   - `guidance_for`:
     `elsif notice[:state] == "budget_exhausted"` -> `"Subagent halted: ran out of step budget. Task was NOT completed. Inspect transcript or launch a new subagent."`

---

### Faz C: Sağlayıcı Concurrency Gate Mimarisi (`provider_concurrency: 2`)
**Hedef:** Dış LLM API'sine aynı anda giden istekleri kontrol altına alarak soket tıkanması ve 90s Read Timeout hatalarını tamamen bertaraf etmek.

1. **`ConcurrencyGate` Sınıfı (`lib/rubik/orchestrator/subagent/concurrency_gate.rb`):**
   - Standart kütüphane `Thread::SizedQueue` kullanılarak yüksek performanslı, deadlock-free ve sızıntısız bir semafor tasarlanır:
     ```ruby
     # frozen_string_literal: true

     module Rubik
       module Orchestrator
         module Subagent
           # Semaphore gate limiting concurrent outbound LLM requests across subagents (Plan 97).
           # Prevents network queue exhaustion and 90s provider read timeouts under load.
           class ConcurrencyGate
             attr_reader :capacity

             def initialize(capacity = 2)
               @capacity = [capacity.to_i, 1].max
               @queue = Thread::SizedQueue.new(@capacity)
               @capacity.times { @queue.push(:token) }
             end

             def synchronize
               token = @queue.pop
               acquired = true
               begin
                 yield
               ensure
                 @queue.push(token) if acquired
               end
             end

             def active_count
               @capacity - @queue.size
             end

             def available_count
               @queue.size
             end
           end
         end
       end
     end
     ```
2. **`Supervisor` Entegrasyonu (`lib/rubik/orchestrator/subagent/supervisor.rb`):**
   - `Supervisor#initialize` içinde `@provider_gate = ConcurrencyGate.new((config&.fetch("subagents.provider_concurrency", 2) || 2).to_i)`.
   - `spawn` çağrısında `Instance.new(..., provider_gate: @provider_gate)`.
3. **`Instance#initialize` (`lib/rubik/orchestrator/subagent/instance.rb`):**
   - `provider_gate: nil` opsiyonel parametresi eklenir (geriye dönük uyumluluk ve bağımsız instance testleri için nil güvenli).
4. **`StepRunner#invoke_provider_with_recovery` (`lib/rubik/orchestrator/subagent/step_runner.rb`):**
   - Sağlayıcı HTTP çağrısı `@provider_gate` varsa `synchronize` bloğu içine alınır:
     ```ruby
     def invoke_provider_with_recovery(opts)
       ProviderRecovery.with_recovery(config: @config, compact: method(:emergency_compact_and_notify!)) do
         if @provider_gate
           @provider_gate.synchronize { invoke_provider(opts) }
         else
           invoke_provider(opts)
         end
       end
     end
     ```
   - Gate'in `with_recovery` bloğunun **içinde** yer alması sayesinde retry durumunda token serbest bırakılır ve bekleyen diğer subagent'lar için starvation engellenir.

---

### Faz D: Testler ve Doğrulama

1. **Bütçe Skalası Testleri:**
   - `test/unit/test_subagent_budget.rb`: Varsayılan 88 adım bütçesi ve 20 adım grant doğrulamaları güncellenir.
   - `test/unit/test_subagent_orchestration.rb`: `test_default_max_steps_from_config` (88 adımı doğrular).
2. **Durum Makinesi Testleri (`:budget_exhausted`):**
   - `test/unit/test_subagent_orchestration.rb`: `test_pause_and_await_budget_expansion_timeout` artık `:completed` değil `:budget_exhausted` durumunu ve eksiklik mesajını doğrular.
   - `test/unit/test_instance_grant_budget.rb`: `:budget_exhausted` durumundaki instance'a grant verilmesinin reddedildiğini test eder.
   - `test_manage_subagents_wait_with_budget_pause_guidance`: `WAITING_BUDGET` ve `BUDGET_EXHAUSTED` rehberlik metinlerini doğrular.
3. **Concurrency Gate Testleri (`test/unit/test_subagent_concurrency_gate.rb`):**
   - 5 eşzamanlı thread'in aynı anda gate'e girdiği, havada (in-flight) eşzamanlı çalışan iş sayısının asla `capacity` (2) değerini aşmadığı, işlemlerin hatasız tamamlandığı ve token sızıntısı olmadığını doğrulayan bağımsız minitest süiti.
4. **Modül Hijyeni ve Gerileme Testleri:**
   - `test_module_hygiene.rb` satır tavanı sınırlarına tam uyum:
     - `tools/builtins/subagent.rb` < 350
     - `orchestrator/subagent/supervisor.rb` < 350
     - `orchestrator/subagent/instance.rb` < 350
     - `orchestrator/subagent/step_runner.rb` < 250
     - `orchestrator/subagent/notices.rb` < 150
     - `orchestrator/subagent/budget.rb` < 150
     - `orchestrator/subagent/concurrency_gate.rb` < 100
   - `bundle exec rake test` ile mevcut tüm testlerin %100 yeşil kalması.

---

## 📋 4. Kontrol Listesi (Checklist)

- [x] Plan AGENTS.md, Spatiotemporal Composability ve modül hijyeni açısından incelendi mi?
- [x] `DEFAULT_MAX_STEPS = 88` ve `subagents.default_max_steps = 88` yapıldı mı?
- [x] `DEFAULT_GRANT_STEPS = 20` olarak ayarlandı mı?
- [x] `invoke_subagent` parametre şemasına `max_steps` (default 88) netleştirildi mi?
- [x] Bütçe bekleme zaman aşımı `budget_wait_timeout = 180` saniyeye çıkarıldı mı?
- [x] Bütçesi tükenip timeout olan alt ajan kesinlikle `:budget_exhausted` durumuna geçiyor mu?
- [x] `:budget_exhausted` durumundaki ajanın sahte `:completed` olması engellendi mi?
- [x] `ConcurrencyGate` semaforu oluşturuldu ve varsayılan `provider_concurrency = 2` olarak bağlandı mı?
- [x] `StepRunner` LLM çağrılarını `provider_gate.synchronize` ile koruyor mu?
- [x] `lib/rubik/tools/builtins/subagent.rb` satır sayısı 350 altında korundu mu?
- [x] Tüm birim ve entegrasyon testleri başarıyla geçiyor mu (0 failure, 0 error)?

---

## 🚀 5. Uygulama Sonucu (Implementation Log)

> **Uygulama Tarihi:** 21 Eylül 2026  
> **Uygulayan:** Plan 97 Executor (Çoklu Ajan Teamwork: Reviewer → Executor → Execution Reviewer)  
> **Test Sonucu:** 1930 runs, 11199 assertions, 0 failures, 0 errors, 1 skips

### Değiştirilen Dosyalar

| Dosya | Değişiklik |
| :--- | :--- |
| `lib/rubik/orchestrator/subagent/budget.rb` | `DEFAULT_MAX_STEPS = 88`, `DEFAULT_GRANT_STEPS = 20` |
| `lib/rubik/config/defaults.rb` | `default_max_steps: 88`, `provider_concurrency: 2`, `budget_wait_timeout: 180` |
| `lib/rubik/orchestrator/subagent/supervisor.rb` | `@provider_gate`, `@default_max_steps` fallback 88, `extend_budget` default 20 adım |
| `lib/rubik/orchestrator/subagent/instance.rb` | `:budget_exhausted` durum geçişi, 180s timeout, `grant_budget!` terminal listesi genişletildi |
| `lib/rubik/orchestrator/subagent/step_runner.rb` | `invoke_provider_with_recovery` → `provider_gate.synchronize` ile sarıldı |
| `lib/rubik/orchestrator/subagent/notices.rb` | `budget_exhausted` bildirimi ve kurtarma rehberliği, `extend_budget_hint(steps: 20)` |
| `lib/rubik/tools/builtins/subagent.rb` | `max_steps` şeması, `BUDGET_EXHAUSTED` High-SNR teşhis, 340 satır (< 350 tavan) |

### Yeni Dosyalar

| Dosya | Açıklama |
| :--- | :--- |
| `lib/rubik/orchestrator/subagent/concurrency_gate.rb` | `Thread::SizedQueue` tabanlı, deadlock-free, sızıntısız LLM semafor sınıfı |
| `test/unit/test_subagent_budget_scale.rb` | 88 adım varsayılanı, 75% uyarısı (66. adım), dinamik `max_steps` testleri |
| `test/unit/test_instance_budget_state_machine.rb` | `:budget_exhausted` durum geçişi ve dürüst raporlama testleri |
| `test/unit/test_subagent_concurrency_gate.rb` | Eşzamanlı 5 thread → max 2 in-flight LLM isteği, token sızıntısı yok |

### Test Detayları

- `test_subagent_budget_scale.rb`: 4 runs, 11 assertions, 0 failures, 0 errors
- `test_instance_budget_state_machine.rb`: 4 runs, 21 assertions, 0 failures, 0 errors
- `test_subagent_concurrency_gate.rb`: 4 runs, 12 assertions, 0 failures, 0 errors
- `test_subagent_budget.rb`: 9 runs, 27 assertions, 0 failures, 0 errors
- `test_instance_grant_budget.rb`: 10 runs, 31 assertions, 0 failures, 0 errors
- `test_subagent_orchestration.rb`: 31 runs, 174 assertions, 0 failures, 0 errors
- `test_module_hygiene.rb`: 11 runs, 77 assertions, 0 failures, 0 errors
- `bundle exec rubocop`: 20 files inspected, no offenses detected

### Kök Neden Çözüm Özeti

| Kök Neden | Çözüm |
| :--- | :--- |
| 25 adımlık bütçe keşif aşamasında tükeniyor | `DEFAULT_MAX_STEPS = 88` — keşif + düzenleme + test döngüsü için yeterli alan |
| Bütçe bitti = sahte `:completed` — üst ajan aldatılıyor | `:budget_exhausted` terminal durumu — "task was NOT completed" mesajı ile dürüst raporlama |
| 60s timeout çok kısa, üst ajan fırsat bulamıyor | `budget_wait_timeout = 180s` — LLM stream/düşünme turu bitmeden önce ajan ölmüyor |
| 5 ajan aynı anda LLM'e → 90s read timeout | `ConcurrencyGate(capacity: 2)` — eşzamanlı HTTP isteği en fazla 2, kuyruk önlendi |

