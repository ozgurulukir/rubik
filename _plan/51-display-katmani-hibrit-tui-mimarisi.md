# 51 — Display Katmanının Hibrit TUI Mimarisi

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Uygulandı (A–E Tüm Fazlar)** · **Zorluk:** Orta–Zor · **Faz:** 6 (Display Katmanı & Terminal UX)  
> **İlgili Planlar:** [02](02-repl-cekirdegi.md), [27](27-tampon-kirli-durum-hatirlatici-ve-akilli-ping-sistemi.md), [37](37-kademeli-verbosity-ayarlari-ve-canli-ajan-izleme.md), [41](41-repl-komut-modulerizasyonu-domain-driven-command-decoupling.md), [43](43-repl-bang-komut-standardizasyonu-ve-wiring-denetimi.md), [49](49-tam-kapsamli-cross-platform-ve-windows-uyumluluk-mimarisi.md), [50](50-varsayilan-llm-stream-iletisimi-ve-canli-token-akisi.md)  
> **Kapsam:** `lib/rubik/ui/**` (yeni modül), `lib/rubik/repl/shell.rb`, `lib/rubik/repl/presentation.rb` (yeni), `lib/rubik/repl/step_formatter.rb`, `lib/rubik/repl/tee_io.rb`, `lib/rubik/repl/confirmations.rb`, `lib/rubik/repl/commands/*`, `lib/rubik/config.rb`, `lib/rubik/orchestrator/loop.rb` (yalnız meta zenginleştirme), `lib/rubik/runtime/context.rb`, `rubik.gemspec`, `bin/rubik`, `CONFIG.md`, `COMMANDS.md`, `README.md`  
> **Çalışma Zamanı Bağımlılıkları:** `pastel`, `strings-ansi`, `tty-markdown`, `tty-prompt`, `tty-spinner`

---

## 🎯 1. Hedef ve Gerekçe

Rubik'in display katmanı bugün **tamamen düz metin** çalışmaktadır: ANSI renk kodu yoktur, LLM yanıtları ham markdown sözdizimiyle basılır, ajan adımları `⏳ [Step 1/40] Thinking...` / `▶ [Step 1/40] write_file (path: ...)` / `✔ [Obs] 3 lines (15.2ms)` biçiminde tek düze listelenir, açılışta banner yoktur ve tüm etkileşim `rubik (proje) [branch] > ` düz promptuna sıkışmıştır (Keşif raporu: `StepFormatter`, `Shell#execute_free_text`, `TeeIO`).

Bu plan, display katmanını sektörün iki referans ajan CLI'ının **hibrit** tasarımına dönüştürür:

1. **Claude Code'un sunum dilinden:** renkli tema ve marking dili (`⏺` eylem mermisi, `⎿` sonuç dalı), canlı spinner + geçen süre, akış sırasında markdown render'ı, bilgi yoğunluğu yüksek daraltılmış tool satırları, girdi kutusu estetiği ve "esc ile kes" tarzı iç ipuçları.
2. **Antigravity CLI'ın operasyonel yüzeylerinden:** ajan/fiber yönetim panosu (`/agents` muadili `!agents`), prompt üzerinde hızlı onay kartları ve tuş kısayolları, sandbox durumuna **adaptif onay soruları**, özelleştirilebilir durum çubuğu (statusline), etkileşimli diff görüntüleyici ve oturum seçici.

Temel kazanımlar:

1. **Sıfır Tekerlek İcadı:** Renk, spinner, menü, kutu, tablo ve markdown render'ı bakımlı Ruby gem'lerine (TTY ekosistemi) devredilir; Rubik yalnızca **bileşim ve tema** katmanı yazar.
2. **ANSI Hijyeni Garantisi:** Oturum kayıtları (`Session::Recorder`), `conversation_history` ve LLM bağlamı **asla** ANSI kodu görmez; renk yalnızca gerçek TTY hedefe üretilir, kayıt yolunda otomatik soyulur.
3. **Deterministik Pipe/CI Modu:** `RUBIK_TEST=1`, pipe/görsel olmayan terminal, `NO_COLOR`, `TERM=dumb` koşullarında çıktı bugünkü düz-metin sadeliğinde kalır; mevcut test yapısı bozulmaz.
4. **Spatiotemporal Uyum:** Yeni `UI::RenderService`, AST/Index/Loop servisleri gibi **reaktif coeffect servisi** olarak kaydedilir; spinner thread'i `ctx.on_dispose` ters işlemiyle LIFO öldürülür — `AGENTS.md` "Leaked Side Effects" anti-pattern'ine düşülmez.
5. **Verbosity Semantiği Korunur:** `quiet/normal/verbose/debug` matrisi aynen kalır; yalnızca **görsel dil** değişir.

---

## 🔍 2. Araştırma Özeti

### 2.1. Mevcut Durum (Rubik)

