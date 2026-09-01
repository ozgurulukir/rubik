# Plan 70 — WriteFileTool Çöp Yol Koruması: 0-Byte Garbage Dosyalarının Önlenmesi

> **Domain:** Tools / Buffer (File I/O Safety)
> **Kaynak:** Rubik ajanı (LLM) `write_file` çağrılarında geçersiz `path` parametreleri (`RubyAdapter.new,`, `0.75,`, `?error,`) gönderdi — bunlar tampona yazıldı ve `!apply` ile diske 0-byte garbage dosyaları olarak yazıldı.
> **Durum:** ✅ **Tamamlandı**
> **Öncül Planlar:** [03](03-dosya-tamponu-snapshot-undo.md) · [48](48-harici-erisim-izinli-dizinler-ve-sifir-ast-sandbox-guvenlik-kapisi.md) · [56](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md) · [60](60-kritik-yol-guvenligi-sandbox-timeout-ve-kod-sagligi.md)

---

## 1. Amaç

LLM ajanının `write_file` aracına geçersiz `path` parametreleri göndermesi durumunda, bu değerlerin tampona yazılmasını ve nihayetinde diske 0-byte garbage dosyaları olarak yazılmasını engellemek.

### Başarı Kriterleri

- [x] `write_file` çağrısı `RubyAdapter.new,` gibi bir path ile yapıldığında hata döndürür, tampona yazılmaz
- [x] `write_file` çağrısı `0.75,` gibi bir path ile yapıldığında hata döndürür, tampona yazılmaz
- [x] `write_file` çağrısı `?error,` gibi bir path ile yapıldığında hata döndürür, tampona yazılmaz
- [x] Geçerli yollar (`lib/app.rb`, `src/main.go`, `Gemfile`, `Dockerfile`, `LICENSE`) normal şekilde çalışır
- [x] `Buffer::Manager#apply!` ikincil güvenlik katmanı olarak garbage path'leri yakalar ve olay yayınlar
- [x] Mevcut tüm testler yeşil kalır
- [x] Yeni testler eklenmiştir

---

## 2. Kök Neden Analizi

### 2.1 Zincir

```
LLM write_file(path="RubyAdapter.new,", content="...")
  → WriteFileTool#execute (NO validation — her string geçer)
    → Buffer::Manager#write (sanitize_path traversal koruması yapar, format kontrolü yapmaz)
      → Buffer::Manager#apply! (hiçbir içerik doğrulaması yapmaz)
        → Platform.atomic_write → 0-byte dosya
```

### 2.2 Üç Zayıf Nokta

| Katman | Sorun |
| :--- | :--- |
| **WriteFileTool#execute** | `path` parametresi için hiçbir format doğrulaması yok. Schema'da `description` alanı eksik — LLM ne tür bir değer beklendiğini bilemez. |
| **WriteFileTool params_schema** | `path: { type: "string" }` — sadece tip belirtilmiş, açıklama yok. LLM path'in bir dosya yolu olması gerektiğini anlamayabilir. |
| **Buffer::Manager#apply!** | Tampon girdilerini diske yazmadan önce hiçbir sağlık kontrolü yapmaz. |

### 2.3 sanitize_path'in Rolü

`Buffer::Manager#sanitize_path` zaten traversal koruması yapar — path proje kökü veya ek kök dizinler altında değilse `InvalidPathError` fırlatır. Ancak:

- `sanitize_path` **çalışma alanı içindeki** garbage path'leri engelleyemez (ör. `src/RubyAdapter.new,` proje kökü altında olduğu için geçer)
- `sanitize_path` çağrısı `write` metodunda yapılır, `apply!`'da yapılmaz — `write` başarılı olursa `apply!` hiç kontrol etmez

---

## 3. Değişiklikler

### 3.0 Yeni Paylaşılan Modül: `Rubik::Buffer::PathValidator`

**Dosya:** `lib/rubik/buffer/path_validator.rb`

İki sınıf arasında doğrulama mantığını kopyalamak yerine tek bir SSOT modülü.

