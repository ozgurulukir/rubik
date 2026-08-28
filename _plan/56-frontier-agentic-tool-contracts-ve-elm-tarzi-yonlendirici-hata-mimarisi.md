# 56 — Frontier LLM Beklentileriyle Uyumlu Araç Kontratları, Elm Tarzı Yönlendirici Hata Mimarisi ve Hedefli Düzenleme (replace_file_content)

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Onaylandı (Review Tamamlandı)** · **Zorluk:** Orta · **Faz:** 6 (Ajan Ergonomisi & Araç Kalitesi)  
> **İlgili Planlar:** [10](10-ajan-dongusu-ve-arac-entegrasyonu.md), [16](16-genisletilmis-arac-seti-ve-planlama.md), [17](17-yerel-arac-cagrilari-ve-router.md), [20](20-spatiotemporal-runtime-context-ve-fiber-yasam-dongusu.md), [24](24-kendi-kendini-gelistiren-arac-sentezi.md), [32](32-agentic-tool-cagrilari-yapilandirilmis-io-ve-akilli-baglam-kirpma.md), [36](36-repl-komut-ve-yerel-arac-ayrimi-ve-ajan-yonlendirme-guardrail.md), [44](44-llm-egitim-uyumlu-arac-isimlendirmesi-grep-ve-tool-aliasing.md), [45](45-spatiotemporal-oz-evrilen-calisma-zamani-ve-otonom-adaptor-sentezi.md), [52](52-yerlesik-arac-hizlandirma-native-offload-ve-lazy-hash.md), [54](54-step-executor-ve-arac-alani-moduler-refaktoru.md), [55](55-run-command-platform-kapili-kabuk-secimi.md)  
> **Kapsam:** `rubik.gemspec`, `lib/rubik/tools/diagnostic_reporter.rb` (yeni), `lib/rubik/tools/fuzzy_matcher.rb` (yeni), `lib/rubik/tools/builtins/replace_file_content.rb` (yeni), `lib/rubik/tools/builtins/files.rb`, `lib/rubik/tools/builtins/symbols.rb`, `lib/rubik/tools/builtins/exec.rb`, `lib/rubik/orchestrator/step_executor.rb`, `lib/rubik/tools/registry.rb`, `lib/rubik/prompt/context_builder.rb`, `COMMANDS.md`, `CONFIG.md`

---

## 🎯 1. Hedef ve Gerekçe

Frontier seviyesindeki kodlama modelleri (**Claude 3.7 / 3.5 Sonnet**, **GPT-4o**, **OpenAI o1 / o3-mini**, **DeepSeek-Coder-V3 / R1**, **Qwen 2.5 Coder**); araç çağırma (tool calling) mekanizmalarında katı tip şemaları, hedefli küçük parça düzenlemeleri (targeted chunk edits), otonom araç sentezleme farkındalığı ve hata anında karşılaştıkları geri bildirimlerin açıklayıcılığı ile en yüksek ilk-deneme başarı oranına (first-attempt pass rate) ulaşır.

Mevcut Rubik araç mimarisinde dört kritik sürtünme noktası bulunmaktadır:
1. **Yalnızca Tam Dosya Yazma (`write_file` Zorunluluğu):** 1000 satırlık bir dosyada 2 satırlık bir değişiklik için tüm dosyanın baştan yazılması gerekmektedir. Bu durum hem yüzlerce çıktı token'ını israf etmekte, hem modelin dosyanın geri kalanını halüsinasyonla bozma riskini artırmakta, hem de diff takibini zorlaştırmaktadır.
2. **Kuru ve Yönlendirmesiz Hata Mesajları:** Bir dosya veya araç bulunamadığında araçlar yalnızca `"File not found: foo.rb"` veya `"Error: Tool 'foo' does not exist"` gibi düz ve yönlendirmesiz yanıtlar döndürmektedir. Model ne yapacağını bilemeyip 2-3 adım boyunca deneme-yanılma ile token tüketmektedir.
3. **Elm Derleyicisi Tarzı Empatik Geri Bildirim Eksikliği:** Elm derleyicisinin efsanevi *"Hata mesajı bir engel değil, yol gösteren bir çift programcıdır"* felsefesi; sorunun ne olduğunu, mevcut durumu, en yakın adayları ("Did you mean...?") ve modelin atması gereken somut sonraki adımı tek bir adımda modele vermelidir.
4. **Otonom Araç Sentezi Farkındalığının Eksikliği:** Rubik'in `synthesize_tool` ve `synthesize_command` ile çalışma zamanında dinamik araç üretme süper-gücü bulunmasına rağmen, sistem istemi (`<operational_rules>`) ve hata yönlendirmeleri modele bu yeteneği açıkça hatırlatmamaktadır. Model ihtiyaç duyduğu özel bir araç olmadığında (örn. özel bir AST transformer, veri dönüştürücü veya benchmark aracı) çaresiz kalmak yerine kendi aracını sentezleyebileceğini bilmelidir (`AGENTS.md` §3).

