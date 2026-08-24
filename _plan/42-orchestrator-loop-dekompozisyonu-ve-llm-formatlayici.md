# 📋 Plan 42: Orchestrator Loop Dekompozisyonu ve Ortak LLM Mesaj Formatlayıcı

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟡 **Planlandı** · **Zorluk:** Orta · **Faz:** 5 (Mimari İyileştirme & Performans)  
> **İlgili Planlar:** [10](10-ajan-dongusu-ve-arac-entegrasyonu.md), [17](17-yerel-arac-cagrilari-ve-router.md), [30](30-dinamik-llm-saglayicilari-ozel-endpointler-ve-baglam-limiti.md), [31](31-agentic-adim-butcesi-ve-dinamik-genisletme.md), [35](35-akilli-baglam-sikistirici-ve-dinamik-token-yonetimi.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

### Mevcut Durum (Aşırı Derinlik ve Tekrar)
1. **`Loop#execute_steps` Karmaşıklığı:**
   - [`lib/rubik/orchestrator/loop.rb`](../lib/rubik/orchestrator/loop.rb) içindeki `execute_steps` metodu 256 satır uzunluğunda ve nesting derinliği 36'ya ulaşmaktadır.
   - LLM istekleri, token kullanımı, tool call parsing, tekil/paralel tool çalıştırma, bağlam sıkıştırma (`emergency_compact`), bütçe uyarıları ve hata yönetimi aynı döngü gövdesinde iç içe girmiştir.
2. **LLM Mesaj Formatlama Tekrarı:**
   - `Rubik::LLM::OpenAICompatible`, `Rubik::LLM::Anthropic` ve `Rubik::LLM::Ollama` sınıfları içinde mesaj dönüştürme mantığı (`format_messages`) neredeyse aynı yapısal dallanmaları içermekte ve kod tekrarı oluşturmaktadır.

### Hedef
1. `execute_steps` metodunu net, test edilebilir ve izole yardımcı metotlara bölmek:
   - `handle_step_response(res)`
   - `execute_tool_calls(tool_calls)`
   - `check_context_compaction!`
   - `check_step_budget_warning!`
2. `Rubik::LLM::BaseFormatter` ortak temel sınıfı oluşturarak OpenAI, Anthropic ve Ollama sağlayıcılarındaki mesaj dönüştürme kodlarını konsolide etmek.
3. Test süitinin %100 yeşil kalmasını sağlamak.

---

## 🏛️ 2. Mimari Tasarım

```
                          ┌──────────────────────────────────────────────┐
                          │         Rubik::Orchestrator::Loop            │
                          │   • run(prompt)                              │
                          │   • execute_steps(max)                       │
                          └──────────────────────┬───────────────────────┘
                                                 │
                        ┌────────────────────────┼────────────────────────┐
                        ▼                        ▼                        ▼
         ┌─────────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐
         │   Step Execution & I/O  │  │  Context Compaction │  │   Budget Guards     │
         ├─────────────────────────┤  ├─────────────────────┤  ├─────────────────────┤
         │ • execute_tool_calls    │  │ • evaluate_overflow │  │ • check_budget_warn │
         │ • process_llm_response  │  │ • emergency_compact │  │ • max_steps_guard   │
         └─────────────────────────┘  └─────────────────────┘  └─────────────────────┘
```

---

## ⚙️ 3. Uygulama Adımları

1. **Adım 1:** `Rubik::LLM::BaseFormatter` ve sağlayıcı formatlayıcı refaktörü.
2. **Adım 2:** `Rubik::Orchestrator::Loop` içindeki `execute_steps` metodunun parçalanması.
3. **Adım 3:** Tüm orkestratör ve LLM testlerinin (`test/unit/test_loop_*.rb`, `test_llm_*.rb`) doğrulanması.