```ruby
# frozen_string_literal: true

module Rubik
  module Buffer
    module PathValidator
      # Uzantısız/noktasız özel dosya adları — path separator veya uzantı olmadan
      # geçerli sayılması gereken dosyalar.
      SPECIAL_FILENAMES = %w[
        Gemfile Rakefile Makefile Dockerfile Procfile
        LICENSE CHANGELOG Vagrantfile Jenkinsfile Justfile
        Berksfile Capfile Guardfile Podfile Appraisals
      ].freeze

      # Geçersiz dosya adı karakterleri — LLM kod fragmanı sızıntısını işaret eder.
      # Not: `,` ve `?` burada da var, ancak contains_invalid_chars? onları açıkça
      # kontrol eder (self-documentation için); chars.any? zaten yakalar.
      INVALID_PATH_CHARS = %w[, ? * " < > |].freeze

      class << self
        # Bir dosya yolunun geçerli olup olmadığını kontrol eder.
        #
        # @param path [String, nil] kontrol edilecek yol
        # @return [Boolean] yol geçerliyse true
        def valid?(path)
          return false if path.nil? || path.to_s.strip.empty?

          cleaned = path.to_s.strip

          # 1. NEGATİF KONTROL: Geçersiz karakterler içeren yolları reddet.
          #    Bu, pozitif kontrollerden ÖNCE çalışır — LLM kod fragmanı sızıntılarını
          #    (sondaki virgül, baştaki soru işareti, vb.) yakalar.
          return false if contains_invalid_chars?(cleaned)

          # 2. Özel dosya adları (uzantısız/noktasız)
          return true if SPECIAL_FILENAMES.include?(cleaned)

          # 3. Geçerli dosya uzantısı — nokta içeren ve noktadan sonra en az 1 karakter
          return true if cleaned.include?(".") && !cleaned.end_with?(".")

          # 4. Path separator içeren yollar
          return true if cleaned.include?("/") || cleaned.include?("\\")

          # 5. Hiçbir koşula uymayan — garbage
          false
        end

        private

        def contains_invalid_chars?(cleaned)
          # Sondaki virgül: LLM'in argüman sızıntısı (RubyAdapter.new,)
          return true if cleaned.end_with?(",")

          # Baştaki soru işareti: LLM sembol sızıntısı (?error)
          return true if cleaned.start_with?("?")

          # Diğer geçersiz karakterler (* " < > |)
          cleaned.chars.any? { |c| INVALID_PATH_CHARS.include?(c) }
        end
      end
    end
  end
end
```

**Tasarım Notları:**

- **Negatif kontrol önce gelir:** Geçersiz karakter/sondaki virgül/baştaki soru işareti kontrolleri, pozitif izin listesinden önce çalışır. Bu, motivasyonel 3 çöp yolunun (`RubyAdapter.new,`, `0.75,`, `?error,`) tamamını yakalar.
- **`.env*` SPECIAL_FILENAMES'te DEĞİL:** `Security::Guard::DEFAULT_CRITICAL_PATTERNS` zaten `.env*` yazımlarını `sanitize_path(for_write: true)` üzerinden engeller — `.env` asla tampona yazılamaz. Ayrıca kural 3 (nokta + uzantı) zaten `.env`'i geçerli sayar, bu nedenle listeye eklemek gereksizdir. Asıl engelleyici Guard'dır, PathValidator değil.
- **Sayısal uzantı kuralı YOK:** `data.1`, `log.2024`, `chunk.001` gibi dosyalar yanlış pozitiftir. Geçersiz karakter kontrolü (sondaki virgül) zaten gerçek çöpü yakalar.
- **SSOT:** Hem `WriteFileTool` hem de `Buffer::Manager#apply!` bu modülü kullanır.

### 3.1 Change 1: WriteFileTool — Path Validasyonu + Schema Açıklaması

**Dosya:** `lib/rubik/tools/builtins/files.rb`

#### 3.1.1 `require` Ekle (dosya başına, mevcut require_relative'lerden sonra)

`files.rb` `lib/rubik/tools/builtins/` dizininde olduğu için, `lib/rubik/buffer/path_validator.rb`'a erişmek için iki seviye yukarı çıkmalıyız:

```ruby
require_relative "../../buffer/path_validator"
```

#### 3.1.2 Schema'ya `description` Ekle (Satır 69)

Mevcut:
```ruby
params_schema: { type: "object", properties: { path: { type: "string" }, content: { type: "string" } }, required: ["path", "content"] }
```

Yeni:
```ruby
params_schema: {
  type: "object",
  properties: {
    path: {
      type: "string",
      description: "File path relative to the project root (e.g. 'lib/app.rb', 'src/main.go', 'Gemfile'). " \
                   "Must be a valid file path with a directory separator or a recognized filename extension."
    },
    content: { type: "string", description: "Full file content to write (overwrites entire file)" }
  },
  required: ["path", "content"]
}
```

#### 3.1.3 `execute` Metoduna Validasyon Ekle (Satır 74 sonrası)

