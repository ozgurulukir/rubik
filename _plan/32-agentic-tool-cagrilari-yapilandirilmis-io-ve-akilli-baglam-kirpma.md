# 32 — Agentic Tool Çağrıları, Yapılandırılmış Girdi/Çıktı (I/O) Formatı, Akıllı Bağlam Kırpma ve Spatiotemporal Entegrasyon

**Durum:** ✅ **Tamamlandı** · **Zorluk:** Orta–Zor · **Öneri kaynağı:** Kullanıcı Talebi & `AGENTS.md` Protokolü · **Faz:** 5 (Otonom Ajan & REPL Mimarisi)  
**İlgili Planlar:** [10 — Tool-Calling & Orkestrasyon](10-tool-calling-orkestrasyon.md) · [17 — Native Tool Calling](17-native-tool-calling-ve-model-yonlendirme.md) · [20 — Spatiotemporal Composability](20-spatiotemporal-composability-eklenti-dongusu.md) · [23 — XML Yapılandırılmış Bağlam](23-xml-yapilandirilmis-baglam-ve-agents-protokol-entegrasyonu.md) · [30 — Dinamik LLM Sağlayıcıları](30-dinamik-llm-saglayicilari-ozel-endpointler-ve-baglam-limiti.md) · [31 — Adım Bütçesi](31-agentic-adim-butcesi-ve-dinamik-genisletme.md) · [CONFIG.md](../CONFIG.md) · [AGENTS.md](../AGENTS.md)

---

## 🎯 1. Mevcut Durum Analizi & Problem

Mevcut durumda:
- Model tool çağırdığında (`run_command`, `read_file`, `write_file` vb.), çıktılar tarihçeye doğrudan düz metin olarak (`role: "user", content: "Tool #{tool_name} output:\n#{tool_output}"`) eklenmekteydi.
- Büyük çıktılar (örneğin yüzlerce satırlık derleme logları, test çıktıları, büyük dosyalar) tüm tarihçeyi şişirmekte (context bloat) ve agentic coding döngülerinde token bütçesini tüketmekteydi.
- Katı native tool protokolü kullanan sağlayıcılarda (OpenAI `role: "tool"` + `tool_call_id`, Anthropic `tool_use` + `tool_result`), düz kullanıcı mesajı göndermek multi-turn tool konuşma geçmişini bozabilmekte veya API hatalarına yol açabilmekteydi.
- Tool çalıştırma esnasında oluşabilecek istisnalar (exception) orkestrasyon döngüsünü çökertebilmekteydi (`AGENTS.md` §5 ihlali).
- Tool çıktıları yürütüm süresi (`duration_ms`), durum (`ok` / `error`), çıkış kodu gibi semantik metadata içermemekteydi.

---

## 💡 2. Hedeflenen Çözüm & Mimari Tasarım

```text
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│                   SPATIOTEMPORAL AGENTIC TOOL I/O & CONTEXT PRESERVATION                         │
├──────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                  │
│  1. Yapılandırılmış Tool Sonuçları (Rubik::Tools::Result):                                       │
│     • Her tool yürütümü durum (ok/error), çıkış kodu, süre (ms) ve çıktı içerir.                 │
│     • Semantik XML: <tool_result tool="run_command" id="call_1" status="ok" duration_ms="45">   │
│                       [Output]                                                                   │
│                     </tool_result>                                                               │
│                                                                                                  │
│  2. Akıllı Bağlam Kırpma (Rubik::Tools::Truncator):                                              │
│     • max_output_chars: 12000, max_output_lines: 300                                             │
│     • head_tail stratejisi: Baştan 100 satır + Sondan 100 satır + Truncation özeti               │
│     • Token bütçesini ve modelin çıkarım kalitesini korur.                                      │
│                                                                                                  │
│  3. Evrensel Sağlayıcı Mesaj Adaptörü (Universal History Normalizer):                           │
│     • OpenAI / Compatible: role="assistant" (tool_calls) -> role="tool" (tool_call_id)          │
│     • Anthropic: role="assistant" (tool_use) -> role="user" (tool_result)                        │
│     • Ollama / Local: Doğrudan XML yapılandırılmış metin akışı                                   │
│                                                                                                  │
│  4. AGENTS.md Protokol Uyumu & Hata İzolasyonu:                                                  │
│     • Tool exception'ları döngüyü çökertmez; atomic rollback ve onarım geri bildirimi sağlar.    │
│     • Sentetik tool ve eklenti yüklemelerinde inverse registration korunur.                      │
│                                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## ⚙️ 3. Yeni Yapılandırma Şeması (`config.yml`)

```yaml
# ------------------------------------------------------------------------------
# 🛠️ Tool Girdi / Çıktı ve Bağlam Koruma Ayarları
# ------------------------------------------------------------------------------
tools:
  max_output_chars: 12000
  max_output_lines: 300
  truncation_strategy: head_tail
  timeout_seconds: 30
```

---

## 🛠️ 4. Uygulama Adımları

### A. Yapılandırma ve Veri Modelleri
- [x] `lib/rubik/config.rb` içine `"tools"` bloğunun eklenmesi.
- [x] `lib/rubik/tools/result.rb` oluşturulması (`Result` veri modeli, `to_xml`, `to_h`, `ok?`).
- [x] `lib/rubik/tools/truncator.rb` oluşturulması (Head/Tail ve satır/karakter akıllı kırpma).

### B. Orkestrasyon Döngüsü Refactoring
- [x] `lib/rubik/orchestrator/loop.rb`:
  - Tool çalıştırmayı `begin...rescue` ile koruma altına alma.
  - Çalışma süresini (`duration_ms`) ölçme.
  - `Truncator` ile çıktıyı normalize etme.
  - Tarihçeye hem native `tool_call_id` hem de zenginleştirilmiş XML `<tool_result>` formatında kaydetme.

### C. Sağlayıcı Adaptörlerinin Native Tool Tarihçe Desteği
- [x] `lib/rubik/llm/openai_compatible.rb`: Tarihçedeki tool çağrı ve sonuçlarını OpenAI `tool` mesaj formatına dönüştürme.
- [x] `lib/rubik/llm/anthropic.rb`: Tarihçeyi Anthropic `tool_use` ve `tool_result` content bloklarına dönüştürme.
- [x] `lib/rubik/llm/ollama.rb`: Tool mesajlarını graceful formatlama.

### D. Testler ve Doğrulama
- [x] `test/unit/test_tool_calling_io.rb` test paketinin yazılması.
- [x] Tüm testlerin (%100 yeşil) doğrulanması.
- [x] `CONFIG.md`, `README.md` ve plan indeksinin güncellenmesi.
