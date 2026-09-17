# Plan 91 — Çok Satırlı Yapıştırma Desteği: `!paste` Modu ve Paste-Burst Birleştirme

> **Durum:** ✅ **Tamamlandı**  
> **Zorluk:** Orta  
> **Faz:** 9  
> **Öneri Bölümü:** REPL Çekirdeği, Girdi Döngüsü & Kullanıcı Ergonomisi  
> **İlgili Planlar:** [02](02-repl-cekirdegi.md), [49](49-tam-kapsamli-cross-platform-ve-windows-uyumluluk-mimarisi.md), [51](51-display-katmani-hibrit-tui-mimarisi.md), [61](61-llm-baglam-surekliligi-hata-turlerinde-kayit-ve-stream-butunlugu.md), [79](79-guvenlik-baslatma-izolasyonu-sandbox-seffafligi-ve-repl-sh-tamiri.md)

---

## 🎯 1. Motivasyon ve Sorun Tanımı

Kullanıcı, LLM'den üretilmiş bir kod bloğunu veya herhangi bir çok satırlı metni terminale yapıştırdığında, Windows konsolu ve Reline'da **bracketed-paste** desteği bulunmadığından blok satır satır ENTER'larla gelir. REPL her satırı ayrı bir turn sayar:

```text
> def foo          ← anında değerlendirilir → SyntaxError (blok henüz tamamlanmadı)
>   puts 1         ← ayrı turn
> end              ← ayrı turn
```

### 🔍 Kök Neden Analizi (Root Causes)

1. **Satır-satır teslim:** Yapıştırma, dosya okuma gibi atomik bir girdi değildir; terminal her satırı ayrı readline dönüşü olarak sunar.
2. **`in_pasting?` yanılgısı:** Reline `IOGate#in_pasting?` TTY olmayan girişte (test harness, pipe) yanıltıcı `true` döndürebilir; kör güven, sıralı test satırlarını tek turn'e yutar.
3. **Yavaş/kopan yapıştırma:** Zamanlama tabanlı burst algılama tek başına yeterli değildir; büyük bloklar, yavaş panolar veya SSH gecikmesinde iki satır arası pencereyi aşar ve blok ortadan kopar.

---

## 🏗️ 2. Mimari Çözüm ve Fazlar

```
 ┌──────────────────────────────────────────────────────────────────────┐
 │          PLAN 91 — ÇOK SATIRLI YAPIŞTIRMA (PASTE) DESTEĞİ            │
 └──────────────────────────────────┬───────────────────────────────────┘
                                    │
          ┌─────────────────────────┼─────────────────────────┐
          ▼                         ▼                         ▼
 ┌───────────────────┐    ┌────────────────────┐    ┌────────────────────┐
 │      FAZ A        │    │       FAZ B        │    │       FAZ C        │
 │ PasteSupport      │    │ Paste-Burst        │    │ `!paste` Komutu &  │
 │ Mixin + Durum     │    │ Birleştirici       │    │ Dokümantasyon      │
 ├───────────────────┤    ├────────────────────┤    ├────────────────────┤
 │ • Join window     │    │ • collect_paste_   │    │ • !paste (nokta    │
 │ • paste_clock     │    │   burst            │    │   ile bitir)       │
 │ • in_pasting?     │    │ • tek prompt turn  │    │ • ui.paste_join_   │
 │   gate            │    │ • interactive gate │    │   window_ms ayarı  │
 └───────────────────┘    └────────────────────┘    └────────────────────┘
```

### Faz A — `PasteSupport` Mixini (`lib/rubik/repl/paste_support.rb`)

- `paste_join_window_ms`: iki readline dönüşü arasındaki maksimum "aynı burst" süresi (varsayılan 120 ms; `ui.paste_join_window_ms` ile ayarlanır).
- `paste_clock`: monotonik sayaç (`Process.clock_gettime(CLOCK_MONOTONIC)`); testler singleton ile ezebilir.
- `paste_pending?`: yalnızca gerçek interaktif konsolda `IOGate#in_pasting?` — TTY olmayan ortamda `false` (yanıltıcı pozitiflere karşı `interactive_input?` şartı).
- `paste_burst_eligible?`: burst toplayıcının kapısı; yalnızca gerçek konsolda `true` (testler override ederek toplayıcıyı deterministik egzersize alır).
- `read_paste_block`: explicit paste modu okuyucusu — satırları `.` satırına (veya EOF / Ctrl+D) kadar toplar, `lines.join("\n")` ile döndürür. Zamanlamaya **hiç** başvurmaz; blok her koşulda tek parça kalır.