| Yüzey | Bugünkü Hali | Kaynak |
| :--- | :--- | :--- |
| Renk | Yok — hiçbir ANSI/kaçış dizisi kullanılmıyor | kapsamlı grep: 0 eşleşme |
| Ajan adımları | ` ⏳ [Step N/M]`, ` ▶ ...`, ` ✔ [Obs]`, ` ✖ [Error]` (düz metin + emoji) | `step_formatter.rb:42-255` |
| LLM yanıtı | Ham markdown, hiçbir işleme yok (stream ve batch) | `shell.rb:429,458` |
| Prompt | `rubik (proje) [branch] [DIRTY: N ✎] > ` (Reline) | `shell.rb:226-233` |
| Banner | Yok | `bin/rubik` |
| Onaylar | `ask_yes_no` → `[Y/n]: ` (Reline satırı) | `confirmations.rb` |
| Paneller | Yok — `!fibers`, `!runtime` düz liste | `commands/agent.rb` |
| Kayıt | `TeeIO` fan-out; ANSI zaten olmadığından strip sorunu yok | `tee_io.rb` |

Orkestratörün `on_step` sözleşmesi zengindir (13 olay tipi: `:thinking`, `:chunk`, `:chunk_end`, `:tool_call`, `:tool_result`, `:llm_thought`, `:llm_retry`, `:step_warning`, `:auto_apply`, `:emergency_compact`, `:finish`, `:message` + payload anahtarları) — **görünüm katmanı için veri hazırdır**, yalnızca sunum eksiktir.

### 2.2. Claude Code (Sunum Dili Referansı)

React/Ink tabanlı bir TUI'dir; bizim için önem taşıyan **görsel sözleşmesi** şudur:

- **`⏺` (dolu daire):** her eylem/tool çağrısı tek satır başlık — `⏺ Read(file.md)`.
- **`⎿` (sol-alt dal):** eyleme bağlı sonuç satırları — `⎿ 42 lines · 1.2s`; alt sonuçlar aynı glifle girintilenir.
- **Spinner:** turuncu `✻`/`✳` glifi + döngüsel fiiller (*Brewing, Simmering, Percolating…* tam liste 187 fiil) + geçen süre; statik "Thinking..." yoktur.
- **Girdi kutusu:** yuvarlatılmış çerçeveli girdi alanı, altında soluk ipucu satırı (`esc to interrupt` vb.).
- **Tema:** sıcak turuncu marka vurgusu, soluk gri ikincil metin, düşünceler dim/italik, kod blokları çerçeveli.
- **İçerik:** akış sırasında markdown render (başlık, kalın, kod bloğu), diff ±renkli.
- **Durum çubuğu:** model, bağlam/pencere kullanımı, maliyet göstergesi.