Mevcut `execute` metodu (satır 74-89):
```ruby
def execute(args = {})
  path = (args["path"] || args[:path]).to_s.strip
  content = args["content"] || args[:content]
  begin
    @buffer_manager.write(path, content)
  rescue Errno::EACCES => e
    return DiagnosticReporter.render_permission_denied(path, operation: "write", reason: e.message)
  rescue Rubik::Buffer::InvalidPathError, StandardError => e
    return DiagnosticReporter.render_traversal_blocked(path) if e.class.name.include?("InvalidPathError")

    raise
  end
  "Successfully wrote to in-memory buffer: #{path}"
rescue Errno::EACCES => e
  DiagnosticReporter.render_permission_denied(path, operation: "write", reason: e.message)
end
```

Yeni — validasyon satır 75-76 arasına eklenir, mevcut hata işleme korunur:
```ruby
def execute(args = {})
  path = (args["path"] || args[:path]).to_s.strip
  content = args["content"] || args[:content]

  return "Error: `path` parameter is required." if path.empty?
  unless Rubik::Buffer::PathValidator.valid?(path)
    return "Error: Invalid file path '#{path}'. Path must be a valid file path " \
           "relative to the project root (e.g. 'lib/app.rb', 'src/main.go', 'Gemfile')."
  end

  begin
    @buffer_manager.write(path, content)
  rescue Errno::EACCES => e
    return DiagnosticReporter.render_permission_denied(path, operation: "write", reason: e.message)
  rescue Rubik::Buffer::InvalidPathError, StandardError => e
    return DiagnosticReporter.render_traversal_blocked(path) if e.class.name.include?("InvalidPathError")

    raise
  end
  "Successfully wrote to in-memory buffer: #{path}"
rescue Errno::EACCES => e
  DiagnosticReporter.render_permission_denied(path, operation: "write", reason: e.message)
end
```

**Hata Formatı Notu:** Düz `"Error: ..."` dizesi kullanılmıştır (DiagnosticReporter yerine), çünkü bu bir *parametre doğrulama* hatasıdır — tıpkı `ReplaceFileContentTool`'un `"Error: \`path\` parameter is required."` formatı gibi. ELM DiagnosticReporter, traversal/permission gibi *güvenlik/güvenilirlik* hataları için kullanılır. Bu bilinçli bir seçimdir ve mevcut tool parametre doğrulama stiliyle tutarlıdır.

### 3.2 Change 2: Buffer::Manager#apply! — İkincil Güvenlik Katmanı

**Dosya:** `lib/rubik/buffer/manager.rb`

#### 3.2.1 `require` Ekle (dosya başına)

```ruby
require_relative "path_validator"
```

#### 3.2.2 `apply!` Metoduna Validasyon + Olay Yayını Ekle (Satır 189-200 arası)

Mevcut:
```ruby
keys_to_apply.each do |rel_path|
  next unless @dirty_files.key?(rel_path)

  full_path = File.expand_path(rel_path, @root_dir)
  content = @buffer[rel_path]

  Rubik::Platform.atomic_write(full_path, content)
  ...
```

Yeni:
```ruby
keys_to_apply.each do |rel_path|
  next unless @dirty_files.key?(rel_path)

  unless PathValidator.valid?(rel_path)
    @dirty_files.delete(rel_path)
    @buffer.delete(rel_path)
    @event_bus&.emit(:buffer_garbage_skipped, path: rel_path)
    next
  end

  full_path = File.expand_path(rel_path, @root_dir)
  content = @buffer[rel_path]

  Rubik::Platform.atomic_write(full_path, content)
  ...
```

**Tasarım Notu:** Atlanan garbage path'ler `@event_bus` üzerinden `:buffer_garbage_skipped` olayı yayınlar. Bu, REPL'in atlanan yolları göstermesine ve operatörün farkında olmasına olanak tanır — sessiz veri silme yok. `Guard#log_audit` kullanılmaz çünkü bu bir güvenlik ihlali değil, veri bütünlüğü korumasıdır.

### 3.3 Değişiklik Özeti

| Dosya | Değişiklik | Etki |
| :--- | :--- | :--- |
| `lib/rubik/buffer/path_validator.rb` | **YENİ** — Paylaşılan `PathValidator` modülü | SSOT doğrulama mantığı |
| `lib/rubik/tools/builtins/files.rb` | `require` eklendi | Modülü yükler |
| `lib/rubik/tools/builtins/files.rb` | `params_schema`'da `path`'e `description` eklendi | LLM artık path formatını görür |
| `lib/rubik/tools/builtins/files.rb` | `execute`'a validasyon eklendi | Geçersiz path'lerde hata döndürür |
| `lib/rubik/buffer/manager.rb` | `require` eklendi | Modülü yükler |
| `lib/rubik/buffer/manager.rb` | `apply!`'a garbage path atlama + olay yayını eklendi | Güvenlik ağı |