Bu plan; **`replace_file_content` (hedefli kod düzenleme)** aracını ekleyerek, **Elm tarzı `DiagnosticReporter` & `FuzzyMatcher`** motorunu kurarak, **otonom araç sentezi farkındalığını** sistem geneline yayarak ve tüm araç kontratlarını frontier modellerin eğitim ağırlıklarıyla kusursuz hizalayarak ajanımızı endüstri standardı bir kodlama harness'ına dönüştürür.

---

## 💎 2. Gem ve Kütüphane Stratejisi (Tekerleği Yeniden İcat Etmeme)

Sistem mimarisinde gereksiz tekerlek icadını önlemek ve sektör standardı, test edilmiş algoritmaları kullanmak adına şu kütüphaneler tercih edilmiştir:

1. **Fuzzy String Matching & Spell Checking: `did_you_mean` (Ruby Standard Library)**
   - Ruby 3.3+ çekirdeğinde yerleşik olarak bulunan `DidYouMean::SpellChecker` ve `DidYouMean::Levenshtein` motoru kullanılır.
   - Dosya adları, sembol isimleri, araç adları ve REPL komutları için C düzeyinde optimize edilmiş, sıfır maliyetli ve güvenli "Did you mean?" önerileri sağlar.
2. **Hassas Diff, Eşleşme Hizalama & Patch: `diff-lcs` (`~> 1.5`)**
   - Ruby ekosisteminin altın standardı olan `diff-lcs` gem'i runtime bağımlılığı olarak eklenir.
   - `replace_file_content` aracında hedef metin ile dosya içeriği arasındaki satır bazlı Longest Common Subsequence (LCS) analizi, en yakın eşleşme tespiti (closest snippet alignment) ve atomik diff üretimi için kullanılır.
3. **Zengin Görsel & Terminal Stili: `pastel` (Mevcut Dependency)**
   - REPL konsolunda renkli ve dikkat çekici Elm tarzı hata kutuları çizilirken, LLM'e iletilen çıktıda temiz ve ayrıştırılabilir ASCII/Markdown yapısı korunur.

---

## 🛠️ 3. Frontier Model Araç Yetenek Matrisi (Tool Capabilities Matrix)

Rubik'in 6 temel alandaki 22 aracı, frontier kodlama LLM'lerinin (Anthropic Claude 3.7 Sonnet Coding Harness, OpenAI Function Calling, DeepSeek Agent Protocol) beklentileriyle tam uyumlu hale getirilir:

