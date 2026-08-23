# 📋 Plan 37: Kademeli Verbosity (Ayrıntı Düzeyi) Yapılandırması, Canlı Ajan İzleme ve REPL `!verbosity` Komutu

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** ✅ **Tamamlandı** (196/196 Test %100 Yeşil)

---

## 🎯 1. Problem ve İhtiyaç Analizi

### Mevcut Durum ("Verbose Off" Hissi)
Şu anda `Rubik::REPL::Shell#execute_free_text` içinde serbest metin veya kodlama görevi çalışırken:
* Model arka planda araç çağırırken yalnızca `[Rubik::Act] Calling read_file...` şeklinde argümansız, kuru bir satır basılmaktadır.
* Aracın ne sonuç ürettiği (`tool_result`), kaç milisaniye sürdüğü, kaç satır okunduğu/yazıldığı kullanıcıya hiç yansıtılmamaktadır.
* Modelin ara düşünceleri, token tüketimi, adım bütçesi detayları ve LSP uyarıları gizli kalmakta; kullanıcı ajanın ne yaptığını göremediği için sistem donmuş ya da sessiz ("verbose off") gibi hissetmektedir.

### Çözüm Hedefi
Kullanıcının tercihine göre 4 kademeli (0-3) ayarlanabilir `verbosity` config knob'u eklemek:
1. **`quiet` (0):** Sıfır ara gürültü. Sadece nihai yanıt ve kritik hatalar.
2. **`normal` (1 - Varsayılan):** Temiz, estetik ve bilgilendirici akış (Adım no, araç adı + temel argüman, özet sonuç, süre).
3. **`verbose` (2):** Ayrıntılı operasyonel görünüm (Tam JSON argümanları, ilk 3-5 satır çıktı önizlemesi, token tüketimi, LSP hata bildirimleri, ara mesajlar).
4. **`debug` / `trace` (3):** Geliştirici ve teşhis seviyesi (Tüm ham araç girdi/çıktıları, compactor token tahminleri, tam gecikmeler).

Ayrıca çalışma zamanında REPL içinden `!verbosity <seviye>` (veya `!verbose on/off`) ile anında değiştirilebilmesi.

---

## 🏛️ 2. Mimari Bileşenler ve Tasarım

```
                 ┌──────────────────────────────────────────────┐
                 │       Config: ui.verbosity / agent.verbosity │
                 │      (quiet: 0 | normal: 1 | verbose: 2 | debug: 3)
                 └──────────────────────┬───────────────────────┘
                                        │
                                        ▼
                  ┌───────────────────────────────────────────┐
                  │    Rubik::REPL::StepFormatter (Yeni)      │
                  │  Formats :tool_call, :tool_result, etc.   │
                  └─────────────────────┬─────────────────────┘
                                        │
             ┌──────────────────────────┼──────────────────────────┐
             ▼                          ▼                          ▼
      [ quiet (0) ]              [ normal (1) ]            [ verbose/debug (2/3) ]
 • Sadece bitiş yanıtı      • ▶ [Step 2] read_file         • ▶ [Step 2] read_file (full JSON)
 • Hatalar                  • ✔ [Obs] 48 lines (12ms)      • ↳ Output Preview (5 lines)
                            • ⚠️ Bütçe / LSP uyarıları     • 📊 Tokens: in 4.2k, out 310
                                                           • 🔍 Full raw I/O & Compactor
```

### A. Yapılandırma Şeması (`lib/rubik/config.rb`)
```ruby
"ui" => {
  "verbosity" => "normal" # "quiet" (0), "normal" (1), "verbose" (2), "debug" (3)
}
```

### B. `Rubik::REPL::StepFormatter` (Biçimlendirici Servis)
`lib/rubik/repl/step_formatter.rb`:
Tek bir merkezi biçimlendirici sınıf, `on_step` event'lerini (`:tool_call`, `:tool_result`, `:message`, `:step_warning`, `:auto_apply`, `:emergency_compact`, `:finish`) seçilen verbosity seviyesine göre renkli ve okunabilir ANSI/düz metin formatına dönüştürür.