---

## 4. Test Kapsamı

### 4.1 Mevcut Testler (Değişiklik Gerektirmez)

- `test/unit/test_buffer.rb` — Temel buffer okuma/yazma/apply testleri (etkilenmez)
- `test/unit/test_critical_write_guard.rb` — Kritik yol koruması (etkilenmez)
- `test/unit/test_elm_system_diagnostics_and_utf8_resilience.rb` — ELM hata formatı (etkilenmez)

### 4.2 Yeni Testler: `test/unit/test_write_file_path_validation.rb`

```ruby
# frozen_string_literal: true

require_relative "../test_helper"

class TestWriteFilePathValidation < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @tool = Rubik::Tools::WriteFileTool.new(@manager)
  end

  def teardown
    remove_temp_dir(@temp_dir)
  end

  # =====================
  #  Geçerli yollar
  # =====================

  def test_valid_ruby_file_path
    result = @tool.execute("path" => "lib/app.rb", "content" => "puts 1")
    assert_includes result, "Successfully wrote"
    assert_equal "puts 1", @manager.read("lib/app.rb")
  end

  def test_valid_nested_path
    result = @tool.execute("path" => "src/main.go", "content" => "package main")
    assert_includes result, "Successfully wrote"
  end

  def test_valid_special_filename_gemfile
    result = @tool.execute("path" => "Gemfile", "content" => 'source "https://rubygems.org"')
    assert_includes result, "Successfully wrote"
  end

  def test_valid_special_filename_dockerfile
    result = @tool.execute("path" => "Dockerfile", "content" => "FROM ruby:3.2")
    assert_includes result, "Successfully wrote"
  end

  def test_valid_special_filename_license
    result = @tool.execute("path" => "LICENSE", "content" => "MIT License")
    assert_includes result, "Successfully wrote"
  end

  def test_valid_special_filename_vagrantfile
    result = @tool.execute("path" => "Vagrantfile", "content" => "Vagrant.configure")
    assert_includes result, "Successfully wrote"
  end

  def test_valid_markdown_file
    result = @tool.execute("path" => "README.md", "content" => "# Hello")
    assert_includes result, "Successfully wrote"
  end

  def test_valid_config_file
    result = @tool.execute("path" => "config/application.rb", "content" => "module Config; end")
    assert_includes result, "Successfully wrote"
  end

  def test_valid_numeric_versioned_file
    # data.1, log.2024 gibi dosyalar geçerli sayılmalıdır
    result = @tool.execute("path" => "log.2024", "content" => "log data")
    assert_includes result, "Successfully wrote"
  end

  def test_valid_dotfile
    result = @tool.execute("path" => ".ruby-version", "content" => "3.2")
    assert_includes result, "Successfully wrote"
  end

  # =====================
  #  Schema / Tool metadata
  # =====================

  def test_schema_includes_path_description
    schema = @tool.params_schema
    path_schema = schema.dig("properties", "path") || schema.dig(:properties, :path)
    refute_nil path_schema, "path property should exist in schema"
    desc = path_schema["description"] || path_schema[:description]
    assert desc&.include?("relative to the project root"),
           "path description should guide the LLM: #{desc.inspect}"
  end

  # =====================
  #  Geçersiz yollar (garbage)
  # =====================

  def test_rejects_ruby_code_fragment
    result = @tool.execute("path" => "RubyAdapter.new,", "content" => "x")
    assert_includes result, "Error"
    refute_includes result, "Successfully wrote"
    # Tampon temiz kalmalı
    refute @manager.dirty?
  end

  def test_rejects_numeric_fragment
    result = @tool.execute("path" => "0.75,", "content" => "x")
    assert_includes result, "Error"
    refute @manager.dirty?
  end

  def test_rejects_error_symbol_fragment
    result = @tool.execute("path" => "?error,", "content" => "x")
    assert_includes result, "Error"
    refute @manager.dirty?
  end

  def test_rejects_empty_path
    result = @tool.execute("path" => "", "content" => "x")
    assert_includes result, "Error"
  end

  def test_rejects_nil_path
    result = @tool.execute("path" => nil, "content" => "x")
    assert_includes result, "Error"
  end

  def test_rejects_comma_terminated_fragment
    result = @tool.execute("path" => "some_method,", "content" => "x")
    assert_includes result, "Error"
  end

  def test_rejects_path_with_question_mark
    result = @tool.execute("path" => "file?.rb", "content" => "x")
    assert_includes result, "Error"
  end

  def test_rejects_path_with_asterisk
    result = @tool.execute("path" => "*.rb", "content" => "x")
    assert_includes result, "Error"
  end

  def test_rejects_path_with_angle_bracket
    result = @tool.execute("path" => "<file>.rb", "content" => "x")
    assert_includes result, "Error"
  end

  # =====================
  #  apply! garbage atlama
  # =====================

  def test_apply_skips_garbage_paths
    @manager.write("lib/valid.rb", "content")
    @manager.write("garbage,", "should_not_write")

    applied = @manager.apply!
    assert_includes applied, "lib/valid.rb"
    refute_includes applied, "garbage,"
    refute File.exist?(File.join(@temp_dir, "garbage,"))
  end

  def test_apply_does_not_skip_valid_paths
    @manager.write("lib/app.rb", "puts 1")
    @manager.write("Gemfile", 'source "https://rubygems.org"')

    applied = @manager.apply!
    assert_includes applied, "lib/app.rb"
    assert_includes applied, "Gemfile"
    assert File.exist?(File.join(@temp_dir, "lib/app.rb"))
    assert File.exist?(File.join(@temp_dir, "Gemfile"))
  end

  def test_apply_emits_event_for_garbage_path
    events = []
    bus = Object.new
    bus.define_singleton_method(:emit) { |event, **payload| events << [event, payload] }
    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, event_bus: bus)

    manager.write("valid.rb", "ok")
    manager.write("bad,,", "no")
    manager.apply!

    garbage_events = events.select { |e, _| e == :buffer_garbage_skipped }
    assert_equal 1, garbage_events.size
    assert_equal "bad,,", garbage_events.first[1][:path]
  end

  def test_apply_with_target_paths_skips_garbage
    @manager.write("lib/valid.rb", "content")
    @manager.write("garbage,", "should_not_write")

    # Sadece belirli bir path'i apply et
    applied = @manager.apply!(["lib/valid.rb"])
    assert_includes applied, "lib/valid.rb"
    refute File.exist?(File.join(@temp_dir, "garbage,"))
    # garbage hala dirty
    assert @manager.dirty?
  end
end
```

