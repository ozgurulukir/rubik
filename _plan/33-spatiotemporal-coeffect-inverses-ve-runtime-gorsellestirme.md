# 33 — Spatiotemporal Coeffect Entegrasyonu, Çift Yönlü Ters İşlemler (Inverses) ve REPL !runtime Görselleştirmesi

**Durum:** ✅ **Tamamlandı** · **Zorluk:** Kolay–Orta · **Öneri kaynağı:** `AGENTS.md` Kod Tabanı Denetimi & Çoklu Ajan İşbirliği · **Faz:** 5 (Otonom Ajan & REPL Mimarisi)  
**İlgili Planlar:** [20 — Spatiotemporal Composability](20-spatiotemporal-composability-eklenti-dongusu.md) · [21 — REPL Komut Sentezi](21-llm-komut-sentezi-ve-calistirma.md) · [24 — Kendi Kendine Evrilen Araç Sentezi](24-kendi-kendine-evrilen-arac-sentezi-ve-calisma-zamani-denetimi.md) · [32 — Agentic Tool I/O](32-agentic-tool-cagrilari-yapilandirilmis-io-ve-akilli-baglam-kirpma.md) · [AGENTS.md](../AGENTS.md) · [CONFIG.md](../CONFIG.md)

---

## 🎯 1. Hedefler & Mimari İyileştirmeler

1. **Çekirdek Servislerin Typed Coeffect Olarak `Runtime::Context`'e Sağlanması:**
   - `buffer`, `snapshot`, `lsp`, `ast`, `guard`, `sandbox`, `adapters`, `events`, `config`, `index` alt sistemleri `Shell#initialize` sırasında `@runtime_manager.provide` ile kök context'e kaydedildi.
   - Tüm dinamik fiberler ve eklentiler `inject: [:lsp, :buffer]` gibi bağımlılıklarını açıkça belirterek reaktif geçişlerden (`Pending` ↔ `Active`) yararlanabiliyor.

2. **Dinamik Araçlarda Çift Yönlü Ters İşlem (Inverse by Construction):**
   - `ToolRegistry#unregister(name)` ve thread-safe atomic `ToolRegistry#swap(name, new_tool)` metodları `Monitor` ile senkronize edildi.
   - `Shell#unregister_command(name)` metodu eklendi.
   - `SynthesizeToolTool` ve `SynthesizeCommandTool` araçları, sentezlenen nesneyi kaydederken unregister callback'ini `Context`'in $\Omega$ LIFO accumulator'ına kaydeder.
   - Context dispose edildiğinde veya fiber kaldırıldığında hiçbir zombi/çift kayıt kalmaz.

3. **REPL `!runtime`, `!fibers`, `!services` Görsel Komutları:**
   - Kullanıcıya aktif servisleri, kayıtlı fiberlerin durumlarını (`🟢 ACTIVE`, `⏳ PENDING` [eksik coeffect'lerle], `🔴 FAILED`), çözülmüş coeffect DAG'ını ve $\Omega$ accumulator derinliğini gösteren zengin terminal paneli sunuldu.

4. **Orkestrasyon Döngüsünde Scoped Disposable Sub-Context:**
   - `Loop#run` çalıştığında `ctx.extend()` ile izole alt-bağlam açılır; işlem tamamlandığında veya hata alındığında `ensure` bloğunda otomatik imha edilir.

---

## 🛠️ 2. Uygulama Adımları

- [x] **A. `ToolRegistry` Dinamik `unregister` ve `swap` Metodları (`lib/rubik/tools/registry.rb`)**
- [x] **B. Çekirdek Servislerin `Shell#initialize`'da Coeffect Olarak Kaydedilmesi (`lib/rubik/repl/shell.rb`)**
- [x] **C. `SynthesizeToolTool` & `SynthesizeCommandTool` İçin Inverse Kayıt Entegrasyonu (`lib/rubik/tools/builtins.rb`)**
- [x] **D. REPL `!runtime`, `!fibers`, `!services` Komutlarının Eklenmesi (`lib/rubik/repl/shell.rb`)**
- [x] **E. `Orchestrator::Loop` İçinde Scoped Sub-Context Desteği (`lib/rubik/orchestrator/loop.rb`)**
- [x] **F. Birim Testleri (`test/unit/test_spatiotemporal_runtime_invariants.rb`) & Tüm Test Paketinin Doğrulanması (161 test, %100 Yeşil)**
