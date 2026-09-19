# Plan 94 — Alt-Ajan Hiyerarşisi, Linux Init (PID 1) Mimarisi ve Asenkron İzole Bağlam Orkestrasyonu (`invoke_subagent`)

> **Durum:** ✅ **Tamamlandı**  
> **Zorluk:** İleri Düzey (Zor)  
> **Faz:** 9 (Ajan Zekası & Çoklu Ajan Mimarisi)  
> **Öneri Bölümü:** Çoklu Ajan Orkestrasyonu, İzolasyon, Asenkron Süreçler & Alt-Bağlamlar  
> **İlgili Planlar:** [03](03-dosya-tamponu-snapshot-undo.md), [10](10-tool-calling-orkestrasyon.md), [16](16-genisletilmis-arac-seti-ve-planlama.md), [20](20-spatiotemporal-composability-eklenti-dongusu.md), [33](33-spatiotemporal-coeffect-inverses-ve-runtime-gorsellestirme.md), [42](42-orchestrator-loop-dekompozisyonu-ve-llm-formatlayici.md), [47](47-orchestrator-loopun-reaktif-sistem-fiberina-donusturulmesi.md), [88](88-tampon-cakisma-deadlock-cozumu-ve-apply-buffer-guclendirmesi.md), [93](93-asenkron-arka-plan-surecleri-ve-gorev-yoneticisi-manage-task.md), [AGENTS.md](../AGENTS.md)

---

## 🎯 1. Motivasyon ve Mimari Vizyon

Modern frontier otonom kodlama ajanlarında karmaşık, çok aşamalı veya geniş kapsamlı görevler (derin kod tabanı keşfi, paralel dosya tarama, güvenlik/test denetimleri, büyük refaktörler) **tek bir doğrusal ajan döngüsü (monolithic single-agent loop)** içinde yürütüldüğünde ciddi sistem darboğazlarına yol açar:

### 🔍 Temel Sorunlar:
1. **Bağlam Şişmesi ve Kirlenmesi (Context Bloat & Token Pollution):**
   - Ana ajan bir kütüphaneyi veya hatayı araştırırken 20 farklı dosya okuduğunda ve binlerce satır log ürettiğinde ana konuşma hafızası dolar. Model asıl nihai hedefini (`goal`) unutmaya başlar veya erken bağlam sıkıştırmaya (`compaction`) zorlanır.
2. **Senkron Bloklanma ve Verimsizlik (Synchronous Bottleneck):**
   - Ajan uzun süren bir keşif veya analiz işini yaparken tüm REPL ve operatör etkileşimi donar; arka planda bağımsız ilerleyebilecek alt işler için sistem bloke olur.
3. **Rol, Persona ve Sistem Promptu Özelleştirme Eksikliği:**
   - Bir araştırma ajanının yalnızca okuma odaklı, tarafsız ve metodik bir araştırmacı personasına; bir güvenlik ajanının ise kırmızı-takım (red-team) kurallarına ihtiyacı vardır. Tek bir sabit sistem promptu ile tüm rolleri yönetmek dikkat dağınıklığına yol açar.
4. **Hata İzolasyonu ve Tampon Kirlenmesi (Buffer & State Contamination):**
   - Keşif ve deneme aşamasında yapılan geçici dosya değişiklikleri ana tamponu (`BufferManager`) kirletir. Deneme başarısız olduğunda sistem durumunun temiz geri alınması zorlaşır.
5. **Yetki Aşımı ve Zombi Ajan Riski (Least Privilege & Zombie Agents):**
   - Sadece araştırma yapacak bir alt ajana yazma veya süreç başlatma yetkisi vermek halüsinasyon riskini artırır. Ayrıca ebeveyn ajan sonlandığında arkada asılı kalan alt ajanların (zombie agents) temizlenmesi gerekir.

---

## 🏛️ 2. Linux Init (PID 1 / Init 0) Süpervizör Mimarisi ve `AGENTS.md` Değişmezleri