| Kategori | Araç Adı & Alias'lar | Frontier LLM Görevi & Yeteneği | Hata & Rehberlik Formatı |
| :--- | :--- | :--- | :--- |
| **Dosya & Düzenleme** | `read_file` (`view_file`, `read`) | 1-based satır numaralı paged okuma (`offset`, `limit`). | `-- FILE NOT FOUND --` (yakın dosya listesi & `write_file` önerisi). |
| | `replace_file_content` (`edit_file`, `str_replace`, `patch_file`, `edit_chunk`) | **[YENİ]** Cerrahi/hedefli blok değiştirme (`target_content` ➔ `replacement_content`, `start_line`, `end_line`, `allow_multiple`). | `-- TARGET NOT FOUND / NOT UNIQUE --` (`Diff::LCS` ile en yakın parça ve satır aralığı). |
| | `write_file` (`create_file`, `save_file`, `overwrite_file`) | Yeni dosya oluşturma veya tüm dosyayı baştan yazma. | BufferManager in-memory yazma & dirty tracking. |
| | `list_files` (`list_directory`, `ls`) | Dizin/uzantı filtreli dosya ağacı listeleme. | `-- DIRECTORY NOT FOUND --` (yakın dizin önerisi). |
| | `grep_search` (`search_code`, `grep`) | Hızlı Regex/metin arama (ripgrep native offload + memory dirty buffer taraması). | Eşleşme yoksa alternatif query ve path önerisi. |
| **AST & Semantik** | `search_symbols` (`find_symbols`) | AST grafında sembol, fonksiyon, sınıf ve çağrı hiyerarşisi arama. | `-- SYMBOL NOT FOUND --` (`DidYouMean` ile en yakın semboller). |
| | `get_symbol` (`symbol_info`, `get_definition`) | Fonksiyon/sınıf gövdesini ve imzasını dosyayı okumadan izole çekme. | Sembol bulunamazsa benzer sembol önerisi. |
| | `get_outline` (`file_outline`, `outline`) | Dosyanın anlamsal iskeletini (metot ve satır aralıkları) çıkarma. | Dosya/AST bulunamazsa `read_file` önerisi. |
| | `find_references` (`references`, `get_callers`) | Güvenli refaktör için tüm çağıranları (callers) bulma. | Çağıran yoksa `grep_search` alternatif önerisi. |
| **LSP & Tanılama** | `lsp_diagnostics` (`diagnostics`) | Canlı derleyici/linter hata ve uyarılarını sorgulama. | LSP kapalıysa `!lsp on` veya `repair_runtime_service` önerisi. |
| | `lsp_hover` (`hover`) | Tip imzası ve docstring sorgulama. | Konum geçersizse satır/sütun düzeltme rehberi. |
| | `lsp_definition` (`definition`) | Tip-güvenli tanıma sıçrama (jump to definition). | Konum bulunamazsa `search_symbols` önerisi. |
| **Çalıştırma & Test** | `run_tests` (`test`) | Otomatik dil adaptörüyle test paketini çalıştırma. | Hata durumunda test çıktısı ve adaptör tamiri önerisi. |
| | `run_command` (`bash`, `sh`, `cmd`) | Platform-kapılı güvenli sandbox kabuk komutu çalıştırma. | Hata durumunda exit kodu, stderr ve platform ipucu. |
| **Öz-Evrim & Sentez** | `synthesize_tool` (`create_tool`) | **Otonom Araç Üretimi:** LLM'in kendi ihtiyaç duyduğu yeni bir fonksiyon çağırma aracını canlı çalışma zamanına enjekte etmesi (`AGENTS.md` §3). | Kod syntax hatası veya sandbox doğrulama hatası varsa anında düzeltme ipucu. |
| | `synthesize_command` (`create_command`) | Çalışma zamanında yeni REPL bang komutu sentezleme. | Scope ve handler sözleşmesi rehberi. |
| | `repair_runtime_service` (`repair_runtime`) | Bozulan LSP/Test/Linter servisini izole sub-context'te (`ctx.extend()`) deneyip hot-swap yapma. | Aday binary listesi ve probing kılavuzu. |
| | `provide_service` / `inspect_runtime` | Coeffect servisi sağlama ve Fiber/coeffect durumunu denetleme. | Bağımlılık DAG durum raporu. |
| **Yaşam Döngüsü** | `apply_buffer` (`save`) | Bellekteki değişiklikleri diske kalıcı yazma. | Temiz/kirli durum özeti. |
| | `exec_repl_command` (`repl`) | `<agent_commands>` içindeki oturum-güvenli komutları çalıştırma. | Bilinmeyen komutta direct native tool yönlendirmesi. |
| | `finish` (`done`) | Nihai özet ile görevi tamamlama sinyali. | Tamamlandı durum raporu. |

---

## 🔍 4. Elm Derleyicisi Felsefesi ve Örnek Hata Karşılaştırmaları

### A. Dosya Bulunamadı Senaryosu
- **Eski Davranış:**
  ```text
  File not found: lib/rubik/tool/files.rb
  ```
- **Elm Tarzı Yeni Davranış (`DiagnosticReporter` & `DidYouMean`):**
  ```text
  -- FILE NOT FOUND ----------------------------------------------------
  I cannot find the file `lib/rubik/tool/files.rb` in the project workspace.

  Did you mean this?
      • lib/rubik/tools/files.rb

  Existing files in `lib/rubik/tools/`:
      • lib/rubik/tools/base.rb
      • lib/rubik/tools/registry.rb
      • lib/rubik/tools/result.rb

  Actionable Next Steps:
    1. If you meant an existing file, call `read_file(path: 'lib/rubik/tools/files.rb')`.
    2. If you want to create a new file, call `write_file(path: 'lib/rubik/tool/files.rb', content: '...')`.
    3. To explore directory contents, call `list_files(path: 'lib/rubik')`.
  ```

