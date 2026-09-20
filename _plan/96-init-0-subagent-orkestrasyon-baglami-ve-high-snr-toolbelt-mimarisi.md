# Plan 96 — `init-0` Kök Süpervizör Subagent Orkestrasyon Bağlamı, Arketip Farkındalığı ve High-SNR Toolbelt Mimarisi

> **Durum:** ✅ **Tamamlandı**  
> **Zorluk:** İleri Düzey (Zor)  
> **Faz:** 9 (Ajan Zekası & Çoklu Ajan Mimarisi)  
> **Öneri Bölümü:** Çoklu Ajan Orkestrasyonu, High-SNR Prompt Mimarisi, Arketip Yetki Farkındalığı, Canlı Bildirim Drenajı  
> **İlgili Planlar:** [10](10-tool-calling-orkestrasyon.md), [23](23-xml-yapilandirilmis-baglam-ve-agents-protokol-entegrasyonu.md), [32](32-agentic-tool-cagrilari-yapilandirilmis-io-ve-akilli-baglam-kirpma.md), [53](53-ajan-yuzeyi-kontrati-izleyici-siniflandirmali-komut-gorunurlugu.md), [56](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md), [94](94-alt-ajan-hiyerarsisi-ve-izole-baglam-orkestrasyonu-invoke-subagent.md), [95](95-subagent-baglam-ve-cikti-dayanikliligi-emergency-compactor-ve-io-guvenligi.md), [AGENTS.md](../AGENTS.md)

---

## 🎯 1. Motivasyon ve Temel Sorunlar (Kök Neden Analizi)

Plan 94 ve Plan 95 ile Rubik; alt-ajan yaşam döngüsü (`Supervisor`, `Instance`, `StepRunner`), arketip kataloğu (`TypeRegistry`), disposable sub-context izolasyonu (`ctx.extend`), sanal tampon (`branch`), acil durum sıkıştırması (`EmergencyCompactor`) ve savunmacı I/O filtrelerini (`Truncator`, `NativeSearch` limitleri) başarıyla kazandı.

Ancak gerçek kullanım denemelerinde kök süpervizörün (`init-0` / PID 1) alt ajanları koordine ederken **ciddi bir durumsal körlük (situational blindness) ve düşük sinyal-gürültü oranı (Low SNR)** yaşadığı tespit edilmiştir:

### 🔍 Kritik Bulgular ve Aksaklıklar:

1. **`init-0` Sistem Promptunda Sıfır Alt-Ajan Bağlamı:**
   - `ContextBuilder.build_system_context`, çalışma alanı (`<workspace_status>`), tampon (`<buffer_status>`), LSP (`<lsp_status>`) ve yetenekleri (`<skills>`) üretirken; **alt-ajan mimarisine dair tek bir XML etiketi dahi üretmemektedir**.
   - `build_system_prompt` metoduna `type_registry` veya `subagent_supervisor` nesnesi iletilmemektedir.
   - `init-0` (ana LLM), alt ajanların varlığını yalnızca fonksiyon çağırma şemasındaki (`tools`) kuru tanımlardan çıkarsamak zorundadır.

2. **Arketip Yetki Körlüğü ve Düzenleme İflasları:**
   - `invoke_subagent` parametre şemasında `type_name` için yalnızca `'research' (default), 'self', 'coder', or custom` yazmaktadır.
   - `init-0`, `research` arketipinin salt-okunur olduğunu; `write_file`, `replace_file_content`, `apply_buffer` ve `run_command` araçlarına sahip olmadığını (tool filtering) bilmemektedir.
   - Kodlama veya hata düzeltme yaptırmak istediği bir görevi arketip belirtmeden (varsayılan `research` ile) başlattığında, alt ajanın elinde dosya düzenleme aracı bulunmamakta ve görev başarısızlıkla sonuçlanmaktadır.
   - `workspace: "inherit"` ile `"branch"` arasındaki sanal tampon ve izolasyon farkı `init-0`'a açıklanmamaktadır.