Unix/Linux işletim sistemlerinde `init` (PID 1 / `systemd`), tüm kullanıcı süreçlerinin mutlak atasıdır. Süreçleri başlatır, süpervize eder, yetim kalan süreçleri (orphaned processes) evlat edinip temizler (`orphan reaping`) ve `init 0` (sistem kapatma) çağrıldığında tüm ağacı LIFO/ters bağımlılık sırasıyla zarifçe kapatır.

Rubik'in çoklu ajan mimarisi bu modeli tam olarak benimser:

```
                          ┌─────────────────────────────────────────────────────────┐
                          │               [init-0] ROOT SUPERVISOR AGENT            │
                          │   (PID 1 / Root Fiber / Interactive REPL Session Loop)  │
                          │       Root Context σ₀  •  Root BufferManager            │
                          └────────────────────────────┬────────────────────────────┘
                                                       │
                          ┌────────────────────────────┴────────────────────────────┐
                          ▼ invoke_subagent (Async Background Job)                  ▼ invoke_subagent
          ┌─────────────────────────────────────────┐               ┌─────────────────────────────────────────┐
          │      [agent-1] CODEBASE RESEARCHER      │               │       [agent-2] SECURITY AUDITOR        │
          │         (Background Fiber / Thread)     │               │       (Background Fiber / Thread)       │
          ├─────────────────────────────────────────┤               ├─────────────────────────────────────────┤
          │ • Sub-Context: ctx.extend()             │               │ • Sub-Context: ctx.extend()             │
          │ • Persona: Researcher System Prompt     │               │ • Persona: Red-Team Auditor Prompt      │
          │ • Tools: Read-Only Toolset              │               │ • Tools: Scoped Verification Tools      │
          │ • Workspace: Inherit (Read-Only)        │               │ • Workspace: Branch (Virtual Buffer)    │
          │ • LIFO Inverses Accumulator: Ω₁         │               │ • LIFO Inverses Accumulator: Ω₂         │
          └────────────────────┬────────────────────┘               └─────────────────────────────────────────┘
                               │
                               ▼ invoke_subagent (Child if depth < max_depth)
          ┌─────────────────────────────────────────┐
          │     [agent-1.1] DEPENDENCY MAPPER       │
          │      (Leaf Subagent / Depth = 2)        │
          └─────────────────────────────────────────┘
```

### Temel Prensipler ve Değişmezler:

1. **`agent-0` (Init 0 / Root Supervisor):**
   - Rubik REPL açıldığında başlayan ana etkileşimli ajan **`agent-0` (Root Supervisor)** olarak konumlanır.
   - Root context ($\sigma_0$), genel `BufferManager`, `TaskManager` ve `SubagentSupervisor` bu kök üzerinde yaşar.
2. **Yetim Süreç Temizliği (Orphan Reaping):**
   - Bir ara alt ajan çökerse veya sonlandırılırsa, onun açtığı alt bağlamlar ve çocuk ajanlar `agent-0` tarafından tespit edilip temizlenir (`prune_child` + LIFO $\Omega$ çözünmesi) veya gözetim altına alınır.
3. **`init 0` Toptan Güvenli Kapatma:**
   - Kullanıcı REPL'i kapattığında (`!exit`, `Ctrl+C`) veya oturum sonlandığında, `agent-0` tüm alt ajan ağacına sonlandırma sinyali gönderir, açık iş parçacıklarını durdurur ve sanal tampon dallarını temizleyerek sıfır kaynak sızıntısıyla kapanır ($A(\sigma) \sim \sigma_0$).
4. **Asenkron Arka Plan Süreç Paradigması (Non-blocking Background Task):**
   - Alt ajanlar ana döngüyü bloklamaz. `invoke_subagent` çağrısı yapıldığı anda alt ajan bağımsız bir arka plan sürecinde/iş parçacığında başlatılır ve çağrıyı yapan ajana anında tanıtıcı kimlik (`conversation_id: "subagent-1"`) ile kontrol döner.
5. **Reaktif Uyanma (Reactive Wakeup):**
   - Çağıran ajan alt ajanı döngüde beklemez (`no busy polling`). Alt ajan görevini tamamladığında, hata aldığında veya mesaj gönderdiğinde Rubik'in olay hattı üzerinden çağıran ajana yüksek öncelikli bildirim düşer ve uyanma gerçekleşir.
