# 📋 Plan 47: Orchestrator Loop'un Reaktif Sistem Fiber'ına Dönüştürülmesi ve Dinamik Coeffect Reconciler Entegrasyonu

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟡 **Planlandı (Kullanıcı Onayı Bekleniyor)** · **Zorluk:** Orta · **Faz:** 5 (Reaktif Ajan Fiber Mimarisi)  
> **İlgili Planlar:** [10](10-ajan-dongusu-ve-arac-entegrasyonu.md), [17](17-yerel-arac-cagrilari-ve-router.md), [20](20-spatiotemporal-runtime-context-ve-fiber-yasam-dongusu.md), [30](30-dinamik-llm-saglayicilari-ozel-endpointler-ve-baglam-limiti.md), [33](33-spatiotemporal-koefektler-ve-ters-islemler.md), [42](42-orchestrator-loop-dekompozisyonu-ve-llm-formatlayici.md), [45](45-spatiotemporal-oz-evrilen-calisma-zamani-ve-otonom-adaptor-sentezi.md), [46](46-ast-ve-baglam-motorunun-reaktif-coeffect-servisine-donusturulmesi.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

### Mevcut Durum:
1. `Rubik::Orchestrator::Loop`, `Shell` tarafından doğrudan `Loop.new(llm_client, tool_registry, ...)` şeklinde bağımsız bir nesne olarak başlatılmaktadır.
2. `AGENTS.md` Bölüm 2 (Fiber Lifecycle State Machine) standardında:
   - Ajan döngüsünün kendisi, deklaratif olarak bağımlılıklarını bildiren bir **Ana Sistem Fiber'ı** (`AgentLoopFiber`) olmalıdır:
     $$\text{AgentLoopFiber} : \text{inject} = [\text{llm\_client}, \text{tool\_registry}, \text{buffer\_manager}]$$
   - Bir LLM sağlayıcısı değiştiğinde (`!provider`, `!model`), araç seti güncellendiğinde (`swap`, `synthesize_tool`) veya tampon değiştiğinde; döngü Fiber'ı `Active \leftrightarrow Pending` geçişlerini Spatiotemporal Reconciler ile sıfır kesintiyle (zero-downtime) gerçekleştirmelidir.

---

## 🏛️ 2. Mimari Tasarım ve Fiber Durum Geçişleri

```
                  ┌─────────────────────────────────────────────────────────┐
                  │                 Runtime Manager Reconciler              │
                  └────────────────────────────┬────────────────────────────┘
                                               │
                                 ┌─────────────┴─────────────┐
                                 ▼                           ▼
                 ┌─────────────────────────────┐   ┌─────────────────────────────┐
                 │    Coeffects Satisfied      │   │     Coeffect Missing        │
                 │ (LLM + Tools + Buffer Ready)│   │  (e.g., LLM Key Missing)    │
                 └──────────────┬──────────────┘   └──────────────┬──────────────┘
                                │                                 │
                                ▼                                 ▼
                 ┌─────────────────────────────┐   ┌─────────────────────────────┐
                 │   🟢 AgentLoopFiber: ACTIVE │   │   ⏳ AgentLoopFiber: PENDING │
                 │ • Executes autonomous steps │   │ • Graceful hold/await state │
                 │ • Inverses in accumulator   │   │ • State preserved safely    │
                 └─────────────────────────────┘   └─────────────────────────────┘
```

---

## ⚙️ 3. Planlanan İyileştirmeler

### 3.1. `Rubik::Runtime::AgentLoopFiber` Tanımı
- `Runtime::Manager#register_component("orchestrator_loop", inject: %i[llm_client tool_registry buffer_manager])` olarak tescil edilir.
- **Aktifleşme (`Activating`):**
  - Gerekli tüm coeffect'ler sağlandığında Loop örneği canlıya alınır ve `Shell#orchestrator_loop` referansına bağlanır.
- **Pasifleşme (`Deactivating`):**
  - Sağlayıcı veya araç koptuğunda, birikmiş ters işlemler LIFO sırasıyla işletilip güvenli bekleme durumuna geçilir.

### 3.2. REPL & Çoklu Sağlayıcı Hot-Swap Entegrasyonu
- `!provider <name>` veya `!model <name>` komutları çalıştığında:
  1. Eski LLM istemcisi LIFO ile devreden çıkarılır.
  2. Yeni `LLM::Client` `ctx.provide(:llm_client, new_client)` ile bağlama sağlanır.
  3. Reconciler otomatik olarak `AgentLoopFiber`'ı yeniden aktive eder (Zero-downtime provider swapping).

---

## 🧪 4. Test ve Kalite Güvencesi

1. **`test/unit/test_orchestrator_fiber_lifecycle.rb`**:
   - `llm_client` olmadan `AgentLoopFiber`'ın `Pending` kalması.
   - `ctx.provide(:llm_client, ...)` ile anında `Active` duruma geçmesi.
   - LLM sağlayıcı değişiminde Fiber'ın sıfır kesintiyle güncellenmesi.
2. **Mevcut Test Süiti:** Tüm 305+ testin kesintisiz %100 yeşil kalması.