3. **Çelişkili Bekleme Yönlendirmesi ve Döngü Erken Terki:**
   - `invoke_subagent` başarı çıktısı: `"Subagents run asynchronously. Use manage_subagents(action: 'status', conversation_id: '...') to inspect progress/result..."` diyerek modeli `status` polling yapmaya teşvik etmektedir.
   - `manage_subagents(action: 'status')` ise modele: `"DO NOT poll 'status' in a loop! Call manage_subagents(action: 'wait', timeout: 30) or stop calling tools to receive reactive wakeup"` yanıtını dönmektedir.
   - Model araç çağırmayı durdurursa (reaktif uyandırma umuduyla), Rubik'in `Loop#execute_steps` döngüsü araçsız metin yanıtını son adım sayarak turu bitirmekte ve REPL kontrolünü kullanıcıya devretmektedir. Çünkü `Loop` içinde alt ajan bitişini bekleyen bir reaktif `mailbox` dinleyicisi yoktur.

4. **Genişletilmiş Toolbelt'te Düşük SNR:**
   - `ContextBuilder.build_operational_rules_xml` içinde sadece 6 kural vardır (Keşif, Düzenleme, Test/Komut, REPL Komutları, Tool Sentezi, Çıktı Bütçesi).
   - Şu kritik araçlar için operasyonel rehberlik **sıfırdır**:
     - `invoke_subagent`, `manage_subagents`, `send_message`, `define_subagent`
     - `inspect_runtime`, `provide_service`, `repair_runtime_service` (çalışma zamanı öz-evrim ve self-healing)
     - `ask_question` (insan geri bildirimi alma standardı)

5. **Loop Döngüsü Seviyesinde Subagent Bildirim Körlüğü:**
   - `Shell` / `Lifecycle` içindeki `@subagent_notices` kuyruğu yalnızca REPL terminaline (`@output.puts`) dökülmekte, o sırada çalışan `Loop`'un `@history` dizisine aktarılmamaktadır.
   - Alt ajan bütçesini bitirdiğinde veya başarıyla tamamlandığında, ana ajan bu olayı adım başında doğrudan bir bildirim mesajı olarak alamamaktadır.

---

## 🏛️ 2. Mimari Tasarım ve Değişmezler (Invariants)

Bu plan, `init-0` kök süpervizörünün alt ajan ekosistemini **tam yetki, arketip farkındalığı, deterministik senkron bekleme ve yüksek sinyal-gürültü oranı (High SNR)** ile yönetmesini sağlar.

```
                           ┌────────────────────────────────────────────────────────┐
                           │          [init-0] ROOT SUPERVISOR AGENT                │
                           │   • Full Toolbelt (Read/Write/Exec/Subagents/Runtime)  │
                           │   • Injected <subagents> Catalog & Operational Rules   │
                           │   • Live In-Loop Subagent Notices Ingestion            │
                           └───────────────────────────┬────────────────────────────┘
                                                       │
                 ┌─────────────────────────────────────┴─────────────────────────────────────┐
                 ▼                                                                           ▼
   ┌───────────────────────────┐                                               ┌───────────────────────────┐
   │    <subagents> XML        │                                               │    <operational_rules>    │
   ├───────────────────────────┤                                               ├───────────────────────────┤
   │ • research (Read-Only)    │                                               │ Rule 7: Subagent Orchestr.│
   │ • coder (Write/Buf/Tests) │                                               │   - Match task to archetype│
   │ • self (Full Clone)       │                                               │   - Always call 'wait'    │
   │ • workspace: branch/inher.│                                               │ Rule 8: Runtime & Feedback│
   └───────────────────────────┘                                               └───────────────────────────┘
                                                       │
                                                       ▼ invoke_subagent(role, prompt, type_name: 'coder')
                               ┌───────────────────────────────────────────────┐
                               │ Output: "Launched [subagent-1].               │
                               │ MUST call manage_subagents(action: 'wait')!"  │
                               └───────────────────────┬───────────────────────┘
                                                       │
                                                       ▼ manage_subagents(action: 'wait', conversation_ids: ['subagent-1'])
                               ┌───────────────────────────────────────────────┐
                               │ Deterministic Wait (Up to timeout)            │
                               │ Result / Report Returned in Tool Output       │
                               └───────────────────────────────────────────────┘
```

---

## 🛠️ 3. Uygulama Fazları ve Adım Adım Yol Haritası

### Faz A: `ContextBuilder.build_subagents_xml` ve Tip Kataloğu Enjeksiyonu
**Hedef:** `init-0`'ın sistem bağlamında mevcut tüm alt ajan arketiplerini, yetki sınırlarını ve izolasyon kurallarını açıkça görebilmesi.