6. **Rol, Görev ve Özel/Miras Sistem Promptu Enjeksiyonu:**
   - Her alt ajan delege edilirken 4 katmanda özelleştirilir:
     - **Role (`role`):** 2-5 kelimelik meslek/unvan tanımı (örn. `"Codebase Researcher"`, `"Database Debugger"`, `"Refactoring Specialist"`).
     - **Task Prompt (`prompt`):** Yapılacak somut, net ve eyleme dönük görev tanımı.
     - **System Prompt (`system_prompt`):** Ebeveynin kurallarını devralan (`inherit`) veya role özel kural ve kısıtlamalar içeren (`custom`) sistem yönergesi.
     - **Tip/Şablon (`type_name`):** Standart katalog (`research`, `self`, `coder`) veya `define_subagent` ile canlı tanımlanmış özel ajan arketipi.
7. **Çatallanmış Sanal Tampon (Virtual Buffer Branching):**
   - Kod üzerinde değişiklik yapacak alt ajanlar ana tamponu doğrudan bozmaz; `buffer_manager.branch` üzerinde izole çalışır. Yalnızca başarıyla tamamlanıp onaylandığında ana tampona birleştirilir (`merge!`).

---

## 🔄 3. Alt Ajan Yaşam Döngüsü Durum Makinesi (State Machine)

Her alt ajan örneği (`SubagentInstance`) aşağıdaki deterministik yaşam döngüsü durumlarını izler:

```
                      [ invoke_subagent ]
                               │
                               ▼
                      ┌─────────────────┐
                      │     PENDING     │  (Bağlam ctx.extend(), araçlar filtrelendi)
                      └────────┬────────┘
                               │ Thread/Fiber başlatıldı
                               ▼
                      ┌─────────────────┐
            ┌─────────┤     RUNNING     ├──────────────────────────┐
            │         └────────┬────────┘                          │
            │                  │                                   │
            │ Girdi/Mesaj      │ Görev Tamamlandı                  │ İptal / Kill İsteği
            │ Bekliyor         ▼                                   │ veya Timeout
            │         ┌─────────────────┐                          │
            └────────►│  WAITING_INPUT  │                          │
            ▲         └────────┬────────┘                          │
            │                  │ send_message                      │
            └──────────────────┘                                   │
                               │                                   ▼
                               ▼                         ┌───────────────────┐
                      ┌─────────────────┐                │     CANCELING     │
                      │    COMPLETED    │                └─────────┬─────────┘
                      └────────┬────────┘                          │
                               │ LIFO Ω Geri Alma /                │ LIFO Ω Rollback
                               │ Sanal Tampon Birleştirme          ▼
                               │                         ┌───────────────────┐
                               │                         │      FAILED       │
                               │                         └─────────┬─────────┘
                               ▼                                   │
                      ┌────────────────────────────────────────────▼┐
                      │                  DISPOSED                   │
                      │  (ctx.dispose, kaynaklar ve thread temiz)   │
                      └─────────────────────────────────────────────┘
```

---

## 🏗️ 4. Mimari Tasarım ve Bileşenler

### 📦 Bileşen 1: `SubagentSupervisor` (Init 0 Çekirdeği)
**Dosya:** `lib/rubik/orchestrator/subagent/supervisor.rb` (`Rubik::Orchestrator::Subagent::Supervisor`)
**Satır Tavanı:** < 250 satır

- **Sorumlulukları:**
  - Kök ajan (`init-0`) adına tüm alt ajan ağacının kayıt defterini tutar.
  - Eşzamanlı alt ajan çalıştırma havuzunu (`Concurrent Pool`) yönetir.
  - Özyineleme derinlik sınırını (`max_depth = 2`) ve maksimum eşzamanlı ajan sayısını (`max_concurrency = 5`) denetler.
  - Alt ajanlardan gelen tamamlama bildirimlerini yakalar ve çağıran ajana reaktif mesaj olarak iletir.
  - `reap_orphans` ve `shutdown_all` (`init 0`) işlemlerini yürütür.