### 4.3 Test Çalıştırma

```bash
ruby -Itest test/unit/test_write_file_path_validation.rb
ruby -Itest test/unit/test_buffer.rb
ruby -Itest test/unit/test_critical_write_guard.rb
ruby -Itest test/unit/test_elm_system_diagnostics_and_utf8_resilience.rb
```

---

## 5. Risk Değerlendirmesi

| Risk | Seviye | Azaltma |
| :--- | :--- | :--- |
| Mevcut geçerli yolların yanlışlıkla reddedilmesi | **DÜŞÜK** | Negatif kontroller (sondaki virgül, baştaki `?`, geçersiz karakterler) yalnızca açıkça garbage olan yolları hedefler; path separator veya uzantı içeren her yol geçerli sayılır |
| Windows yol formatı (`C:\`) ile uyumsuzluk | **DÜŞÜK** | Windows yolları `\` separator içerdiği için geçerli sayılır; colon (`:`) sadece `C:` gibi sürücü öneklerinde bulunur ve INVALID_PATH_CHARS'ta yoktur |
| LLM'in yeni hata mesajını yanlış yorumlaması | **DÜŞÜK** | Hata mesajı açık ve yönlendirici: "Path must be a valid file path relative to the project root" |
| `SPECIAL_FILENAMES` listesinin güncel kalmaması | **DÜŞÜK** | Liste yalnızca uzantısız/noktasız özel dosyalar içindir; çoğu dosya uzantı veya separator ile yakalanır |
| `apply!` garbage atlama + olay yayını performans etkisi | **DÜŞÜK** | Yalnızca dirty dosyalar üzerinde çalışır; `PathValidator.valid?` O(n) string kontrolü |

---

## 6. Uygulama Sırası

1. `lib/rubik/buffer/path_validator.rb` — Yeni paylaşılan modül
2. `lib/rubik/tools/builtins/files.rb` — WriteFileTool değişiklikleri (require + schema + execute validasyonu)
3. `lib/rubik/buffer/manager.rb` — Manager değişiklikleri (require + apply! koruması)
4. `test/unit/test_write_file_path_validation.rb` — Yeni test dosyası
5. Tüm testleri çalıştır ve doğrula
6. `detect_changes` ile etki analizi yap