1. **`ContextBuilder.build_subagents_xml(type_registry)` Metodu (`lib/rubik/prompt/context_builder.rb`):**
   - Eğer `type_registry` mevcut ve boş değilse, kayıtlı tüm tipleri (`TypeDefinition`) progressive disclosure formatında XML'e döker:
   ```xml
   <subagents count="3">
     <subagent name="research" tools="read_only" workspace="inherit">
       Strictly read-only codebase exploration, file reading, symbol search, and architecture analysis. Cannot modify files or run tests.
     </subagent>
     <subagent name="coder" tools="read_write_test" workspace="branch">
       Focused implementation for drafting code edits, staging in buffer, applying changes, and running tests.
     </subagent>
     <subagent name="self" tools="full_clone" workspace="inherit">
       Inherits parent agent's full tools and configuration (except nested subagent spawning).
     </subagent>
     <orchestration_guidance>
       • Match task to archetype: Use 'research' for discovery/investigation; MUST use 'coder' for bug fixes, refactoring, and code implementation.
       • Execution is asynchronous: Immediately follow invoke_subagent with manage_subagents(action: 'wait', conversation_ids: ['...'], timeout: 30) to collect results. DO NOT poll 'status' in a loop.
       • Workspace isolation: 'inherit' shares workspace files; 'branch' provides an isolated virtual buffer that merges atomically on finish.
     </orchestration_guidance>
   </subagents>
   ```
2. **Kablolama (`ContextBuilder.build_system_context` & `build_system_prompt`):**
   - `type_registry:` parametresini kabul et.
   - `lib/rubik/orchestrator/loop.rb`: `@runtime_manager&.context` üzerinden veya `shell.subagent_supervisor&.type_registry` üzerinden `ContextBuilder`'a ilet.

---

### Faz B: `build_operational_rules_xml` Genişletmesi: Kural 7 ve Kural 8 (High SNR Toolbelt)
**Hedef:** Operasyonel kurallar içine alt ajan delegasyonunu, çalışma zamanı self-healing'i ve insan geri bildirimini ekleyerek modelin karar kalitesini maksimize etmek.

1. **Kural 7 (Subagent Delegation & Parallelism):**
   - "When a task requires independent exploration or multi-step code drafting, delegate via `invoke_subagent`. Specify `type_name: 'coder'` whenever code modifications are required (`research` cannot write or test). After launching subagents, synchronously await their results using `manage_subagents(action: 'wait', conversation_ids: [...], timeout: 30)`. Do not poll `status` repeatedly."
2. **Kural 8 (Runtime Introspection, Self-Healing & Human Feedback):**
   - "If internal errors or service degradation occur, inspect runtime state with `inspect_runtime` and repair failed services via `repair_runtime_service`. When critical requirements are underspecified or high-impact architectural decisions require confirmation, use `ask_question` with structured multiple-choice options."

---

### Faz C: `InvokeSubagentTool` ve `ManageSubagentsTool` Yönlendirmelerinin Senkronizasyonu
**Hedef:** Çelişkili yönlendirmeleri kaldırıp modeli deterministik senkron bekleme (`wait`) desenine kilitlemek.

1. **`InvokeSubagentTool#execute` Çıktısının Güncellenmesi (`lib/rubik/tools/builtins/subagent.rb`):**
   - Eski: `"Use manage_subagents(action: 'status', conversation_id: '...') to inspect progress/result..."`
   - Yeni: `"Subagents run asynchronously. To wait for completion and retrieve their findings, call manage_subagents(action: 'wait', conversation_ids: #{launched_ids.inspect}, timeout: 30)."`