```ruby
module Rubik
  module Orchestrator
    module Subagent
      class Supervisor
        attr_reader :root_context, :instances

        def initialize(root_context:, buffer_manager:, tool_registry:, provider:, config:)
          @root_context = root_context
          @buffer_manager = buffer_manager
          @tool_registry = tool_registry
          @provider = provider
          @config = config
          @instances = {} # id -> SubagentInstance
          @monitor = Monitor.new
          @max_depth = 2
          @max_concurrency = config.fetch("subagents.max_concurrency", 5).to_i
        end

        def spawn(type_name:, role:, prompt:, system_prompt: nil, parent_id: "agent-0", workspace: "inherit", model: "inherit")
          # Derinlik ve eşzamanlılık kontrolü
          # Alt bağlam ctx.extend() oluşturma
          # SubagentInstance başlatma (arka plan iş parçacığı)
          # instances haritasına kaydetme
        end

        def get(conversation_id)
          @monitor.synchronize { @instances[conversation_id] }
        end

        def list(parent_id: nil)
          @monitor.synchronize do
            list = @instances.values
            list = list.select { |i| i.parent_id == parent_id } if parent_id
            list.map(&:to_h)
          end
        end

        def send_message(recipient_id, message, sender_id: "agent-0")
          # Hedef alt ajanın gelen kutusuna (inbox) mesaj bırakır ve bekleyen ajanı uyandırır
        end

        def kill(conversation_id)
          # Alt ajanı ve altındaki tüm çocukları Platform.kill_tree benzeri LIFO ile sonlandırır
        end

        def shutdown_all
          # init 0: Tüm alt ajanları ters sırada kapatır
        end
      end
    end
  end
end
```

---

### 📦 Bileşen 2: `SubagentInstance` (Asenkron İş/Fiber Temsili)
**Dosya:** `lib/rubik/orchestrator/subagent/instance.rb` (`Rubik::Orchestrator::Subagent::Instance`)
**Satır Tavanı:** < 250 satır

- **Sorumlulukları:**
  - Tek bir alt ajanın yaşam döngüsünü, bağımsız konuşma geçmişini (`history`), sanal tampon dalını (`branched_buffer`) ve çalışma iş parçacığını (`Thread`) yönetir.
  - Rol ve tipine göre filtrelenmiş `Tool::Registry` kopyasını çalıştırır.
  - Çıktı ve düşünce akışını izole log dosyasında / transcript'inde (`transcript.jsonl`) tutar.
  - Tamamlandığında ebeveyne yapılandırılmış sentez raporu (`synthesis_report`) üretir.

```ruby
module Rubik
  module Orchestrator
    module Subagent
      class Instance
        attr_reader :id, :parent_id, :role, :type_name, :state, :started_at, :ended_at, :context, :transcript_uri

        # State: :pending, :running, :waiting_input, :completed, :failed, :canceled, :disposed
        def start_async(&on_complete)
          @thread = Thread.new do
            run_loop
            on_complete&.call(self)
          end
        end

        def run_loop
          # İzole LLM döngüsü (max_steps tavanı ile)
          # Her adım izole transcript'e işlenir
          # Sonuç sentez raporuna dönüştürülür
        end

        def post_message(message)
          @inbox.push(message)
        end

        def cancel!
          @state = :canceling
          @thread&.kill
          cleanup
        end

        def cleanup
          # LIFO Ω dispose, çocuk bağlam budama, sanal tampon kapatma
        end
      end
    end
  end
end
```

---

### 📦 Bileşen 3: `TypeRegistry` (Ajan Tipleri & Arketip Kataloğu)
**Dosya:** `lib/rubik/orchestrator/subagent/type_registry.rb` (`Rubik::Orchestrator::Subagent::TypeRegistry`)
**Satır Tavanı:** < 200 satır

