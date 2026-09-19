# Plan 94 — Alt-Ajan Hiyerarşisi ve İzole Bağlam Orkestrasyonu (`invoke_subagent`)

> **Durum:** 🔵 **Planlandı**  
> **Zorluk:** Zor  
> **Faz:** 9 (Ajan Zekası & Çoklu Ajan Mimarisi)  
> **Öneri Bölümü:** Çoklu Ajan Orkestrasyonu, İzolasyon & Alt-Bağlamlar  
> **İlgili Planlar:** [03](03-dosya-tamponu-snapshot-undo.md), [10](10-tool-calling-orkestrasyon.md), [16](16-genisletilmis-arac-seti-ve-planlama.md), [20](20-spatiotemporal-composability-eklenti-dongusu.md), [33](33-spatiotemporal-coeffect-inverses-ve-runtime-gorsellestirme.md), [42](42-orchestrator-loop-dekompozisyonu-ve-llm-formatlayici.md), [47](47-orchestrator-loopun-reaktif-sistem-fiberina-donusturulmesi.md), [88](88-tampon-cakisma-deadlock-cozumu-ve-apply-buffer-guclendirmesi.md), [AGENTS.md](../AGENTS.md)

---

## 🎯 1. Motivasyon ve Sorun Tanımı

Gelişmiş yazılım geliştirme süreçlerinde (büyük refaktörler, derin mimari keşifler, güvenlik/test denetimleri) **tek bir ajan döngüsü** iki büyük handikap yaratır:

### 🔍 Temel Sorunlar:
1. **Bağlam Şişmesi ve Zehirlenmesi (Context Bloat & Pollution):**
   - Ana ajan bir kütüphaneyi veya hata kök nedenini araştırırken 20 farklı dosya okuduğunda, yüzlerce satır terminal çıktısı aldığında ana konuşma geçmişi dolup taşar. Model asıl ana hedefini (`goal`) unutmaya veya bağlam sıkıştırmaya (`compaction`) zorlanır.
2. **Hata İzolasyonu Eksikliği (Blast Radius & Buffer Contamination):**
   - Keşif veya deneme aşamasında yapılan geçici dosya değişiklikleri ana tamponu (`BufferManager`) kirletir. Deneme başarısız olduğunda temiz bir şekilde geri alınması güçleşir.
3. **Rol ve Yetki Ayrımı Eksikliği (Least Privilege Principle):**
   - Sadece kod okuyup rapor hazırlayacak bir araştırma aşamasına tam dosya yazma ve komut çalıştırma yetkisi vermek hem güvenlik hem de halüsinasyon riski doğurur.
4. **Özyinelemeli Ajan Patlaması (Recursive Agent Bomb):**
   - Kontrolsüz bir alt-ajan mimarisinde, bir alt ajanın başka bir alt ajanı çağırması sonsuz dallanmaya ve API maliyet patlamasına yol açabilir.

---

## 🏛️ 2. `AGENTS.md` Spatiotemporal Uyumu ve Değişmezler

> *"Isolate experimental or self-generated code within a disposable sub-context (`ctx.extend()`). If the synthesized code fails verification, dispose the sub-context to instantly clean up all side effects."* — [`AGENTS.md`](../AGENTS.md) §3 Directive 4

```
                       ┌─────────────────────────────────────────┐
                       │        PARENT ORCHESTRATOR LOOP         │
                       │           (Parent Context σ₀)           │
                       └────────────────────┬────────────────────┘
                                            │ invoke_subagent(role, prompt)
                                            ▼
                       ┌─────────────────────────────────────────┐
                       │         DISPOSABLE SUB-CONTEXT          │
                       │             child = ctx.extend()        │
                       ├─────────────────────────────────────────┤
                       │ • Scoped Tool Registry (Role-Filtered)  │
                       │ • Forked Virtual Buffer (Atomic Branch) │
                       │ • Isolated Step Budget (Max 10 steps)   │
                       │ • Recursion Depth Guard (Depth <= 1)    │
                       │ • LIFO Inverses Accumulator (Ω_child)   │
                       └────────────────────┬────────────────────┘
                                            │
                      ┌─────────────────────┴─────────────────────┐
                      ▼ Success                                   ▼ Failure / Cancel
       ┌─────────────────────────────┐             ┌─────────────────────────────┐
       │ Merge Forked Buffer Edits   │             │ Discard Forked Buffer Edits │
       │ Synthesize Markdown Report  │             │ child.dispose (Full Rollback│
       │ child.dispose (Prune Ω)     │             │ to σ₀ state)                │
       │ Deliver Report to Parent    │             │ Report Failure Diagnostic   │
       └─────────────────────────────┘             └─────────────────────────────┘
```

1. **Disposable Sub-Contexts (`ctx.extend()`):** Her alt ajan, ebeveyn bağlamdan türetilen bağımsız bir alt bağlamda çalışır. Alt ajanın ürettiği tüm yan etkiler çocuk bağlamın $\Omega$ akümülatöründe izole edilir.
2. **Çatallanmış Sanal Tampon (Forked Buffer Isolation):**
   - Alt ajan `BufferManager`'ı doğrudan kirletmez; ebeveyn tamponunun yalıtılmış bir kopyası (`parent_buffer.fork`) üzerinde çalışır.
   - Yalnızca alt ajan başarıyla (`:success`) tamamlandığında değişiklikler ebeveyn tampona birleştirilir (`merge!`). Hata veya iptal anında çocuk tampon çöpe atılır ($A(\sigma) \sim \sigma_0$).