2. **`subagent.rb` Modül Hijyeni ve Satır Tavanı:**
   - Dosya tavanı `< 350` satır olarak korunacak (şu anda 348 satır; gereksiz yorum ve alias'lar optimize edilecek).

---

### Faz D: `Loop` İçi Canlı Subagent Bildirimleri Drenajı
**Hedef:** Ana ajan `Loop` içindeyken arkadaki bir subagent tamamlandığında veya bütçesi tükendiğinde bilginin anında model geçmişine enjekte edilmesi.

1. **`Loop#enqueue_subagent_notice(msg)` ve `drain_subagent_notices_into_history!`:**
   - `Loop` sınıfına thread-safe bir notice kuyruğu ekle: `@subagent_notice_queue = Queue.new`.
   - `execute_steps` döngüsünde her adımın başında kuyruktaki bildirimleri boşalt:
   ```ruby
   drain_subagent_notices_into_history!
   ```
   - Kuyruktan çekilen bildirimler `@history << { role: "user", content: "<subagent_notification>#{msg}</subagent_notification>" }` şeklinde geçmişe eklenir.
2. **`Shell` / `Lifecycle` Kablolaması (`lib/rubik/repl/lifecycle.rb`):**
   - `emit_subagent_notice` metodu, `@active_loop` varsa `notice`'ı hem `@subagent_notices`'a hem de `@active_loop.enqueue_subagent_notice(msg)` metoduna iletir.

---

### Faz E: Doğrulama, Modül Hijyeni ve Dokümantasyon
**Hedef:** Sistemin sıfır hata, sıfır lint ihlali ve güncel dokümantasyonla güvence altına alınması.

1. **Birim Testleri (`test/unit/test_subagent_prompt_and_snr.rb`):**
   - `test_context_builder_includes_subagents_xml_with_archetypes`
   - `test_context_builder_operational_rules_includes_subagent_and_runtime_rules`
   - `test_invoke_subagent_tool_output_recommends_wait_action`
   - `test_loop_drains_subagent_notices_into_history`
2. **Modül Hijyen Testi (`test/unit/test_module_hygiene.rb`):**
   - `subagent.rb < 350`, `loop.rb < 500`, `context_builder.rb < 450`.
3. **Dokümantasyon Güncellemeleri:**
   - `ARCHITECTURE.md` (Domain 11: Orchestrator & Subagents alt bölümü).
   - `TOOLS.md` (`invoke_subagent` ve `manage_subagents` açıklamaları).
   - `_plan/00-index.md` ve `_plan/index.md` (Plan 96 satırı ve DAG eklemesi).

---

## 📋 4. Başarı Kriterleri ve Değişmezler Kontrol Listesi

- [x] `ContextBuilder.build_system_context`, `type_registry` verildiğinde `<subagents>` bloğunu tam arketip yetkileriyle üretir.
- [x] `<operational_rules>` içinde Kural 7 (`Subagent Delegation`) ve Kural 8 (`Runtime & Feedback`) yer alır.
- [x] `invoke_subagent` çıktısı modele `action: 'status'` yerine deterministik olarak `action: 'wait'` çağrısı önerir.
- [x] Arka planda çalışan alt ajanın tamamlanma veya bütçe bildirimleri ana ajanın `Loop#execute_steps` döngüsüne canlı enjekte edilir.
- [x] `test/unit/test_module_hygiene.rb` içindeki tüm satır tavanları korunur (`subagent.rb < 350`, `loop.rb < 500`).
- [x] `bundle exec rubocop` 0 ihlal verir.
- [x] `bundle exec rake test` 0 hata ve 0 başarısızlıkla sonuçlanır.

---

## 📊 5. Uygulama ve Doğrulama Raporu

- **Uygulanan Dosyalar:**
  - `lib/rubik/prompt/context_builder.rb`: `build_subagents_xml`, Kural 7 ve Kural 8 operasyonel kuralları, `build_system_context` ve `build_system_prompt` parametre zinciri.
  - `lib/rubik/tools/builtins/subagent.rb`: `InvokeSubagentTool` şema arketip açıklamaları ve `manage_subagents(action: 'wait')` yönlendirmesi.
  - `lib/rubik/orchestrator/loop.rb`: `@subagent_notices` kuyruğu, `enqueue_subagent_notice`, `drain_subagent_notices_into_history!` ve `resolve_type_registry`.
  - `lib/rubik/repl/lifecycle.rb`: `emit_subagent_notice` içinde aktif `@active_loop`'a bildirim yönlendirmesi.
  - `test/unit/test_subagent_prompt_and_snr.rb`: 6 yeni birim testi (tümü yeşil).
  - `TOOLS.md` ve `ARCHITECTURE.md`: Subagent arketip yetkileri, bekleme yönergeleri ve in-loop bildirim drenajı dokümantasyonu.
- **Test Sonuçları:**
  - `test_subagent_prompt_and_snr.rb`: 6 runs, 53 assertions, 0 failures, 0 errors.
  - `test_subagent_editing_and_test_isolation.rb`: 7 runs, 24 assertions, 0 failures, 0 errors.
  - `test_module_hygiene.rb`: 10 runs, 69 assertions, 0 failures, 0 errors (`subagent.rb` 348 satır, `loop.rb` 470 satır).
  - `bundle exec rubocop`: 0 offenses across all modified files.