- **Yerleşik Arketipler (Built-in Archetypes):**
  1. `research`:
     - **Persona:** Derin araştırma, semantik kod analizi, tarafsız bilgi derleme.
     - **İzin Verilen Araçlar:** `read_file`, `list_files`, `grep_search`, `search_symbols`, `get_outline`, `find_references`, `get_symbol`, `lsp_hover`, `lsp_definition`, `lsp_diagnostics`.
     - **Yasaklı:** Tüm dosya yazma, komut çalıştırma ve alt-ajan çağırma araçları.
  2. `self`:
     - **Persona:** Ebeveyn ajanın tam kopyası.
     - **İzin Verilen Araçlar:** Alt-ajan çağırma hariç (`invoke_subagent` kapalıdır, depth-guard) tüm ebeveyn araç seti.
  3. `coder`:
     - **Persona:** Odaklanmış kodlama ve birim test doğrulama uzmanı.
     - **İzin Verilen Araçlar:** `read_file`, `write_file`, `replace_file_content`, `run_tests`, `lsp_diagnostics`.
- **Dinamik Arketip Tanımlama (`define_subagent`):**
  - Model çalışma esnasında yeni arketip tipleri tanımlayabilir (`name`, `description`, `system_prompt`, `enable_write_tools`, `enable_subagent_tools`).

---

### 🛠️ Bileşen 4: Araç Katmanı (Built-in Tools)
**Dosya:** `lib/rubik/tools/builtins/subagent.rb` (`Rubik::Tools::SubagentTools`)
**Satır Tavanı:** < 300 satır (veya domain ayrımı ile < 250 satır)

Dört temel ajan etkileşim aracı bu dosyada yer alır:

#### 1. `invoke_subagent` (Asenkron Başlatma)
- **Parametreler:**
  - `subagents` *(array of objects, required)*:
    - `type_name` *(string, required)*: `research`, `self`, `coder` veya özel tanımlı arketip adı.
    - `role` *(string, required)*: 2-5 kelimelik unvan (örn. `"Database Performance Profiler"`).
    - `prompt` *(string, required)*: Net, eyleme dökülebilir görev talimatı.
    - `system_prompt` *(string, optional)*: Özel talimatlar; verilmezse arketipin veya ebeveynin varsayılanı kullanılır.
    - `workspace` *(string, optional, enum: `["inherit", "branch", "share"]`, default: `"inherit"`)*: Tampon yalıtım seviyesi.
    - `model` *(string, optional, enum: `["inherit", "flash_lite", "flash", "pro"]`, default: `"inherit"`)*: Model katmanı seçimi.
- **Dönüş:** Asenkron işlerin başlatıldığına dair tanıtıcı kimlikler (`conversation_id`), roller ve durum özeti.

#### 2. `manage_subagents` (Süpervizör Denetimi)
- **Parametreler:**
  - `action` *(string, required, enum: `["list", "status", "kill", "kill_all"]`)*.
  - `conversation_ids` *(array of string, optional)*: İşlem yapılacak ajan kimlikleri (`kill` için).
- **Dönüş:** Canlı durum tablosu, transcript URI'leri ve adımları.

#### 3. `send_message` (Ajanlar Arası Mesajlaşma)
- **Parametreler:**
  - `recipient` *(string, required)*: Hedef ajanın `conversation_id` kimliği.
  - `message` *(string, required)*: İletilecek metin/talimat içeriği.

#### 4. `define_subagent` (Dinamik Arketip Tanımlama)
- **Parametreler:**
  - `name` *(string, required)*: Yeni arketipin adı (örn. `security_auditor`).
  - `description` *(string, required)*: Modelin arketipi ne zaman seçeceğini açıklayan metin.
  - `system_prompt` *(string, required)*: Arketipe özgü temel sistem talimatı.
  - `enable_write_tools` *(boolean, optional, default: false)*: Dosya yazma yetkisi.
  - `enable_subagent_tools` *(boolean, optional, default: false)*: Kendi altında alt ajan çağırma yetkisi.

---

### 🖥️ Bileşen 5: REPL Bang Komutu (`!subagents`)
**Dosya:** `lib/rubik/repl/commands/subagents.rb`
**Satır Tavanı:** < 150 satır