Kaynaklar: [Claude Code Internals — Terminal UI](https://kotrotsos.medium.com/claude-code-internals-part-11-terminal-ui-542fe17db016), [Claude Code from Source — Ch 13](https://claude-code-from-source.com/ch13-terminal-ui/), [spinner fiilleri listesi](https://deepakness.com/raw/claude-spinner-verbs/), [resmî changelog](https://code.claude.com/docs/en/changelog).

### 2.3. Antigravity CLI (Operasyonel Yüzey Referansı)

Google'ın `agy` komutuyla çalışan TUI'ı; Claude Code'dan farklı olarak öne çıkan **operasyon yüzeyleri**:

- **`/agents` panosu:** aktif/tamamlanmış alt ajanların listesi (durum: running/done/killed + mevcut adım); seçince **tam ekran detay**: adım geçmişi, düşünceler, tool günlükleri, bekleyen onaylar.
- **Hızlı onay yolları:** `Ctrl+K` = sohbetten ayrılmadan bekleyen izni anında onayla; `Ctrl+J` = sıradaki onay bekleyen alt ajana atla; **Fast Path Alerts** doğrudan prompt kutusunun üzerinde yığılır.
- **Adaptif onay soruları:** sandbox **açıkken** "Evet ve sandbox'suz çalıştır", **kapalıyken** "Evet ve sandbox'ta çalıştır" seçeneği sunar.
- **`/statusline`:** canlı durum çubuğu şablonu (model, token, durum); `/diff` etkileşimli diff; `/resume` oturum seçici; `/tasks` arka plan görevi izleme.

Kaynaklar: [resmî özellik sayfası](https://antigravity.google/docs/cli/features/), [GitHub](https://github.com/google-antigravity/antigravity-cli), [ürün sayfası](https://antigravity.google/product/antigravity-cli).

### 2.4. Ruby TUI Gem Ekosistemi (2026)

| Gem | Sürüm | Rolü | Not |
| :--- | :--- | :--- | :--- |
| **`pastel`** | ~> 0.8 | ANSI renk/stil; String'i monkey-patch etmez | TTY standardı, çapraz emulator |
| **`tty-spinner`** | ~> 0.17 | Spinner frame zamanlaması, imleç gizleme, çok satır | Geçen süre bizde eklenir |
| **`tty-prompt`** | ~> 0.23 | Menü/evet-hayır/keypress; `input:`/`output:` enjeksiyonu | Paneller + onaylar |
| **`tty-screen`** | ~> 0.8 | Terminal genişliği/yükseklik | Kutu sarma hesabı |
| **`tty-box`** | ~> 0.7 | Çerçeveli kutular (rounded border dahil) | Banner + onay kartı |
| **`tty-table`** | ~> 0.12 | Hizalı tablolar | `!providers`, `!lsp`, `!session` |
| **`tty-markdown`** | ~> 0.7 | markdown→ANSI (kramdown tabanlı) | Yalnız batch/tam belge |
| **`strings-ansi`** | ~> 0.2 | ANSI strip | `TeeIO` kayıt yolu hijyeni |

Tam ekran Elm-tarzı TUI istenseydi aday **Charm Ruby** (Bubble Tea/Lip Gloss portlaması) olurdu; ancak REPL + canlı stream + oturum kaydı mimarisiyle çelişir ve olgunluğu düşüktür → **değerlendirildi, reddedildi** (bkz. §3.1). Ek okuma: [TTY Toolkit](https://ttytoolkit.org/), [Brett Terpstra 2025 incelemesi](https://brettterpstra.com/2025/10/15/ruby-progress-indicators-for-modern-cli-tools/), [Charm Ruby](https://marcoroth.dev/posts/glamorous-christmas).

---

## 💡 3. Tasarım Kararları

### 3.1. Karar D1 — Reline **kalır**, UI katmanı etrafını sarar (tekerlek testi)

Reline değiştirme izni verilmiş olsa da dürüst değerlendirme: `tty-reader`/özel girdi döngüsüne geçiş, satır düzenleme tekerleğini (imleç hareketi, geçmiş, çok satırlı/heredoc, geniş karakter, yapıştırma) **yeniden icat etmek** olur. Üstelik Plan 49 ve `InterruptHandler` Windows Reline yamalarına ciddi yatırım yapılmıştır. Bunun yerine:

- Reline **satır düzenleyici motoru** olarak kalır (stdlib, Windows'a yamalı).
- **Faz A:** prompt pastel ile renklendirilir + üstüne statusline satırı eklenir.
- **Faz E (opsiyonel, `ui.input_box: true`):** Reline'ın **çok satırlı prompt** desteğiyle (prompt dizisi) üst çerçeve + sol ray `╭─╮ │`; Enter sonrası Shell alt çerçeveyi `╰─╯` basar. Sağ rayın canlı güncellenemeyeceği Reline sınırı belgelenir; tam kapalı kutu istenirse ileride ayrı plan (tty-reader/Charm Ruby) açılır.

### 3.2. Karar D2 — `StepFormatter` semantik katman olarak kalır, `UI::Renderer` dekoratördür

Orkestratör→`on_step` sözleşmesi ve verbosity seviye matrisi **dokunulmaz**. Yeni `UI::Renderer`, `StepFormatter` çıktısını alır; glif/marka dili uygular (`▶`→`⏺`, `✔ [Obs]`→`⎿`), süreyi/satır sayısını meta satıra taşır ve renk ekler. Glif değişimi **TTY olsun olmasın** görünürdür (tek görsel dil); renk yalnız capability izinliyken. Bu, `test_verbosity_and_step_formatter.rb` görsel metinlerinin tek PR'da güncellenmesini gerektirir — semantik testler (quiet→nil matrisi vb.) aynen korunur.

### 3.3. Karar D3 — ANSI Hijyen Politikası

1. Renk **yalnızca** `UI::Capability.color?` true iken üretilir: TTY + `NO_COLOR` yok + `TERM != dumb` + `ui.color != never` (+ `CLICOLOR_FORCE=1` override, `RUBIK_TEST=1` → asla).
2. `TeeIO`, **StringIO hedeflerine** yazarken `strings-ansi` ile kaçış kodlarını soyar → oturum JSONL, `conversation_history`, LLM bağlamı temiz kalır.
3. Windows conhost: Fiddle ile `SetConsoleMode(ENABLE_VIRTUAL_TERMINAL_PROCESSING)` denenir; başarısızsa renk kapalı + ASCII glif seti. Windows Terminal zaten VT destekler.

### 3.4. Karar D4 — Spinner'ın ömrü context'e bağlıdır

`UI::Spinner` kendi thread'inde `tty-spinner` döndürür; `:thinking` olayında başlar, ilk `:chunk`/`:tool_call`/`:finish` olayunda **önce durur sonra** çıktı basılır (mutex ile yarış önlenir). Thread `ctx.on_dispose { spinner.kill }` ile kayıt altındadır — REPL 1000 tur dispose/reload yapılsa bile sızıntı olmaz (`AGENTS.md` kontrol listesi, "Zero-Restart Reloading").

### 3.5. Karar D5 — Markdown: canlı akış için hafif satır render, batch için tty-markdown

`tty-markdown` (kramdown) **tam belge** ister; token token akıtamaz. Bu nedenle iki kollu strateji:

- **Canlı (`:chunk`)**: hafif **satır odaklı** render — başlık (kalın+vurgu), `**kalın**`, `` `satır içi kod` ``, liste mermisi, kod çiti açılınca sol ray `│ ` + dim zemin; satır tamamlanınca (newline) render edilip basılır.
- **Batch (`stream: false`) ve `!session` gösterimi**: tüm yanıt `tty-markdown` ile tek seferde render.
- Çift-basım önlenir: canlı modda `res[:output]` zaten basılmıştır (Plan 50 double-print guard'ı).

### 3.6. Karar D6 — `UI` bir Runtime Coeffect servisi olur

`Rubik::Runtime::RenderService.register(@runtime_manager, shell: self)` kalıbıyla (ASTService/IndexService benzeri): servis `ui` adıyla `provide` edilir; sentezlenen komutlar (`synthesize_command`) ve plugin'ler `ctx.require("ui")` ile **temaya ve renderer'a** erişir — öz-evrilen araçların çıktıları da aynı görsel dili konuşur. Dispose, spinner thread'i ve kayıtlı inverseleri LIFO çalıştırır.

---

## 🏛️ 4. Mimari Tasarım

```
                          [ Kullanıcı Girdisi / Reline ]
                                       │
                     ┌─────────────────▼──────────────────┐
                     │           REPL::Shell              │
                     │  statusline ─ prompt ─ ipucu       │
                     └─────────────────┬──────────────────┘
                                       │ on_step(event)
                     ┌─────────────────▼──────────────────┐
                     │        UI::Renderer (Faz B)        │◄── StepFormatter (sema ntik, korunur)
                     │  ⏺ eylem / ⎿ sonuç / ↳ detay      │
                     └───────┬───────────────────┬────────┘
                             │                   │
              :thinking │ diğer olaylar          │ :chunk
                             │                   │
                  ┌──────────▼─────────┐   ┌─────▼──────────────┐
                  │   UI::Spinner      │   │ UI::MarkdownStream │
                  │ tty-spinner+fiil  │   │ (satır odaklı)      │
                  │ +geçen süre        │   └─────┬──────────────┘
                  └──────────┬─────────┘         │
                             │                   │
                     ┌───────▼───────────────────▼──────────┐
                     │        UI::Screen / Pastel           │
                     │  Capability: TTY? NO_COLOR? VT?      │
                     └───────┬───────────────────┬──────────┘
                             │ renkli (TTY)      │ düz + strip
                     ┌───────▼───────┐   ┌───────▼──────────┐
                     │   $stdout     │   │  TeeIO→StringIO  │──► Recorder /
                     └───────────────┘   └──────────────────┘    conversation_history (ANSI'sız)

   Antigravity yüzeyleri: UI::Approvals (hızlı onay + adaptif sandbox)
                          UI::Panel (!agents) · UI::DiffViewer (!diff)
                          UI::Statusline · UI::Banner
```

### 4.1. Hedef Görsel Dil (Somut Spesifikasyon)

**Ajan akışı (quiet=kapalı, normal):**

```
✻ Kavuruyor… 4sn                                    (ctrl+c: akışı kes)

⏺ write_file — lib/validator.rb
  ⎿ tampon hazır · +3 satır · 18ms        (!diff ile incele)
⏺ run_tests — bundle exec rake test
  ⎿ ✔ 513 test · 0 hata · 4.2s
  ⎿ ↻ 1 retry (rate limit)
```

- `⏺` marka vurgu renginde (Rubik kırmızısı); `⎿` satırları soluk gri; hata `✖` kırmızı; uyarı `⚠` sarı; düşünce `💭` dim italik (verbose+).
- Spinner fiilleri Türkçe ve yapılandırlabilir: `Düşünüyor, Kavuruyor, Karıştırıyor, Damıtıyor, Biçimlendiriyor, Küpüyor…` (`ui.spinner_verbs`).
- Süre/satır/token meta bilgisi `⎿` satırına taşınır; `▶ [Step N/M]` öneki kalkar, adım sayısı statusline'a geçer (verbose'ta geri gelir).

**Prompt + statusline (Faz A):**

```
─ rubik · my_project · main · deepseek/deepseek-coder · ctx %34 · 1 ✎ · sandbox ─
rubik › _
  !komutlar · ?yardım · ctrl+c kes
```

**Hızlı onay kartı (Antigravity Fast Path, Faz C):**

```
┌ ⚠ ONAY BEKLİYOR ──────────────────────────────────────┐
│ write_file → config/credentials.yaml (kritik dosya)   │
└───────────────────────────────────────────────────────┘
  y onayla · n reddet · d diff · e bu dosyayı her zaman onayla
```

**Adaptif sandbox soruları (Faz C):** `sandbox` **açık** → `y onayla · a onayla ve ağ izniyle çalıştır`; **kapalı** → `y onayla · s onayla ve sandbox'ta çalıştır`.

**`!agents` panosu (Antigravity `/agents` muadili, Faz D):**

```
=== Ajan / Fiber Panosu ===
▸ 🟢 orchestrator_loop     adım 12/40 · write_file · Ω derinliği 3
  ⏳ ast_indexer            1.2k dosya tarandı
  ✔ repair_loop            tamamlandı (3 deneme)
  ↑↓ gezin · enter detay · esc çık
```

Detay görünümü: fiberin adım geçmişi, düşünceler, tool çağrıları ve bekleyen onayları (tty-prompt select).

### 4.2. Yeni Modül Haritası

| Dosya | Sorumluluk |
| :--- | :--- |
| `lib/rubik/ui.rb` | namespace + `Runtime::RenderService` kaydı |
| `lib/rubik/ui/capability.rb` | TTY/renk/VT saptama; `NO_COLOR`, `CLICOLOR_FORCE`, `RUBIK_TEST`, `TERM=dumb`; Windows Fiddle VT |
| `lib/rubik/ui/theme.rb` | Pastel singleton; Rubik paleti; `unicode`/`ascii` glif seti; spinner fiilleri |
| `lib/rubik/ui/renderer.rb` | `on_step` olayı → `⏺/⎿` ağaç dili (StepFormatter üstü dekoratör) |
| `lib/rubik/ui/spinner.rb` | tty-spinner yaşam döngüsü + geçen süre + ctx ters işlemi |
| `lib/rubik/ui/markdown_stream.rb` | satır odaklı canlı markdown; tty-markdown batch temsilcisi |
| `lib/rubik/ui/statusline.rb` | prompt üstü durum şablonu (`ui.statusline.template`) |
| `lib/rubik/ui/banner.rb` | açılış banner'ı (tty-box) |
| `lib/rubik/ui/approvals.rb` | hızlı onay kartı + adaptif sandbox + tuş kısayolları |
| `lib/rubik/ui/panel.rb` | `!agents` etkileşimli panosu + detay görünümü |
| `lib/rubik/ui/diff_viewer.rb` | renkli, sayfalanan `!diff` görüntüleyici |

Palet (ANSI 256): vurgu `196/203` (Rubik kırmızısı), ikincil `240` (dim gri), başarı `42`, hata `196`, uyarı `214`, bilgi `80`, düşünce `245 italik`. Tema `ui.theme: rubik` altında izole; yeni temalar yalnız palet dosyası.

### 4.3. Yapılandırma Yüzeyi

```yaml
ui:
  color: auto          # auto | always | never
  theme: rubik         # marka paleti
  glyphs: unicode      # unicode | ascii  (eski conhost fallback)
  banner: true
  spinner: true
  spinner_verbs: [Düşünüyor, Kavuruyor, Damıtıyor, ...]   # yoksa varsayılan
  markdown: live       # live | off
  statusline: true
  statusline.template: "{model} · ctx %{ctx} · {dirty} ✎ · {sandbox}"
  input_box: false     # Faz E bayrağı (Reline çok satırlı prompt kutusu)
```

CLI: `rubik --no-color`; ortam: `NO_COLOR`, `CLICOLOR_FORCE`. Dokümantasyon: `CONFIG.md`'ye `ui.*` şeması, `COMMANDS.md`'ye `!theme`, `!statusline` komutları.

---

## ⚙️ 5. Uygulama Adıları (Fazlar)

> Her faz **bağımsız shippable**; faz sonunda tüm test paketi %100 yeşil olmalıdır. Sembol düzenlemeleri öncesi GitNexus `impact` (yüksek riskliler: `Shell#execute_free_text`, `StepFormatter#format_tool_call`, `TeeIO#write`, `Confirmations#ask_yes_no`), commit öncesi `detect_changes()`.

### Faz A — Temel: Renk altyapısı, ANSI hijyeni, banner, statusline *(Kolay–Orta)*

1. `rubik.gemspec`: `pastel`, `tty-screen`, `tty-box`, `strings-ansi` çalışma zamanı bağımlılıkları; `bundle install`.
2. `ui/capability.rb` + `ui/theme.rb`: saptama matrisi (TTY/`NO_COLOR`/`CLICOLOR_FORCE`/`TERM=dumb`/`RUBIK_TEST`/`ui.color`), Windows VT etkinleştirme, palet + glif setleri.
3. `TeeIO`: StringIO hedeflerine yazım öncesi ANSI strip (`strings-ansi`).
4. `config.rb`: `DEFAULT_CONFIG["ui"]` bloğu + şema doğrulama; `bin/rubik`'e `--no-color`.
5. `ui/banner.rb`: açılışta sürüm + model + cwd + dirty durumu (tty-box; pipe modunda tek satır düz metin veya yok).
6. `ui/statusline.rb` + `Shell#read_and_process_line`: prompt üstü durum satırı (model, tahmini bağlam yüzdesi — `Prompt::TokenEstimator`, dirty sayısı, sandbox, adım N/M ajan çalışırken).
7. `Shell#prompt`: pastel ile segment renklendirme.
8. Test: `test_ui_capability.rb`, `test_ui_theme.rb`, `test_teeio_ansi_strip.rb` (kayıt dosyalarında `/\e\[/` negatif testi). Dokümantasyon: `CONFIG.md`.

### Faz B — Ajan Akışı: `⏺/⎿` ağaç dili + canlı spinner + markdown *(Orta)*

1. `ui/renderer.rb`: 13 olay tipinin yeni görsel dile eşlenmesi; verbosity matrisi korunur (quiet=hiçbir şey; normal=daraltılmış; verbose=önizleme; debug=ham satır `[DEBUG:...]`).
2. `ui/spinner.rb`: `:thinking` → başlat; `:chunk`/`:tool_call`/`:finish` → durdur+temizle; geçen süre saniyesi; fiil döngüsü `theme`'den; ctx `on_dispose` kaydı.
3. `ui/markdown_stream.rb`: satır odaklı canlı render; batch modda `tty-markdown` (`tty-markdown` + `tty-spinner` bu fazda gemspec'e eklenir).
4. `orchestrator/loop.rb` (yalnız meta): `:tool_result` payload'ına `tokens` ve isteğe bağlı `files_touched` eklenir — davranış değişikliği yok.
5. `Shell#execute_free_text`: `on_step` lambdasının yeni renderer'a devri; spinner ile stream yarışına mutex.
6. Test: `test_ui_renderer.rb` (4 verbosity × olay matrisi), `test_ui_spinner.rb` (yaşam döngüsü + 500 dispose sonrası canlı thread kalmaz), `test_ui_markdown_stream.rb`; `test_verbosity_and_step_formatter.rb` ve `test_repl_stream.rb` görsel metin güncellemeleri. Dokümantasyon: `COMMANDS.md` (`!verbosity` örnekleri).

### Faz C — Onay Akışları: hızlı onay + adaptif sandbox *(Orta)*

1. `ui/approvals.rb`: `tty-prompt` keypress tabanlı `y/n/d/e` akışı; onay kartı tty-box ile prompt üzerinde.
2. **Adaptif sandbox:** soru metni ve seçenekler `sandbox.allow_network` durumuna göre üretilir (Antigravity eşdeğeri); tek seferlik ağ izni mevcut `!config` altyapısını kullanır.
3. `confirmations.rb`: `ask_yes_no` API'si korunur, içi `UI::Approvals`'a delege eder (çağrı yerleri — max-steps continue, kritik dosya onayı — değişmez).
4. Etkileşimsiz mod: mevcut kısa devre davranışı aynen (varsayılan cevap, kart yok).
5. Test: `test_ui_approvals.rb`; `test_shell_ask_yes_no.rb` güncellemesi.

### Faz D — Paneller: `!agents`, diff görüntüleyici, oturum seçici, tablolar *(Orta–Zor)*

1. `ui/panel.rb`: `!agents` panosu — `Runtime::Manager#fibers` verisinden durum listesi; tty-prompt select; detay görünümünde adım geçmişi + Ω derinliği + bekleyen onaylar. `!fibers` düz liste olarak kalır (pipe/CI uyumu).
2. `ui/diff_viewer.rb`: `!diff` renkli ± satırlar, sayfalama (`u`/`d`), `a` uygula, `u undo` yönlendirmesi, `esc` çıkış; pipe modunda bugünkü düz diff.
3. `!session resume` etkileşimli seçici; `!providers`/`!lsp`/`!sessions` çıktıları `tty-table`'a taşınır (pipe modunda düz hizalı metin fallback).
4. Test: `test_ui_panel.rb`, `test_ui_diff_viewer.rb`; `tty-prompt` gemspec'e eklenir.

### Faz E — Cila: kutulu girdi alanı *(Opsiyonel, `ui.input_box: true`)*

1. Reline çok satırlı prompt ile üst çerçeve + sol ray; Enter sonrası alt çerçeve; kirli tampon `[DIRTY]` rozetinin çerçeveye taşınması.
2. Sağ ray canlı güncellenemez sınırının ve gelecekteki tam ekran modu seçeneklerinin (tty-reader / Charm Ruby) `README.md`'de belgelenmesi.
3. `tty-table` dışındaki kalan gem bağımlılıklarının gözden geçirilip kullanılmayanların çıkarılması.

---

## 🧪 6. Test ve Kalite Güvencesi

1. **Deterministiklik:** `RUBIK_TEST=1` ve pipe modunda çıktıda ANSI kodu **sıfır** (negatif regex testi tüm yeni test dosyalarında).
2. **Görsel matris:** `test_ui_renderer.rb` — 4 verbosity × 13 olay tipi; beklenti dizeleri çift set (TTY kapalı düz / TTY açık strip-edilmiş karşılaştırma).
3. **Sızıntı:** `test_ui_spinner.rb` — 500 başlat/durdur + dispose sonrası `Thread.list` temiz; `AGENTS.md` "Zero-Restart Reloading" kontrol listesi maddesi.
4. **Hijyen:** `test_teeio_ansi_strip.rb` — renkli komut çıktısı TeeIO'dan geçtikten sonra kayıt string'inde `/\e\[/` yok.
5. **Mevcut paket:** 513+ test görsel metin güncellemeleri dışında %100 yeşil; semantik davranış (verbosity matrisi, double-print guard, interrupt kurtarma) aynen.
6. **Kabul senaryosu (elle):** Windows Terminal, Git Bash ve düz `cmd` conhost'ta; ayrıca `echo "..." | ruby bin/rubik` pipe modunda renk/yazı bozulması yok.

## ⚠️ 7. Riskler ve Önlemler

| Risk | Önlem |
| :--- | :--- |
| Windows conhost VT desteği | Fiddle ile VT etkinleştirme; rescue → renk kapalı + `glyphs: ascii`; Windows Terminal birincil hedef |
| Spinner thread ↔ stream yarışı | Tek mutex; her çıktı öncesi spinner durdurma sözleşmesi; dispose ters işlemi |
| ANSI sızması kayıtlara/LLM bağlamına | TeeIO StringIO-strip + negatif testler (§6.4) |
| Reline çok satırlı prompt kenar durumları | Faz E'yi feature flag arkasına koymak; Ana akım (Faz A prompt) tek satır kalır |
| `tty-markdown`/kramdown bağımlılık ağırlığı (~8 gem) | Yalnız batch/tam belge yolunda kullanım; canlı akış hafif satır render'ı |
| Test görselleri kırılması | Tek PR'da güncelleme; semantik matris testleri korunur; faz bağımsız shippable |
| Backwards uyumluluk (`!fibers`, `!diff` script kullanıcıları) | Yeni etkileşimli yüzeyler ayrı komut/bayrak; eski düz çıktı pipe modunda yaşar |

## 📊 8. Uygulama Kontrol Listesi

- [x] **Adım A1:** Gemspec bağımlılıkları + `ui/capability.rb` + `ui/theme.rb` + TeeIO ANSI strip + `ui.*` config şeması.
- [x] **Adım A2:** Banner, statusline, renkli prompt; `test_ui_*` birim testleri; `CONFIG.md`.
- [x] **Adım B1:** `ui/renderer.rb` (`⏺/⎿` dili) + mevcut görsel test güncellemeleri.
- [x] **Adım B2:** `ui/spinner.rb` (ctx-bağlı ömür) + `ui/markdown_stream.rb`; `COMMANDS.md`.
- [x] **Adım C:** `ui/approvals.rb` hızlı onay + adaptif sandbox; `ask_yes_no` delegasyonu.
- [x] **Adım D:** `ui/panel.rb` (`!agents`), `ui/diff_viewer.rb`, oturum seçici, tty-table geçişi *(bkz. Sapma D-4)*.
- [x] **Adım E:** `ui.input_box` kutulu girdi; bağımlılık gözden geçirmesi *(bkz. Sapma D-1)*.
- [x] **Kapanış:** `README.md` özellik listesi; tüm testler `bundle exec rake test` ile **%100 yeşil (603 runs · 3211 assertions · 0 failure/error)**, Rubocop yeni dosyalarda 0 ihlal.

---

## 🔧 9. Uygulama Sapmaları (Plan → Kod)

Uygulama sırasında ortaya çıkan gerçekler ve buna göre plana işlenen sapmalar:

| # | Sapma | Gerekçe |
| :-- | :--- | :--- |
| **D-1** | **`tty-box` ve `tty-screen` gem'leri çıkarıldı.** Kutular ~30 satırlık `UI::Frame` (tema glifleriyle) tarafından, terminal genişliği ise stdlib `io/console` (`IO.console.winsize`) tarafından sağlanıyor. | tty-box 0.7'nin yuvarlak köşe desteği yok (`border:` yalnızca ön ayar rol sembolleri kabul ediyor, değişmez karakter değil) ve `tty-screen` gereksiz bağımlılık. |
| **D-2** | **`tty-table` eklenmedi.** `!providers`/`!lsp`/`!session` listeleri mevcut hizalı düz çıktılarında bırakıldı. | Mevcut çıktılar zaten hizalı; tablo göçüşü 3+ komut testinde görsel kırılım yaratıp hiçbir kullanıcı değeri eklemiyor. Etkileşimli tablolar gelecekteki tam ekran moduna (Faz E notu) bırakıldı. |
| **D-3** | **`tty-spinner ~> 0.9`** (plan `~> 0.17` yazmıştı; böyle bir sürüm yok). 0.9 API'si farklı: `update(tokens)`, çıktı yalnız TTY'ye yazılır ve varsayılan çıktı `$stderr`. | Sarmalayıcı (`UI::Spinner`) açık `output:` iletir, geçen süreyi kendi thread'inde token olarak besler. |
| **D-4** | **`StepFormatter` hiç değiştirilmedi** (testleri aynen yeşil). `UI::Renderer` debug seviyesinde ona delege eder; kararlı olay gövdeleri (uyarı/retry/finish) aynen korunup yalnız iki boşlukla ağaca ankrajlanır ve renklenir. | Tek görsel dil korunurken mevcut 20+ birim test kırılmadı; yalnız 1 Shell-seviyeli görsel test güncellendi. |
| **D-5** | **`orchestrator/loop.rb` dokunulmadı.** Planın öngördüğü `:tool_result` `tokens` meta'sı zaten mevcuttu. | Keşif teyidi; davranış değişikliği gerekmedi. |
| **D-6** | **Adaptif sandbox onayı API olarak geldi (`UI::Approvals.confirm_action`), interaktif bir gate'e bağlanmadı.** Kod tabanında mevcut interaktif sandbox onay akışı yoktu (Guard otomatik bloklıyor). Mevcut iki onay noktası (`!plan` onayı, adım bütçesi devamları) tek tuş `keypress_yes_no`'ya yükseltildi. | API + birim testleri hazır; ilk gerçek gate (ör. kritik dosya yazımı) geldiğinde tek satır bağlanacak. |
| **D-7** | **Yeni `lib/rubik/repl/presentation.rb` modülü** (Confirmations kalıbında mixin) ve `prompt`/`detect_git_branch` de bu modüle taşındı. | `test_repl_command_decoupling` shell.rb'yi 600 satır altında zorunlu tutuyor; sunum yardımcıları oraya ait. |
| **D-8** | **`ui.theme` config anahtarı eklenmedi** (palet tek yerleşik `rubik`); `spinner_verbs`, `input_box` eklendi. | Ölü config anahtarı üretmemek için tema anahtarı çoklu palet geldiğinde eklenecek. |
| **D-9** | **Statusline/banner/spinner yalnız interaktif TTY'de**; `RUBIK_TEST=1` tüm diğer sinyallerin üzerinde **kesin kapama** anahtarı olarak kademelendirildi (`NO_COLOR` ve `ui.color`'dan önce). | Test determinizmi ve CI çıktı garantisi; `CLICOLOR_FORCE=1` yine `RUBIK_TEST` hariç her şeyi ezer. |
| **D-10** | **Kod incelemesi düzeltmeleri (3 paralel inceleyici):** ① `UI::Capability.interactive?`/`unwrap_tee` tek kanonik interaktivite sorgusu — `!agents`/`!diff`/oturum seçicinin komut TeeIO'su altında erişilemez kalması düzeltildi; ② `Runtime::Context#provide` artık anahtar başına tek silme-ters işlemi kaydediyor (Ω akümülatörü `refresh_ui!`/tur başına `llm` sağlamalarıyla sınırsız büyümüyordu — her ikisi de kapatıldı); ③ `RenderService` kill-ters işlemi tek kez kaydedilir ve dispose anındaki güncel renderer'ı çözer; ④ `refresh_ui!` geçici komut TeeIO'su yerine **gerçek** terminale bağlanır ve kaydı `RenderService`'e delege eder; ⑤ `!verbose`/`!verbosity` artık display katmanını canlı yeniden inşa ediyor; ⑥ Spinner `":spinner :msg"` şablonu + `clear: true` ile mesajı gerçekten basıyor ve durduğunda artık glif satırı bırakmıyor; ⑦ `Theme.for` çıktı kodlaması `⏺`'ı kodlayamıyorsa (Windows cp1254/cp857 boru) otomatik ascii glif setine düşer; ⑧ `Frame` üst kenarlığındaki bir kolon kayması düzeltildi ve `top_border`/`bottom_border` ortak yardımcıları kutulu prompt ile paylaşıldı; ⑨ Renderer'ın StepFormatter'ı yeniden uygulayan özel metotları silindi — semantik (`thinking_parts`, `primary_arg_value`, `thought_first_line`) StepFormatter'ın public API'sinden tüketiliyor (D2 sözleşmesi gerçek oldu); ⑩ ölü sabitler (`YES_WORDS`, `NO_WORDS`, `PLACEHOLDERS`) kaldırıldı. | Üç inceleyicinin P1 bulguları; her düzeltmeye regresyon testi eklendi (Ω sınırlılığı, canlı dispose-kill, TeeIO unwrap, çerçeve genişlik eşitliği). |
| **D-11** | **Kırmızı-takım (self-diff) denetimi bulguları:** ① `ui.input_box: true` Array prompt Reline 0.6'da `String#gsub` nedeniyle readline'ı çökertiyordu — üst çerçeve artık readline'dan ÖNCE ayrı düz satır (`prepare_prompt_line`) basılıyor, prompt daima tek String (sol raylı); ② `DiffViewer#offer_actions` ham `#gets` kullanıyordu (Windows'ta Reline wedge anti-pattern'i) → tty-prompt keypress; ③ `!plan`/`!goal` LLM bekleme ortasında ölürse spinner thread'i sonsuza dek dönüyordu → `execute_command` ensure'ında garanti kill (StandardError bilinçli olarak yine dışarı yayılıyor — geçmiş davranış); ④ Interrupt'ta canlı markdown kuyruğundaki yarım satır kayboluyordu → `execute_free_text` ensure'ında `md_stream.finish`; ⑤ `Frame.truncate_plain` uzun içerikte çerçeve genişliğini bozuyordu (max+1) ve ascii sette bile unicode `…` basıyordu → temadan `ellipsis` glifi (`…`/`...`) ile tam `max` genişliğe kesim + taşma testleri; ⑥ oturum seçicide Ctrl+C yanlışlıkla en son oturuma resume ediyordu → `:picker_cancelled` sentinel'i ile gerçek iptal; ⑦ `refresh_ui!` pipe modunda TeeIO fallback'ini ilk hedefe bağlıyor; ⑧ DiffViewer'daki ölü `filename:` parametresi kaldırıldı. Ayrıca `rubocop -A`'nın shell.rb'de istemeden dokunduğu önceden-var kod (`ENV["HOME"]`→`Dir.home`, rescue-modifier yeniden yazımları vb.) geri alındı: shell.rb HEAD içeriğine sıfırlanıp yalnız plan kapsamındaki değişiklikler yeniden uygulandı — diff'te ilgisiz hunk kalmadı. | Adversarial self-review; her düzeltmeye regresyon testi (çerçeve taşma uniformitesi, ascii ellipsis, box-prompt String sözleşmesi, komut sonu spinner kill). |
