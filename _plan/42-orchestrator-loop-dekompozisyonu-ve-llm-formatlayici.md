# 📋 Plan 42: Orchestrator Loop Dekompozisyonu ve Ortak LLM Mesaj Formatlayıcı

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** Orta · **Faz:** 5 (Mimari İyileştirme & Performans)  
> **İlgili Planlar:** [10](10-ajan-dongusu-ve-arac-entegrasyonu.md), [17](17-yerel-arac-cagrilari-ve-router.md), [30](30-dinamik-llm-saglayicilari-ozel-endpointler-ve-baglam-limiti.md), [31](31-agentic-adim-butcesi-ve-dinamik-genisletme.md), [35](35-akilli-baglam-sikistirici-ve-dinamik-token-yonetimi.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

### Mevcut Durum (Aşırı Derinlik ve Tekrar)
1. **`Loop#execute_steps` Karmaşıklığı:**
   - [`lib/rubik/orchestrator/loop.rb`](../lib/rubik/orchestrator/loop.rb) içindeki `execute_steps` metodu 256 satır uzunluğunda ve nesting derinliği 36'ya ulaşmaktaydı.
   - LLM istekleri, token kullanımı, tool call parsing, tekil/paralel tool çalıştırma, bağlam sıkıştırma (`emergency_compact`), bütçe uyarıları ve hata yönetimi aynı döngü gövdesinde iç içe girmişti.
2. **LLM Mesaj Formatlama Tekrarı:**
   - `Rubik::LLM::OpenAICompatible`, `Rubik::LLM::Anthropic` ve `Rubik::LLM::Ollama` sınıfları içinde mesaj dönüştürme mantığı (`format_messages`) neredeyse aynı yapısal dallanmaları içermekte ve kod tekrarı oluşturmaktaydı.

### Hedef
1. `execute_steps` metodunu net, test edilebilir ve izole yardımcı metotlara bölmek:
   - `evaluate_step_budget_warning!`
   - `evaluate_context_compaction!`
   - `send_llm_request_with_recovery`
   - `track_token_usage!`
   - `extract_and_normalize_tool_calls`
   - `process_step_response`
   - `execute_tool_calls`
   - `execute_single_tool_call`
   - `handle_finish_tool`
   - `execute_registered_tool`
   - `handle_invalid_tool`
2. `Rubik::LLM::BaseFormatter` ortak temel sınıfı oluşturarak OpenAI, Anthropic ve Ollama sağlayıcılarındaki mesaj dönüştürme kodlarını konsolide etmek:
   - `Rubik::LLM::OpenAIFormatter`
   - `Rubik::LLM::AnthropicFormatter`
   - `Rubik::LLM::OllamaFormatter`
3. Test süitinin %100 yeşil kalmasını sağlamak.

---

## 🏛️ 2. Mimari Tasarım

```
                          ┌──────────────────────────────────────────────┐
                          │         Rubik::Orchestrator::Loop            │
                          │   • run(prompt)                              │
                          │   • execute_steps (22 satır sade döngü)      │
                          └──────────────────────┬───────────────────────┘
                                                 │
                         ┌───────────────────────┼────────────────────────┐
                         ▼                       ▼                        ▼
          ┌─────────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐
          │   Step Execution & I/O  │  │  Context Compaction │  │   Budget Guards     │
          ├─────────────────────────┤  ├─────────────────────┤  ├─────────────────────┤
          │ • execute_tool_calls    │  │ • evaluate_context_ │  │ • evaluate_step_    │
          │ • execute_single_tool   │  │   compaction!       │  │   budget_warning!   │
          │ • execute_registered_   │  │ • emergency_compact │  │ • max_steps_guard   │
          │   tool / handle_finish  │  │   recovery          │  │                     │
          └─────────────────────────┘  └─────────────────────┘  └─────────────────────┘

                          ┌──────────────────────────────────────────────┐
                          │          Rubik::LLM::BaseFormatter           │
                          │   • format_messages                          │
                          │   • format_tools                             │
                          └──────────────────────┬───────────────────────┘
                                                 │
                         ┌───────────────────────┼────────────────────────┐
                         ▼                       ▼                        ▼
               ┌───────────────────┐   ┌───────────────────┐    ┌───────────────────┐
               │  OpenAIFormatter  │   │ AnthropicFormatter│    │  OllamaFormatter  │
               └───────────────────┘   └───────────────────┘    └───────────────────┘
```

---

## ⚙️ 3. Uygulanan Değişiklikler

1. **`lib/rubik/llm/formatter.rb` Oluşturuldu:**
   - `BaseFormatter`: Ortak mesaj/araç şema dönüştürücü arayüzü ve korumalı yardımcılar (`extract_role`, `extract_content`, `extract_tool_calls`, `extract_call_id`).
   - `OpenAIFormatter`: OpenAI/OpenRouter uyumlu function schema ve role ayrıştırma (orta konuşma system mesajlarını user bildirimine dönüştürme dahil).
   - `AnthropicFormatter`: `tool_use` ve `tool_result` blok dönüşümleri ve `input_schema` formatlama.
   - `OllamaFormatter`: Ollama `/api/chat` native tool formatlama.
2. **`lib/rubik/llm.rb` Güncellendi:**
   - `require_relative "llm/formatter"` eklendi.
3. **Sağlayıcı Sınıfları Sadeleştirildi:**
   - `Rubik::LLM::OpenAICompatibleProvider`, `AnthropicProvider`, `OllamaProvider` sınıflarındaki kod fazlalıkları ilgili formatlayıcı sınıflara delege edildi.
4. **`Rubik::Orchestrator::Loop` Dekompoze Edildi:**
   - `execute_steps` metodu ~20 satırlık temiz bir ana döngüye indirgendi.
   - 11 adet izole ve tek sorumluluklu yardımcı metoda bölündü.
5. **Kapsamlı Test Kapsamı Eklendi:**
   - `test/unit/test_llm_formatter.rb` ile tüm formatlayıcılar doğrulandı.
   - `test/unit/test_loop_decomposition.rb` ile parçalanan Loop yardımcı metotları doğrulandı.

---

## 📊 4. Sonuç ve Metrikler

- **Loop Karmaşıklığı:** 256 satırlık iç içe döngü 22 satıra indirgendi, nesting derinliği 36'dan 2'ye düşürüldü.
- **LLM Mesaj Formatlama:** 3 farklı sağlayıcıdaki tekrarlı mantık bağımsız ve test edilebilir Formatter sınıflarında toplandı.
- **Geriye Dönük Uyumluluk:** Mevcut API sözleşmeleri ve test çağrıları (`provider.send(:format_messages, ...)`) %100 korundu.