İnsan operatör için tam görünürlük ve denetim sağlar:
- `!subagents` / `!subagents list`: Tüm aktif ve geçmiş alt ajanları ağaç biçiminde (PID/ID, rol, durum, harcanan token ve çalışma süresi) döker.
- `!subagents status <id>`: Seçilen alt ajanın detaylı durumunu, transcript özetini ve son araç çağrısını gösterir.
- `!subagents logs <id> [--tail N]`: Alt ajanın konuşma ve araç günlüğünü görüntüler.
- `!subagents kill <id>` / `!subagents kill-all`: Süreçleri iptal eder.

---

## 🧪 5. Test Senaryoları ve Kabul Kriterleri

1. **Linux Init Ağacı & PID 1 Hiyerarşisi:**
   - Kök ajanın `agent-0` olarak başladığı, üretilen alt ajanların `agent-1`, `agent-2` şeklinde hiyerarşik kimliklendiği doğrulanır.
2. **Asenkron Başlatma (Non-blocking):**
   - `invoke_subagent` çağrısının alt ajanın bitmesini beklemeden < 50ms içinde `conversation_id` döndüğü test edilir.
3. **Reaktif Uyanma ve Bildirim:**
   - Arka planda tamamlanan bir alt ajanın sonucunun, ana ajanın olay hattına `MESSAGE_PRIORITY_HIGH` ile ulaştığı ve ana ajanın uyanarak sonucu teslim aldığı teyit edilir.
4. **Rol ve Özel/Miras Sistem Promptu Enjeksiyonu:**
   - `system_prompt` parametresi verildiğinde alt ajanın promptunun özel talimatı içerdiği; verilmediğinde arketip veya ebeveyn miras promptunu kullandığı doğrulanır.
5. **Araştırmacı Rolü Araç Kısıtlaması (Least Privilege):**
   - `type_name: "research"` ile açılan bir alt ajanın araç kütüğünde `write_file`, `replace_file_content` veya `run_command` araçlarının bulunmadığı test edilir.
6. **Dinamik Arketip Tanımlama (`define_subagent`):**
   - Çalışma anında yeni bir arketip tanımlandığı ve ardından `invoke_subagent` ile bu arketip tipinde başarılı bir ajan başlatılabildiği doğrulanır.
7. **Çatallanmış Sanal Tampon ve Rollback (Branch Workspace):**
   - `workspace: "branch"` modunda çalışan ve hata alan bir alt ajanın yaptığı dosya değişikliklerinin ana `BufferManager`'a sızmadığı, başarıyla tamamlanan ajanın değişikliklerinin ise atomik birleştirildiği teyit edilir.
8. **Özyineleme ve Derinlik Koruması (Depth Guard):**
   - Bir alt ajanın derinlik sınırını (`max_depth = 2`) aşamadığı, yaprak ajanlarda `invoke_subagent` aracının devre dışı bırakıldığı test edilir.
9. **Ajanlar Arası Mesajlaşma (`send_message`):**
   - Beklemedeki bir alt ajana `send_message` ile yeni talimat gönderildiğinde ajanın mesajı alıp yürütmeye devam ettiği test edilir.
10. **`init 0` Toptan Güvenli Kapatma & Sıfır Bellek Sızıntısı:**
    - `supervisor.shutdown_all` çağrıldığında tüm çalışan iş parçacıklarının sonlandırıldığı, çocuk bağlamların budandığı (`prune_child`), `disposable_count` değerinin başlangıç tabanına döndüğü doğrulanır.

---

## 📝 6. Dosya Tavanları ve Modül Hijyeni

Sistem bütünlüğü ve okunabilirlik için aşağıdaki satır sınırlarına harfiyen uyulur:

| Dosya | Modül / Sınıf | Satır Sınırı |
| :--- | :--- | :---: |
| `lib/rubik/orchestrator/subagent/supervisor.rb` | `Rubik::Orchestrator::Subagent::Supervisor` | < 250 satır |
| `lib/rubik/orchestrator/subagent/instance.rb` | `Rubik::Orchestrator::Subagent::Instance` | < 250 satır |
| `lib/rubik/orchestrator/subagent/type_registry.rb` | `Rubik::Orchestrator::Subagent::TypeRegistry` | < 200 satır |
| `lib/rubik/tools/builtins/subagent.rb` | `InvokeSubagentTool`, `ManageSubagentsTool` vb. | < 300 satır |
| `lib/rubik/repl/commands/subagents.rb` | `Rubik::REPL::Commands::Subagents` | < 150 satır |
| `test/unit/test_subagent_orchestration.rb` | Kapsamlı minitest paketi | Serbest |