3. **Bağlam Temizliği (Clean Pruning):** Alt ajan işini tamamladığında veya iptal edildiğinde `child.dispose` çalışır; ebeveynin bağlamı kirlenmeden sadece **yapılandırılmış sentez raporu (synthesis report)** ebeveyn konuşma geçmişine enjekte edilir.
4. **Özyineleme Koruması (Recursion Depth Guard):** Alt ajanların derinliği kesin olarak `max_depth = 1` ile sınırlandırılır. Alt ajanlar `invoke_subagent` aracına erişemez.
5. **Token ve Bütçe Şeffaflığı:** Alt ajanın harcadığı token miktarı ebeveynin `BudgetManager` ve `Session::Recorder` istatistiklerine yansıtılır.

---

## 🏗️ 3. Mimari Tasarım ve Fazlar

### 📦 Faz A: `SubagentPool` ve Alt-Ajan Yaşam Döngüsü
**Dosya:** `lib/rubik/orchestrator/subagent/pool.rb` (`Rubik::Orchestrator::Subagent::Pool`)

- **Rol Şablonları (Role Catalogs):**
  - `:researcher`: Salt-okunur (`read_file`, `list_files`, `grep_search`, `search_symbols`, `get_outline`, `find_references`, `lsp_hover`, `lsp_definition`).
  - `:reviewer`: Salt-okunur + diff (`read_file`, `lsp_diagnostics`).
  - `:coder`: Kodlama odaklı (`read_file`, `write_file`, `replace_file_content`, `run_tests`).
  - `:self`: Ebeveynin tüm araçlarını miras alan tam yetkili alt ajan (özyineleme hariç).
- **Yönetim Metotları:**
  - `spawn(role:, prompt:, parent_loop:, max_steps: 10)`: Alt bağlam (`ctx.extend`), çatallanmış tampon ve rol-filtreli araç kütüğü oluşturur.
  - `execute_subagent(instance)`: Alt ajan döngüsünü bütçe dahilinde çalıştırır.
  - `terminate(id)`: Alt ajanın bağlamını dispose edip kaynakları serbest bırakır.

### 🛠️ Faz B: `InvokeSubagentTool` ve `ManageSubagentsTool`
**Dosya:** `lib/rubik/tools/builtins/subagent.rb` (`Rubik::Tools::InvokeSubagentTool`)

- **JSON Şeması:**
```json
{
  "name": "invoke_subagent",
  "description": "Spawns an isolated subagent in a disposable sub-context to perform focused research, code review, or refactoring without polluting the main context.",
  "parameters": {
    "type": "object",
    "properties": {
      "role": { "type": "string", "enum": ["researcher", "reviewer", "coder", "self"], "description": "Specialized role and tool privilege level." },
      "prompt": { "type": "string", "description": "Clear, single-responsibility instructions for the subagent." },
      "max_steps": { "type": "integer", "description": "Maximum step budget for the subagent (default: 10, max: 20)." }
    },
    "required": ["role", "prompt"]
  }
}
```

- **Dönüş Formatı (Synthesis Report):**
```text
=== Subagent Report (role: researcher | id: subagent-1) ===
Status: SUCCESS | Steps used: 4/10
Report:
- Analyzed auth pipeline in `lib/rubik/security/guard.rb`.
- Identified that AST classification runs before allowlist lookup.
- Verified test suite status.
Artifacts:
- None (read-only research)
```

### 🖥️ Faz C: REPL `!subagents` Komutu
**Dosya:** `lib/rubik/repl/commands/subagents.rb`

- `!subagents list`: Aktif/tamamlanmış alt ajanları, rollerini, tüketilen adımları ve durumlarını listeler.
- `!subagents kill <id>`: Takılı kalan veya gereksiz alt ajanı temizler.

---

## 🧪 4. Test Senaryoları ve Kabul Kriterleri

1. **Araştırmacı Rolü Araç İzolasyonu:** `researcher` rolündeki alt ajana `write_file` çağrısı yaptırıldığında aracın registry'de bulunmadığı ve hata verdiği doğrulanır.
2. **Ebeveyn Bağlamının Korunması:** Alt ajan 8 adımda 12 dosya okusa dahi ebeveyn ajanın konuşma geçmişine yalnızca tek bir `tool_result` sentez raporunun eklendiği doğrulanır.
3. **Tampon Çatallanması ve Atomik İzolasyon:** Başarısız olan bir alt ajanın yaptığı dosya değişikliklerinin ana `BufferManager`'a sızmadığı doğrulanır.
4. **Özyineleme Engeli (Depth Guard):** Alt ajanın kendi içinde `invoke_subagent` çağıramadığı teyit edilir.
5. **Adım Tavanı (Step Budget):** Alt ajanın belirlenen bütçeyi (örn. 10 adım) aşamadığı test edilir.
6. **LIFO Dispose:** Alt ajan sonlandığında alt bağlamın `child.disposed?` olduğu ve ebeveyn bağlamdan budandığı (`prune_child`) teyit edilir.

---

## 📝 5. Dosya Tavanları ve Hijyen

- `lib/rubik/orchestrator/subagent/pool.rb`: < 250 satır
- `lib/rubik/tools/builtins/subagent.rb`: < 200 satır
- `lib/rubik/repl/commands/subagents.rb`: < 120 satır
- `test/unit/test_subagent_orchestration.rb`: Kapsamlı birim testler
