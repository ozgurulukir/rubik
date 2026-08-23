# 📋 Plan 35: Akıllı Bağlam Sıkıştırma (Context Compactor), Dinamik Token Tahmini ve Otomatik Taşma Kurtarma (Auto-Recovery)

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** ✅ **Tamamlandı** (184/184 Test %100 Yeşil)

---

## 🎯 1. Hedef ve Kapsam

Uzun süren diyaloglarda ve çok adımlı otonom ajan döngülerinde (`!goal`, 30+ adım, büyük dosya okumaları, uzun derleyici/test çıktıları) LLM'in bağlam penceresi (`context_limit`, örn: 32K, 64K, 128K) dolabilir.

Ayrıca modellerin sadece toplam bağlam limiti değil, **üretebilecekleri maksimum çıktı kapasitesi (`max_output_tokens`, örn: 4096, 8192 token)** bulunur. Eğer girdi token'ları bağlamın tamamını kaplarsa, model kod üretirken veya araç çağırırken yarıda kesilir (`finish_reason: "length"` / truncated output).

Bu plan ile Rubik'e:
1. **Model Çıktı Kapasitesi Duyarlı Efektif Bütçeleme (Output Capacity-Aware Budgeting):**
   - $\text{Kullanılabilir Girdi Limiti} = \text{Context Limit} - \text{Max Output Tokens} - \text{Safety Margin}$
   - $\text{Sıkıştırma Eşiği} = \text{Kullanılabilir Girdi Limiti} \times \text{max\_tokens\_ratio}$
   - Bu formül sayesinde modelin her zaman tam kapasitede çıktı üretebilecek serbest token alanı (`max_output_tokens`) garanti altına alınır.
2. **Dinamik Token Tahmin Motoru (`Rubik::Prompt::TokenEstimator`):**
   - Mesaj dizisinin (`@history` ve `@conversation_history`) tahmini token maliyetini ($O(N)$ hızlı BPE/karakter-tabanlı hesaplama) anlık hesaplar.
3. **Akıllı Bağlam Sıkıştırma Motoru (`Rubik::Prompt::ContextCompactor`):**
   - Yapılandırılabilir sıkıştırma stratejileri (`hybrid`, `prune_tool_results`, `sliding_window`, `summarize`).
   - Sistem promptunu ve ilk kullanıcı hedefini (`preserve_first_n`), son adımları (`preserve_last_n`) tam detayda korur; aradaki eski dosya okuma ve araç çıktılarını özetler veya budar.
4. **Yapılandırılabilir Ayar Düğmeleri (Config Knobs in `config.yml`):**
   - `context.compaction_strategy`: `"hybrid"` (varsayılan)
   - `context.max_tokens_ratio`: `0.85` (efektif girdi limitinin %85'ine ulaşıldığında otomatik tetiklenir)
   - `context.tool_result_prune_chars`: `1500`
   - `context.preserve_first_n`: `2`
   - `context.preserve_last_n`: `6`
   - `context.safety_margin_tokens`: `1024`
   - `context.auto_recover_on_overflow`: `true`
5. **Acil Durum Bağlam Aşımı Kurtarma (Auto-Recovery on Context Overflow):**
   - Sağlayıcı 400 Context Length Exceeded (bağlam aşımı) hatası döndürürse ajan döngüsü çökmez; acil sıkıştırma (`emergency_compact!`) yaparak adımı otomatik olarak yeniden dener.
6. **REPL `!context` Komutu:**
   - Mevcut aktif bağlam boyutunu, modelin çıktı kapasitesini (`max_output_tokens`), tahmini girdi token kullanımını, kalan bütçeyi ve sıkıştırma durumunu görsel olarak gösterir (`!context status`, `!context compact`).

---

## 🏛️ 2. Yapılacak Teknik Değişiklikler

### A. [`lib/rubik/prompt/token_estimator.rb`](../lib/rubik/prompt/token_estimator.rb) (Yeni Modül)
- `TokenEstimator.estimate_text(text)` -> karakter/kelime ve BPE yaklaşımıyla yaklaşık token sayısını döner (~3.8 karakter / token ortalaması).
- `TokenEstimator.estimate_message(msg)` -> rol, içerik ve `tool_calls` dahil token hesaplar.
- `TokenEstimator.estimate_history(messages)` -> tüm diyalog geçmişinin toplam token hacmini hesaplar.

### B. [`lib/rubik/prompt/context_compactor.rb`](../lib/rubik/prompt/context_compactor.rb) (Yeni Modül)
- `ContextCompactor.compact_history(history, context_limit:, config:)`:
  - Eşik kontrolü: `current_tokens > (context_limit * max_tokens_ratio)` olduğunda devreye girer.
  - Stratejiler:
    - `:prune_tool_results`: Eski adımlardaki devasa `tool_result` XML içeriklerini önemli başlık ve durumları koruyarak budar.
    - `:sliding_window`: Eski ara adımları atlar.
    - `:hybrid`: İlk adımı (hedef) ve son N adımı korur, ortadaki eski araç sonuçlarını budayıp `<compacted_steps_summary>` ekler.
- `ContextCompactor.emergency_compact!(history)`:
  - 400 hatası alındığında agresif sıkıştırma uygulayarak bağlamı anında %50 küçültür.

### C. [`lib/rubik/config.rb`](../lib/rubik/config.rb)
- `DEFAULT_CONFIG["context"]` bloğunu ekleme.

### D. [`lib/rubik/orchestrator/loop.rb`](../lib/rubik/orchestrator/loop.rb)
- `execute_steps` döngüsünde her LLM çağrısı öncesi `ContextCompactor.compact_if_needed!` kontrolü.
- `Rubik::LLM::ClientError` yakalandığında eğer mesaj "context" / "maximum context length" içeriyorsa `emergency_compact!` yapıp 1 kez kurtarma denemesi yapma.

### E. [`lib/rubik/repl/shell.rb`](../lib/rubik/repl/shell.rb)
- `!context` komutunu ekleme (`!context status`, `!context compact`).

---

## 🧪 3. Test ve Doğrulama Planı

- `test/unit/test_context_compactor_and_truncation.rb`:
  - Token tahmin doğruluğu.
  - Eşik aşıldığında `compact_history` çalışması ve token tasarrufu.
  - Sistem promptu ve son adımların korunması (`preserve_first_n`, `preserve_last_n`).
  - 400 context overflow simülasyonunda `auto_recover_on_overflow` ile döngünün başarıyla kurtulması.
  - REPL `!context` komutu testi.
  - Tüm 170+ testin %100 yeşil geçmesi.