---

## 🏁 7. Uygulama Adımları

1. **Adım 1:** `TypeRegistry` ve temel arketip şablonlarının (`research`, `self`, `coder`) kodlanması.
2. **Adım 2:** `SubagentInstance` yaşam döngüsü, asenkron `Thread` koşucusu ve izole transcript yönetiminin kurulması.
3. **Adım 3:** `SubagentSupervisor` (Init 0 süpervizörü) orkestrasyonunun, orphan reaping ve `shutdown_all` mekanizmalarının inşası.
4. **Adım 4:** `InvokeSubagentTool`, `ManageSubagentsTool`, `SendMessageTool`, `DefineSubagentTool` araçlarının yazılması ve `Registry.build_default`'a bağlanması.
5. **Adım 5:** REPL `!subagents` (`list`, `status`, `logs`, `kill`, `kill-all`) yönetim komutunun eklenmesi.
6. **Adım 6:** `test/unit/test_subagent_orchestration.rb` ile 10 test senaryosunun yazılması, `rake test` ve `rubocop` doğrulamalarının gerçekleştirilmesi.
7. **Adım 7:** `TOOLS.md`, `ARCHITECTURE.md`, `COMMANDS.md` ve indeks dosyalarının güncellenmesi.

---

## 🚀 8. Uygulama ve Doğrulama Raporu (Implementation & Verification Log)

- **Tarih:** 19 Eylül 2026
- **Sonuç:** ✅ **Başarıyla Tamamlandı (100% Yeşil Testler & Sıfır RuboCop İhlali)**
- **Yeni Çekirdek Bileşenler:**
  1. `lib/rubik/orchestrator/subagent/type_registry.rb` (~108 satır): Yerleşik arketipler (`research`, `self`, `coder`) ve dinamik arketip kaydı (`define_subagent`), araç filtreleme.
  2. `lib/rubik/orchestrator/subagent/instance.rb` (~248 satır): Durum makinesi (`:pending`, `:running`, `:waiting_input`, `:completed`, `:failed`, `:canceling`, `:disposed`), asenkron arka plan iş parçacığı (`Thread`), `inbox` kuyruğu, izole transkript kaydı.
  3. `lib/rubik/orchestrator/subagent/supervisor.rb` (~194 satır): Linux init (PID 1 / `init 0`) kök süpervizör mimarisi, derinlik sınırı (`max_depth = 2`), eşzamanlılık koruması (`max_concurrency = 5`), yetim toplama (`orphan reaping`) ve LIFO ters tasfiye (`shutdown_all`).
  4. `lib/rubik/tools/builtins/subagent.rb` (~226 satır): 4 yerleşik araç (`invoke_subagent`, `manage_subagents`, `send_message`, `define_subagent`), toplam araç sayısını 25'ten 29'a çıkardı.
  5. `lib/rubik/repl/commands/subagents.rb` (~125 satır): `!subagents` komutu (`list`, `status`, `types`, `kill`, `kill-all`).
- **Coeffect Entegrasyonu:**
  - `Rubik::Coeffects::SUBAGENT_SUPERVISOR = "subagent_supervisor"` tanımlandı ve REPL `wire_runtime_context` üzerinden sağlandı (`provide`).
- **Modül Hijyeni ve Satır Tavanları:**
  - Tüm dosyalar belirlenen satır limitlerinin altında tutuldu (`test_subagent_files_stay_small` ile minitest korumalı).
- **Test ve Kalite:**
  - `test/unit/test_subagent_orchestration.rb`: 18 test, 81 assertion, 0 failure, 0 error.
  - `test/unit/test_module_hygiene.rb`: 10 test, 68 assertion, 0 failure, 0 error.
  - `test/unit/test_expanded_tools.rb`: 19 test, 133 assertion, 0 failure, 0 error.
  - `test/unit/test_tool_aliasing_and_naming.rb`: 9 test, 127 assertion, 0 failure, 0 error.
  - `test/unit/test_repl_command_decoupling.rb`: 4 test, 62 assertion, 0 failure, 0 error.
  - RuboCop: 0 offenses across all modified files.