### B. Hedefli Kod Düzenleme (`replace_file_content`) Hedef Bulunamadı Senaryosu
- **Elm Tarzı Geri Bildirim (`Diff::LCS` ile En Yakın Parça Hizalama):**
  ```text
  -- TARGET CONTENT NOT FOUND ------------------------------------------
  I could not find the exact `target_content` in `lib/rubik/config.rb` within lines 10..35.

  Target content requested:
    "def max_retries\n  3\nend"

  Closest matching snippet found at lines 15..17 (82% similarity):
    "def max_retry_attempts\n  3\nend"

  Actionable Next Steps:
    1. Call `read_file(path: 'lib/rubik/config.rb', offset: 10, limit: 30)` to inspect exact indentation and line contents.
    2. Re-run `replace_file_content` with the exact matching lines.
  ```

### C. Hedefli Kod Düzenleme (`replace_file_content`) Çoklu Eşleşme (Ambiguous) Senaryosu
- **Elm Tarzı Geri Bildirim (Uniqueness Invariant):**
  ```text
  -- TARGET CONTENT NOT UNIQUE -----------------------------------------
  The specified `target_content` was found 3 times in `lib/rubik/config.rb` at lines: 12, 45, 88.

  Target content:
    "end"

  Actionable Next Steps:
    1. Provide more surrounding context lines in `target_content` to make the match unique.
    2. Or restrict the search range by specifying `start_line` and `end_line` (e.g. `start_line: 10, end_line: 20`).
    3. If you intentionally want to replace all occurrences across the entire file, pass `allow_multiple: true`.
  ```

### D. Geçersiz / Yanlış Araç Çağrısı ve Araç Sentezi Yönlendirmesi
- **Eski Davranış:**
  ```text
  Error: Tool 'view_file' does not exist. Please check available tools.
  ```
- **Elm Tarzı Yeni Davranış (DidYouMean + Tool Synthesis Gücü):**
  ```text
  -- UNKNOWN TOOL ------------------------------------------------------
  I cannot find an active tool named `view_file`.

  Did you mean one of these?
      • read_file (alias for viewing file content)
      • list_files
      • get_outline

  Available direct tools in toolbelt:
      `read_file`, `replace_file_content`, `write_file`, `list_files`, `grep_search`,
      `search_symbols`, `get_outline`, `find_references`, `get_symbol`, `run_tests`,
      `run_command`, `synthesize_tool`, `synthesize_command`, `repair_runtime_service`,
      `exec_repl_command`, `apply_buffer`, `finish`.

  💡 Need a specialized capability?
      You can dynamically create and register your own custom tool at runtime using:
      `synthesize_tool(name: '...', description: '...', code: '->(args) { ... }')`
  ```

---

## 🏛️ 5. Mimari ve Bileşenler

```
                               ┌─────────────────────────────┐
                               │     Orchestrator::Loop      │
                               └──────────────┬──────────────┘
                                              │
                                              ▼
                               ┌─────────────────────────────┐
                               │  Orchestrator::StepExecutor │
                               └──────────────┬──────────────┘
                                              │
                      ┌───────────────────────┴───────────────────────┐
                      ▼                                               ▼
         [ Native Tool Invocations ]                    [ Invalid / Unknown Tools ]
                      │                                               │
                      ▼                                               ▼
         ┌─────────────────────────┐                     ┌─────────────────────────┐
         │     BaseTool / Tools    │                     │   DiagnosticReporter    │
         └────────────┬────────────┘                     │   (Elm-Style Formatter) │
                      │                                  └────────────┬────────────┘
                      ▼                                               │
         ┌─────────────────────────┐                                  │
         │   DiagnosticReporter    │◄─────────────────────────────────┘
         │   (DidYouMean+DiffLCS)  │
         └────────────┬────────────┘
                      │
                      ▼
         [ Empathetic & Actionable ]
         [ Self-Healing Response   ]
```

---

## 🧩 6. Tasarım Kararları