### Faz B — Paste-Burst Birleştirici (`lib/rubik/repl/input_loop.rb`)

- `read_and_process_line`, kabul edilen her satırın monotonik zaman damgasını `last_line_at` olarak döndürür; takip eden satır pencere içinde gelirse `collect_paste_burst` devreye girer.
- `collect_paste_burst`: satırlar `paste_join_window_ms` içinde gelmeye (veya `paste_pending?` devam etmeye) sürdüğü sürece biriktirir; burst bittiğinde birleşik bloğu **tek prompt turn** olarak gönderir.
- Kapı koşulları: yalnızca gerçek interaktif konsol (`paste_burst_eligible?`), boş olmayan satır, heredoc modu ve çoklu-satır tamponu boşken. Böylece pipe/test yolu (`run_stream`, stub'lı readline) hiç etkilenmez.
- Açılan boş Enter, yapıştırmanın **ilk** satırının da burst'e katılabilmesi için `last_line_at` damgası basar (engelleyici readline'da bekleyen ilk satır dondurulamaz).
- `!paste` bayrağı `@paste_requested`, `read_and_process_line` başında **capture-then-reset** ile tüketilir: bayrak paste yolunda tüketilmezse sonraki her prompt paste moduna düşer ve nil döndüren pipe'lı readline sonsuz döngüye girer.

### Faz C — `!paste` Komutu ve Dokümantasyon

- `lib/rubik/repl/commands/session.rb`: `!paste` — bir sonraki prompt'ta `read_paste_block`'u başlatır; blok tek turn olarak yürütülür.
- `lib/rubik/config/defaults.rb`: `ui.paste_join_window_ms` (120) varsayılanı.
- `COMMANDS.md` §7 ve `CONFIG.md` `ui:` şablonu güncellendi.

---

## 📋 3. Başarı Kriterleri

- [x] YAP IŞTIRILAN blok, satırları ne kadar hızlı gelirse gelsin, tek prompt turn olarak yürütülmeli.
- [x] Elle yazılan ardışık satırlar asla birleştirilmemeli (pencere dışında kaldığında ayrı turn).
- [x] Pipe/stream girişi ve test harness'ı burst toplayıcıdan tamamen izole kalmalı.
- [x] `!paste` modu zamanlama sezgisine hiç güvenmeden bloğu `.` satırına kadar tek parça toplamalı; boş ve sondaki satırlar birebir korunmalı.
- [x] Yanlış paste-modu bayrağı sızıntısı sonsuz döngüye yol açmamalı (capture-then-reset).
- [x] Test paketi 0 failure, 0 error ile geçmeli.

---

## 🏁 4. Uygulama Sonucu ve Doğrulama

- **Faz A:** `lib/rubik/repl/paste_support.rb` oluşturuldu; `Shell` mixin'i include etti ve `@paste_requested` durumunu taşıyor.
- **Faz B:** `lib/rubik/repl/input_loop.rb` içine burst toplayıcı ve `run_paste_mode` eklendi; heredoc/çoklu-satır tamponu etkileşimi korundu.
- **Faz C:** `!paste` komutu `lib/rubik/repl/commands/session.rb` içinde kaydedildi; `ui.paste_join_window_ms` `lib/rubik/config/defaults.rb`'ye eklendi.
- **Faz D:** `test/unit/test_paste_support.rb` (8 run, 13 assertion) ve `test/unit/test_repl.rb` %100 yeşil; tam paket **1544 run / 8811 assertion / 0 failure / 0 error / 1 skip**. Test harness kurulum düzeltmesi (rootless `Shell.new` senkron repo indekslemesi ~6s/test → izole tmpdir konvansiyonu ile ~2s) aynı pakette tamamlandı; `test_paste_support` 30s → 1.9s, `test_repl` 49s → 2.8s.