### 🔍 Fresh-Eye Diff Review & Sağlamlaştırma (Commit `1cfc4154` Sonrası)
- **Tarih:** 19 Eylül 2026
- **Sonuç:** ✅ **Tüm Bulgular Düzeltildi, Testler %100 Yeşil, 0 RuboCop İhlali**
- **Tespit Edilen Bulgular ve Çözümler:**
  1. **Zero-Restart Kuralı ve Bağlam Sızıntısı (`AGENTS.md` §6):**
     - *Bulgu:* Alt ajan tamamlandığında (`:completed` veya `:failed`) alt bağlamın `dispose`'u çağrılmıyordu; bu durum kök bağlamda biriken ters temizlik girdilerinin (`disposable_count`) artmasına yol açıyordu.
     - *Çözüm:* `SubagentInstance#start_async` içindeki `ensure` bloğuna `cleanup_context` çağrısı eklendi. İş parçacığı sonlandığında alt bağlam otomatik olarak LIFO sırasında tasfiye edilip kök bağlamdan prune edilir ve `disposable_count` başlangıç seviyesine geri döner.
  2. **Branch Workspace İzolasyonu ve Atomik Geri Alma / Birleştirme:**
     - *Bulgu:* `workspace: "branch"` parametresi sadece bir öznitelik olarak tutuluyor, bağımsız bir sanal tampon ve araç bağı oluşturulmuyordu.
     - *Çözüm:* `Supervisor#branch_or_inherit_buffer` metodu ile izole `Rubik::Buffer::Manager` kopyası üretildi. Dosya işlem araçları (`read_file`, `write_file`, `replace_file_content`, `apply_buffer`) bu izole tampona bağlandı. Görev `:completed` olduğunda `merge_branch_buffer` ile değişiklikler atomik olarak ana tampona aktarılır; `:failed` durumunda ise ana tampona hiçbir kirli girdi sızmaz (otomatik rollback).
  3. **Linux Init Modeli — Yetim Ajan Sahiplenme (`orphan reaping`):**
     - *Bulgu:* Ebeveyn bir alt ajan kapandığında veya öldürüldüğünde, hayatta kalan aktif çocukları kök süpervizör (`agent-0`) tarafından yetim olarak devralınamıyordu.
     - *Çözüm:* `reap_orphans` mekanizması güncellendi; ebeveyni aktif olmayan veya tasfiye edilen tüm alt ajanlar otomatik olarak `parent_id = "agent-0"`'a devredilir. `Supervisor#kill(id, cascade: false)` desteği sağlandı; `ManageSubagentsTool` ise kontrata uygun biçimde ağacı toptan temizlemek için `cascade: true` bayrağını kullanır.
  4. **Shell Kapanış Kancası:**
     - *Bulgu:* REPL Shell kapandığında (`Shell#stop`), süpervizörün `shutdown_all` metodu açıkça tetiklenmiyordu.
     - *Çözüm:* `Shell#stop` içine `@subagent_supervisor&.shutdown_all` eklenerek oturum kapanışında tüm alt ajanların LIFO ters sırada kapatılması garanti edildi.
  5. **Dokümantasyon Senkronizasyonu:**
     - *Bulgu:* `SELF_EVOLUTION.md` dosyasında yerleşik araç sayısı güncel değildi (22 araç listeleniyordu) ve `define_subagent` eksikti.
     - *Çözüm:* Toplam araç sayısı 29 olarak güncellendi ve `define_subagent` eklendi.
- **Satır Tavanı Doğrulaması:**
  - `instance.rb`: 243 satır (< 250)
  - `supervisor.rb`: 237 satır (< 250)
  - `type_registry.rb`: 124 satır (< 200)
  - `builtins/subagent.rb`: 263 satır (< 300)
  - `commands/subagents.rb`: 119 satır (< 150)