### D-1: `Rubik::Tools::FuzzyMatcher` (DidYouMean Entegrasyonu)
[`lib/rubik/tools/fuzzy_matcher.rb`](file:///C:/Github/rubik/lib/rubik/tools/fuzzy_matcher.rb):
- Ruby stdlib `did_you_mean` modülünü sarmalayarak `DidYouMean::SpellChecker` ve `DidYouMean::Levenshtein` kullanır.
- `best_matches(query, candidates, limit: 3)`: En benzer adayları döndürür.
- `similarity_ratio(str1, str2)`: Levenshtein mesafesi üzerinden [0.0, 1.0] arası benzerlik puanı hesaplar.
- `find_closest_subsequence(target, lines)`: `Diff::LCS` yardımıyla dosyadaki en yakın satır bloğunu ve satır numaralarını bulur.

### D-2: `Rubik::Tools::DiagnosticReporter` (Elm Formatlayıcı)
[`lib/rubik/tools/diagnostic_reporter.rb`](file:///C:/Github/rubik/lib/rubik/tools/diagnostic_reporter.rb):
- Standart Elm tarzı kutulama (`-- TITLE -----------------`), net problem tanımı, mevcut bağlam ("Context"), en yakın adaylar ("Did you mean?") ve numaralı aksiyon adımları ("Actionable Next Steps").
- Şablonlar:
  - `render_file_not_found(path, candidates: [], existing_dir_files: [])`
  - `render_target_not_found(path, target_content, closest_snippet: nil, closest_range: nil, similarity: nil, start_line: nil, end_line: nil)`
  - `render_target_not_unique(path, target_content, match_count, line_occurrences)`
  - `render_unknown_tool(tool_name, candidate_tools: [], all_tools: [])`
  - `render_symbol_not_found(sym_name, candidate_symbols: [])`
  - `render_command_failed(cmd, exit_code, stderr, suggestions: [])`
- Eksik yeteneklerde **`synthesize_tool`** dinamik araç sentezi ipucunu daima sunar.

### D-3: `Rubik::Tools::ReplaceFileContentTool` (`replace_file_content`)
[`lib/rubik/tools/builtins/replace_file_content.rb`](file:///C:/Github/rubik/lib/rubik/tools/builtins/replace_file_content.rb):
- **İsim:** `replace_file_content` (alias'lar: `edit_file`, `edit_chunk`, `str_replace`, `patch_file`).
- **Parametre Şeması:**
  - `path` (string, zorunlu): Dosya yolu.
  - `target_content` (string, zorunlu): Değiştirilecek mevcut karakter dizisi (boşluk ve girintiler dahil birebir eşleşmelidir).
  - `replacement_content` (string, zorunlu): Yerine konulacak yeni metin.
  - `start_line` (integer, opsiyonel, 1-based): Arama yapılacak başlangıç satırı.
  - `end_line` (integer, opsiyonel, 1-based): Arama yapılacak bitiş satırı.
  - `allow_multiple` (boolean, opsiyonel, default: false): Birden fazla eşleşme varsa hepsini değiştir (false ise ve >1 eşleşme varsa güvenlik gereği hata verir).
- **Benzersizlik Güvencesi (Uniqueness Invariant):**
  - Dosyada `target_content` tam 1 kez geçiyorsa atomik olarak değiştirilir ve buffer güncellenir.
  - 0 kez geçiyorsa `Diff::LCS` destekli `target_not_found` Elm hatası üretilir (en yakın satırlarla birlikte).
  - >1 kez geçiyorsa ve `allow_multiple: false` ise `target_not_unique` Elm hatası üretilir ve modele `start_line`/`end_line` belirterek aralığı daraltması söylenir.
- **Satır Sonu Normalizasyonu:** `\r\n` (CRLF) ve `\n` (LF) uyuşmazlıkları karşılaştırma esnasında normalleştirilir.

### D-4: `ReadFileTool` Sayfalama ve Satır Numaralı Çıktı Standardı
[`lib/rubik/tools/builtins/files.rb`](file:///C:/Github/rubik/lib/rubik/tools/builtins/files.rb):
- `read_file` çıktısı 1-based satır numaralarıyla formatlanır:
  ```text
  1: # frozen_string_literal: true
  2: 
  3: module Rubik
  ```
- Bu format, modelin `replace_file_content` veya `start_line`/`end_line` kullanırken hatasız satır referansı vermesini sağlar.
- `offset` (1-based satır numarası) ve `limit` (satır sayısı) desteği paged okuma kontratını sağlar.

### D-5: `handle_invalid_tool` Akıllı İyileştirme ve Araç Sentezi Çağrısı
[`lib/rubik/orchestrator/step_executor.rb`](file:///C:/Github/rubik/lib/rubik/orchestrator/step_executor.rb):
- Model bilinmeyen veya hatalı bir araç çağırdığında (`StepExecutor#handle_invalid_tool`), hemen ajanı durdurmak yerine `FuzzyMatcher` ile en yakın geçerli aracı ve `synthesize_tool` sentez opsiyonunu önerir; model 1 sonraki adımda hatasını düzeltebilir.
- `StepExecutor#execute_registered_tool`: `replace_file_content` aracını da `write_file` gibi LSP in-buffer diagnostics döngüsüne bağlar.

### D-6: `<operational_rules>` ve Sistem İstemi Güncellemesi
[`lib/rubik/prompt/context_builder.rb`](file:///C:/Github/rubik/lib/rubik/prompt/context_builder.rb):
- `<operational_rules>` içine:
  - Hedefli düzenlemeler için `replace_file_content` (`target_content`, `replacement_content`, isteğe bağlı `start_line`/`end_line`), yeni dosya/baştan yazma için `write_file` kuralı.
  - Özel bir işlev veya kütüphane gerektiğinde `synthesize_tool` ile otonom araç sentezleme kuralı eklenir.

---

## 📋 7. Uygulama Adımları

### Adım 1: Gemfile & gemspec Güncellemesi
- [`rubik.gemspec`](file:///C:/Github/rubik/rubik.gemspec) içine `spec.add_runtime_dependency "diff-lcs", "~> 1.5"` ekle ve `bundle install` çalıştır.

### Adım 2: `Rubik::Tools::FuzzyMatcher` ve `Rubik::Tools::DiagnosticReporter` Modülleri
- [`lib/rubik/tools/fuzzy_matcher.rb`](file:///C:/Github/rubik/lib/rubik/tools/fuzzy_matcher.rb) dosyasını oluştur (`DidYouMean::SpellChecker` & `Levenshtein` sarmalayıcısı).
- [`lib/rubik/tools/diagnostic_reporter.rb`](file:///C:/Github/rubik/lib/rubik/tools/diagnostic_reporter.rb) dosyasını oluştur:
  - `render_file_not_found(path, candidates, existing_dir_files)`
  - `render_target_not_found(path, target_content, closest_snippet, start_line, end_line)`
  - `render_target_not_unique(path, target_content, match_count, line_occurrences)`
  - `render_unknown_tool(tool_name, candidate_tools, all_tools)`
  - `render_symbol_not_found(sym_name, candidate_symbols)`
  - `render_command_failed(cmd, exit_code, stderr, suggestions)`

### Adım 3: `ReplaceFileContentTool` Aracının Geliştirilmesi
- [`lib/rubik/tools/builtins/replace_file_content.rb`](file:///C:/Github/rubik/lib/rubik/tools/builtins/replace_file_content.rb) dosyasını oluştur.
- `BufferManager` ile entegre çalışarak in-memory dosya içeriğini okuyup güncellesin.
- Başarılı düzenlemede kaçıncı satırların değiştiğini ve diff özetini döndürsün.

### Adım 4: Mevcut Dosya ve Sembol Araçlarının Elm Formatına Yükseltilmesi
- [`lib/rubik/tools/builtins/files.rb`](file:///C:/Github/rubik/lib/rubik/tools/builtins/files.rb): `read_file` için satır numarası formatlaması ve `DiagnosticReporter.file_not_found` entegrasyonu. `WriteFileTool` alias'larından `edit_file`'ı kaldırıp `ReplaceFileContentTool`'a devret.
- [`lib/rubik/tools/builtins/symbols.rb`](file:///C:/Github/rubik/lib/rubik/tools/builtins/symbols.rb): `search_symbols`, `get_symbol`, `find_references` için `DiagnosticReporter.symbol_not_found` ve `FuzzyMatcher` entegrasyonu.
- [`lib/rubik/tools/builtins/exec.rb`](file:///C:/Github/rubik/lib/rubik/tools/builtins/exec.rb): `run_command` ve `run_tests` için yapılandırılmış hata önerileri.

### Adım 5: Araç Kayıtçısı (`Registry`), `StepExecutor` ve Sistem İstemi (`Prompt`) Güncellemesi
- [`lib/rubik/tools/registry.rb`](file:///C:/Github/rubik/lib/rubik/tools/registry.rb) ve [`lib/rubik/tools/builtins.rb`](file:///C:/Github/rubik/lib/rubik/tools/builtins.rb) içine `ReplaceFileContentTool`'u varsayılan araç olarak kaydet.
- [`lib/rubik/orchestrator/step_executor.rb`](file:///C:/Github/rubik/lib/rubik/orchestrator/step_executor.rb): `handle_invalid_tool` metodunu `DiagnosticReporter` ile güncelle; `replace_file_content` için LSP in-buffer diagnostics'i bağla.
- [`lib/rubik/prompt/context_builder.rb`](file:///C:/Github/rubik/lib/rubik/prompt/context_builder.rb) içindeki `<operational_rules>` bölümünü `replace_file_content`, hedefli düzenleme ve `synthesize_tool` otonom araç sentezleme kurallarını içerecek şekilde güncelle.

### Adım 6: Birim ve Entegrasyon Testleri
- `test/unit/test_fuzzy_matcher.rb`: `DidYouMean` tabanlı benzerlik ve aday öneri testleri.
- `test/unit/test_diagnostic_reporter.rb`: Elm tarzı hata şablonu ve öneri testleri.
- `test/unit/test_replace_file_content.rb`: Tekil eşleşme, çoklu eşleşme, satır aralığı kısıtı, hata durumu ve buffer entegrasyonu testleri.
- `test/unit/test_tools_elm_diagnostics.rb`: `read_file`, `symbols`, `invalid_tool` Elm hataları entegrasyon testleri.
- `bundle exec rake test`: 522+ testin 0 hata ile geçtiğinin doğrulanması.

### Adım 7: Dokümantasyon Güncellemeleri
- `COMMANDS.md` ve `CONFIG.md` dosyalarına `replace_file_content` aracı, Elm tarzı hata teşhis mimarisi ve otonom araç sentezleme rehberinin eklenmesi.

---

## 🛡️ 8. Risk ve Uç Durum Analizi

| Risk / Uç Durum | Olası Etki | Önleyici Tedbir |
| :--- | :--- | :--- |
| **Satır Sonu Uyuşmazlığı (`\r\n` vs `\n`)** | Windows ortamında modelin gönderdiği `\n` ile dosyadaki `\r\n` eşleşmeyebilir. | `replace_file_content` içerisinde satır sonları karşılaştırma öncesi normalize edilir (`gsub("\r\n", "\n")`). |
| **Benzersiz Olmayan Eşleşme (Ambiguous Target)** | Model kısa bir kelimeyi (örn. `end`) hedeflediğinde yanlış blok değişebilir. | `allow_multiple: false` varsayılandır; birden fazla eşleşmede işlem yapılmaz ve `target_not_unique` hatasıyla satır aralığı istenir. |
| **Büyük Dosyalarda LCS Performansı** | Çok büyük dosyalarda diff hesaplama gecikmeye neden olabilir. | `Diff::LCS` yalnızca arama başarısız olduğunda en yakın satır pencereleri üzerinde çalıştırılır. |

---

## 🎯 9. Kabul Kriterleri

1. `did_you_mean` (Ruby stdlib) ve `diff-lcs` gem'i ile tekerlek yeniden icat edilmeden güvenli, hızlı ve endüstri standardı algoritmalar kullanılmalıdır.
2. `replace_file_content` aracı hem tam eşleşmede hem `start_line`/`end_line` aralığında kusursuz çalışmalıdır.
3. Dosya, sembol veya araç bulunamadığında dönen hata Elm derleyicisi formatında, "Did you mean?" önerili ve somut aksiyon adımlı olmalıdır.
4. Model, sistem isteminde (`<operational_rules>`) ve araç yönlendirmelerinde ihtiyaç duyduğunda `synthesize_tool` ile kendi aracını dinamik olarak üretebileceğini açıkça bilmelidir.
5. `read_file` 1-based satır numaralandırmasıyla modelin hatasız aralık seçmesini sağlamalıdır.
6. Tüm testler (`bundle exec rake test`) 0 failure, 0 error ile %100 yeşil geçmelidir.