- **`normal` Seviye Çıktı Örnekleri:**
  ```text
   ▶ [Adım 1/40] read_file (path: "src/main.ts")
   ✔ [Sonuç] 142 satır okundu (12.4ms)
   ▶ [Adım 2/40] write_file (path: "src/main.ts", +15 satır)
   ✔ [Sonuç] Belleğe yazıldı (3.1ms) [LSP: 0 hata]
   ▶ [Adım 3/40] run_tests (command: "npm test")
   ✔ [Sonuç] Testler başarılı (18 test, 0 hata) (420.5ms)
  ```

- **`verbose` Seviye Çıktı Örnekleri:**
  ```text
   ▶ [Adım 1/40] Calling read_file with args: { "path": "src/main.ts" }
   ✔ [Obs] 142 satır (12.4ms) | Token tahmini: ~1,200 tok
     ↳ Preview:
       1: import { createApp } from 'vue'
       2: import App from './App.vue'
       3: ...
   ▶ [Adım 2/40] Auto-applying 1 file(s) to disk before test run: src/main.ts
  ```

### C. REPL Kabuğu (`lib/rubik/repl/shell.rb`)
1. `execute_free_text`, `!goal` ve `!plan` komutlarının `on_step` callback'ini merkezi `StepFormatter` ile bağlama.
2. `!verbosity` ve `!verbose` komutlarının eklenmesi:
   - `!verbosity` $\rightarrow$ mevcut seviyeyi gösterir.
   - `!verbosity normal|verbose|debug|quiet` (veya `0|1|2|3`) $\rightarrow$ anında günceller ve kaydeder.
   - `!verbose` $\rightarrow$ `normal` ile `verbose` arasında toggle eder.

### D. Orkestratör Döngüsü (`lib/rubik/orchestrator/loop.rb`)
- `execute_steps` içinde daha zengin `on_step` olayları:
  - `:step_start` (adım başlangıcı ve tahmini token bütçesi)
  - `:llm_thought` (modelin araç çağırmadan önceki ara düşünce metni)
  - `:tool_result` (status, duration_ms, truncated, line_count, byte_size)

---

## 🧪 3. Test ve Doğrulama Planı

`test/unit/test_verbosity_and_step_formatter.rb`:
1. **Seviye Dönüşümü:** `quiet`, `normal`, `verbose`, `debug`, `0`, `1`, `2`, `3` string/integer ayrıştırma testleri.
2. **StepFormatter Çıktı Doğrulaması:**
   - `quiet`: `:tool_call` ve `:tool_result` için `nil` / boş çıktı.
   - `normal`: Kompakt satır (araç adı, temel parametre, özet ve süre).
   - `verbose`: Ayrıntılı argümanlar, önizleme satırları, token bilgileri.
   - `debug`: Tam döküm.
3. **REPL Shell Entegrasyonu:**
   - `!verbosity` komutunun çalışması ve seviye değiştirmesi.
   - Serbest metin akışında `StepFormatter`'ın doğru işletilmesi.
4. **Tüm Test Paketi Regresyon Kontrolü:** 193+ testin %100 yeşil kalması.

---

## 🚀 4. Uygulama Adımları

1. **Adım 1:** `lib/rubik/config.rb` içine `"ui" => { "verbosity" => "normal" }` ekle.
2. **Adım 2:** `lib/rubik/repl/step_formatter.rb` sınıfını oluştur.
3. **Adım 3:** `lib/rubik/orchestrator/loop.rb` `on_step` yükünü zenginleştir.
4. **Adım 4:** `lib/rubik/repl/shell.rb` içine `StepFormatter`, `!verbosity` ve `!verbose` komutlarını bağla.
5. **Adım 5:** `test/unit/test_verbosity_and_step_formatter.rb` testlerini yaz ve tüm test paketini koştur.
