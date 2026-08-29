# 📋 Plan 58: Elm Tarzı Empatik Sistem & İzin Hata Teşhisi, UTF-8 Serileştirme Bağışıklığı ve Hata Toleranslı Dizin Taraması

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** Kolay–Orta · **Faz:** 6 (Gelişmiş Ajan Ergonomisi & Sistem Sağlamlığı)  
> **İlgili Planlar:** [05](05-baglam-motoru-dosya-indeksi.md), [12](12-guvenlik-diff-onay.md), [40](40-coklu-calisma-alani-ve-ek-kok-dizin-erisim-yonetimi.md), [48](48-harici-erisim-izinli-dizinler-ve-sifir-ast-sandbox-guvenlik-kapisi.md), [51](51-display-katmani-hibrit-tui-mimarisi.md), [56](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md), [57](57-sistem-saglamligi-birlesik-tanilama-fuzyonu-e2e-ve-thread-safety.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

Canlı geliştirme oturumlarında (`smart-doc-analyzer` test oturumu) gözlemlenen ve sistem dayanıklılığını doğrudan etkileyen **3 temel sorun ve ihtiyaç**:

### 1.1. `JSON::GeneratorError: source sequence is illegal/malformed utf-8`
- **Gözlem:** Adım biçimlendirme (`StepFormatter`, `Renderer`) veya LLM API isteği hazırlama (`LLM::Client#send_request`, `LLM::Formatter`) sırasında, araç argümanları, komut çıktıları veya LLM stream parçaları içinde bozuk UTF-8 baytları (`invalid byte sequence`) bulunduğunda Ruby'nin C-tabanlı `JSON.generate` ve `JSON.dump` çağrıları `JSON::GeneratorError` fırlatarak adımı çökertmektedir.
- **Kök Neden:** JSON serileştirme öncesinde string ve nesne hiyerarşilerinde derinlemesine UTF-8 temizleme (`.encode("UTF-8", invalid: :replace, undef: :replace)`) sarmalayıcısının eksik olması.

### 1.2. `Errno::EACCES` İzin Hataları ve Çöken Dizin Taramaları
- **Gözlem:** `/tmp` veya izin kısıtlı alt dizinler (`/tmp/systemd-private-...`, `root` sahipli docker klasörleri) çalışma alanında veya sistemde bulunduğunda, `list_files` veya `!context scan` komutları `Errno::EACCES - Permission denied @ dir_initialize` hatası alarak tüm tarama sürecini ve araç yürütümünü durdurmaktadır.
- **Kök Neden:** `Rubik::Context::Scanner#walk_dir` metodundaki `Dir.foreach` çağrısının `rescue SystemCallError` ile korunmaması; izin verilmeyen dizinleri atlamak yerine istisna fırlatarak işlemi kırması.

### 1.3. Elm Derleyicisi Felsefesinin Sistem Hatalarına Genişletilmesi
- **Gözlem:** Dosya/araç bulunamadığında Plan 56 ile devreye aldığımız efsanevi Elm derleyicisi tarzı kutulu, empatik ve yol gösterici format (`DiagnosticReporter`), işletim sistemi izin hataları (`Errno::EACCES`), yol kısıtlamaları (`Path traversal blocked`) ve bağlam durumu sorgularında henüz kullanılmamaktadır.
- **İhtiyaç:** Ajan veya kullanıcı izin/sistem hatasıyla karşılaştığında kuru bir hata mesajı yerine:
  - Ne olduğunu (`-- PERMISSION DENIED -----------------`),
  - Neden kaynaklandığını (`Operating system restricted read permissions for /tmp/...`),
  - Çözüm için atılması gereken somut adımları (`1. Use !allow <path> for scratch directories`, `2. Use list_files(path: 'subfolder')`) tek bir adımda sunmak.

---

## 🏛️ 2. Mimari Tasarım ve Çözüm Bileşenleri

```
                               ┌──────────────────────────────────────────────┐
                               │           Rubik Robustness Engine            │
                               └──────────────────────┬───────────────────────┘
                                                      │
                       ┌──────────────────────────────┼──────────────────────────────┐
                       ▼                              ▼                              ▼
        ┌─────────────────────────────┐┌─────────────────────────────┐┌─────────────────────────────┐
        │  1. UTF-8 Immune JSON Guard ││ 2. Fault-Tolerant Scanner   ││ 3. Elm System Diagnostics   │
        ├─────────────────────────────┤├─────────────────────────────┤├─────────────────────────────┤
        │ • safe_json_generate(obj)   ││ • rescue SystemCallError    ││ • render_permission_denied  │
        │ • safe_json_dump(obj)       ││ • Graceful directory skip   ││ • render_traversal_blocked  │
        │ • clean_utf8_deep(hash/arr) ││ • Non-fatal debug logging   ││ • render_encoding_warning   │
        │ • Zero JSON::GeneratorError ││ • Zero scan abort on EACCES ││ • Actionable Next Steps     │
        └─────────────────────────────┘└─────────────────────────────┘└─────────────────────────────┘
```

---

## ⚙️ 3. Planlanan İyileştirmeler ve Kodlama Adımları

### 3.1. `Rubik::Platform` ve Evrensel Güvenli JSON Serileştirici
[`lib/rubik/platform.rb`](file:///home/aristo/Projects/rubik/lib/rubik/platform.rb)
- `clean_utf8(str)`: String'i `invalid: :replace, undef: :replace, replace: ""` ile temizler.
- `clean_utf8_deep(obj)`: Hash, Array ve String veri yapılarını özyinelemeli olarak UTF-8 güvenli hale getirir.
- `safe_json_generate(obj)` & `safe_json_dump(obj)`: Önce nesneyi temizler, hata durumunda yedek JSON formatlayıcı işletir.
- [`lib/rubik/ui/renderer.rb`](file:///home/aristo/Projects/rubik/lib/rubik/ui/renderer.rb), [`lib/rubik/repl/step_formatter.rb`](file:///home/aristo/Projects/rubik/lib/rubik/repl/step_formatter.rb), [`lib/rubik/llm/client.rb`](file:///home/aristo/Projects/rubik/lib/rubik/llm/client.rb) ve [`lib/rubik/llm/formatter.rb`](file:///home/aristo/Projects/rubik/lib/rubik/llm/formatter.rb) çağrılarının `Platform.safe_json_generate` ile korunması.

### 3.2. `Rubik::Context::Scanner` Hata Toleranslı Tarama
[`lib/rubik/context/scanner.rb`](file:///home/aristo/Projects/rubik/lib/rubik/context/scanner.rb)
- `walk_dir` içinde `Dir.foreach` ve `File.lstat` çağrıları `rescue SystemCallError, StandardError` ile sarmalanır:
  ```ruby
  entries = begin
    Dir.foreach(current).sort - [".", ".."]
  rescue SystemCallError, StandardError => e
    # Okunamayan dizinleri atla, taramayı durdurma
    []
  end
  ```
- `scan_root` içinde kök dizin okuma hataları tolere edilir.

### 3.3. `Rubik::Tools::DiagnosticReporter` Elm Tarzı Sistem Hata Şablonları
[`lib/rubik/tools/diagnostic_reporter.rb`](file:///home/aristo/Projects/rubik/lib/rubik/tools/diagnostic_reporter.rb)
- **`render_permission_denied(path, operation: "read", reason: nil)`:**
  ```text
  -- PERMISSION DENIED -------------------------------------------------
  I cannot access `path` due to operating system permission restrictions (Errno::EACCES).

  Actionable Next Steps:
    1. If this is a scratch or temporary directory, allow it via REPL: `!allow path`
    2. Ensure the process has proper OS read/write permissions for this directory.
    3. Target a specific accessible subfolder using `list_files(path: 'accessible_dir')`.
  ```
- **`render_traversal_blocked(path, allowed_roots: [], allowed_exts: [])`:**
  ```text
  -- PATH ACCESS RESTRICTED (SANDBOX GATE) -----------------------------
  Access to `path` was blocked because it is outside of the configured project workspace.

  Configured Allowed Roots:
      • [PRIMARY] /home/aristo/Projects/smart-doc-analyzer
      • [ALLOWED] /tmp/my_scratch (Zero-AST)

  Actionable Next Steps:
    1. To allow transient I/O and sandbox access to this folder without AST bloat, run:
       `!allow <path>`
    2. To add it as a full workspace root with AST indexing, run:
       `!workspace add <path> [--rw]`
  ```
- **`render_encoding_warning(source, sample_snippet: nil)`**

### 3.4. Araç ve REPL Entegrasyonu
- `ListFilesTool` ve `GrepSearchTool` içinde yakalanan `Errno::EACCES` / `InvalidPathError` hatalarının `DiagnosticReporter.render_permission_denied` ve `render_traversal_blocked` ile dönmesi.
- `!context scan` ve `!context status` REPL komutlarının zengin token dökümü ve Elm tarzı kılavuz sunması.

---

## 🧪 4. Test ve Kalite Güvencesi

Yeni Test Dosyası: [`test/unit/test_elm_system_diagnostics_and_utf8_resilience.rb`](file:///home/aristo/Projects/rubik/test/unit/test_elm_system_diagnostics_and_utf8_resilience.rb)

### Doğrulanacak Senaryolar:
1. **UTF-8 Serileştirme Testi:**
   - Bozuk bayt dizileri içeren (`"\xFF\xFE\xAA"`) hash/array nesnelerinin `safe_json_generate` ile hatasız serileştirilmesi.
   - `Renderer` ve `StepFormatter`'ın bozuk bayt içeren araç argümanlarında `JSON::GeneratorError` fırlatmadan çalışması.
2. **Hata Toleranslı Scanner Testi:**
   - `0000` (okuma izni olmayan) bir alt klasör içeren geçici dizinde `Scanner#scan` çalıştırıldığında çökmeden kalan dosyaların taranması.
3. **Elm Sistem Hata Formatı Testi:**
   - `render_permission_denied` ve `render_traversal_blocked` çıktılarının Elm başlık kutusunu, açıklamasını ve `Actionable Next Steps` adımlarını içermesi.
4. **Genel Regresyon Güvencesi:**
   - Tüm mevcut test süitinin %100 yeşil kalması.

---

## 🏆 5. Denetim ve Uygulama Onayı (Execution Review & Quality Audit)

- **Platform & UTF-8 Bağışıklığı:** `lib/rubik/platform.rb` içindeki `clean_utf8`, `clean_utf8_deep`, `safe_json_generate`, `safe_json_dump` metotları ve fallback mekanizmaları eksiksiz doğrulandı. `Renderer`, `StepFormatter`, `LLM::Client`, `LLM::Formatter`, `TokenEstimator`, `ContextBuilder`, `SessionRecorder` noktaları bozuk bayt dizilerine karşı bağışık hale getirildi.
- **Hata Toleranslı Dizin Taraması:** `lib/rubik/context/scanner.rb` içindeki `walk_dir`, `scan_root`, `scan`, `index_listed` ve `parse_gitignore` metotlarına eklenen `rescue SystemCallError, StandardError` korumaları sayesinde izin kısıtlı dizinlerin taranması sırasında çökme engellendi.
- **Elm Tarzı Sistem Teşhisi:** `lib/rubik/tools/diagnostic_reporter.rb` içindeki `render_permission_denied`, `render_traversal_blocked`, `render_encoding_warning`, `render_context_status_guidance` fonksiyonları oluşturularak `ReadFileTool`, `WriteFileTool`, `ListFilesTool`, `ReplaceFileContentTool`, `GrepSearchTool` ve REPL `!context` komutlarıyla entegre edildi.
- **Modülerlik ve Kod Sağlığı:** `files.rb` dosya boyutu 289 satıra indirilerek 300 satır mimari limiti altında tutuldu (`TestModuleHygiene` %100 yeşil).
- **Test Süiti Doğrulaması:** `test/unit/test_elm_system_diagnostics_and_utf8_resilience.rb` (20 run, 112 assertion) ve tüm test süiti (%100 yeşil) bağımsız olarak doğrulandı.

