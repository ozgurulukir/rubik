# 📋 Plan 77: Tampon Çakışma Tespiti, Gerçek Unified Diff ve Genel Audit Tamirleri

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** Orta–İleri · **Faz:** 6
> **İlgili Planlar:** [03](03-dosya-tamponu-snapshot-undo.md), [70](70-write-file-garbage-path-korumasi.md), [71](71-calisma-zamani-saglamlastirma-lsp-devre-kesici-buffer-thread-safety-ve-izole-testler.md), [73](73-arac-katmani-sertlestirme-kapsulleme-ve-hata-ayristirma.md), [75](75-reaktif-yapilandirma-gozlemcisi-sistem-geneli-knob-kablolamasi-ve-canli-rekonfigurasyon.md), [76](76-lsp-buffer-jit-senkronizasyonu-oturum-arac-kaydi-ve-modern-web-adaptoru.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

Tam kod tabanı audit'i (baseline: `rake test` 1.207 test / 7.098 assertion %100 yeşil, RuboCop 319 dosya 0 offense) sırasında saptanan bulgular tek semantik birimde toplanır:

### 1.1. Tampon Çakışma Tespiti Eksik (Plan 03 Görev 9'un Tamamlanması)
- **Problem:** Plan 03 "Görev 9": `!apply` veya `apply_buffer` anında disk içeriği, tamponun okuma/yazma tabanından beri harici olarak (kullanıcı, başka süreç, `git pull`) değiştiyse çakışma bildirilmeli ve veri kaybı önlenmelidir.
- **Mevcut Durum:** `@original_hashes` altyapısı ilk günden beri `lib/rubik/buffer/manager.rb` içinde tutulmakta (`read`, `write`, `snapshot_state`), ancak `apply!` metodunda bu hash'ler disk ile **asla karşılaştırılmamaktadır** (tüketici yok).
- **Risk:** Ajan bir dosyayı okur veya yazar → bu sırada dışarıdan dosyaya müdahale edilir → `!apply` sessizce diski ezer ve harici değişiklik kaybolur.

### 1.2. Sahte Unified Diff (Tüm Dosyayı Silip Baştan Ekleme)
- **Problem:** `Rubik::Buffer::Diff.build_hunk` (`diff.rb:23-35`) gerçek bir diff algoritması çalıştırmayıp, `@@ -1,N +1,M @@` başlığı altında **orijinal tüm satırları eksi (`-`)** ve **yeni tüm satırları artı (`+`)** olarak dökmektedir.
- **Etki:** 500 satırlık dosyada 1 satırlık değişiklik yapıldığında ~1000 satırlık sahte diff üretilerek LLM bağlam bütçesi (token budget) israf edilmekte ve REPL kullanıcısı yanıltılmaktadır.

### 1.3. Oturum Kaydedicisi Sınırsız Bellek Büyümesi
- **Problem:** `lib/rubik/session/recorder.rb:36` `@events = []` her oturum olayını bellekte sınırsız biriktirir. Uzun REPL ve ajan oturumlarında veya `switch_session_file` ile büyük oturum dosyaları yüklendiğinde O(session_length) bellek tüketimi oluşur.

### 1.4. Sandbox "İzolasyon" Vaadinin Şeffaflığı ve Doğru Sürücü Seçimi
- **Problem:** `ProcessDriver` ortamında `allow_network: false` yalnızca proxy ortam değişkenlerini (`HTTP_PROXY`, `ALL_PROXY`) geçersiz kılar; ham soketler veya değişkenleri temizleyen süreçler ağı kullanabilir. Kullanıcı ve modele bu izolasyonun düzeyi açıkça raporlanmalıdır.
- **Otomatik Yükseltme:** `sandbox.driver: "auto"` modunda sistemde Docker veya Podman konteyner motoru çalışır durumdaysa güvenli konteyner sürücüsü seçilmeli, yoksa şeffaf bir danışmanlık uyarısıyla Process sürücüsüne geçilmelidir.

### 1.5. Kök Dizinde LICENSE Dosyasının Eksikliği
- **Problem:** `rubik.gemspec` satır 14'te `spec.license = "MIT"` ve satır 17'de `spec.files` içinde `"LICENSE"` yer almasına rağmen dosya sisteminde `LICENSE` dosyası mevcut değildir.

### 1.6. Güvenlik Kalkanı (Security Guard) Regex Bypasları
- **Problem:** `guard.rb:22` içindeki `rm\s+-rf\s+/` deseni; `rm -fr /`, `rm -r -f /`, `rm -rf /*`, `rm -rf -- /`, `rm -v -r -f /` gibi bilinen varyantları yakalamamaktadır. Ayrıca `dd if=` ve `mkfs` desenleri eksiktir.

---

## 🏛️ 2. Mimari Tasarım ve Çözüm Bileşenleri

### 2.1. Bileşen 1: `apply!` Çakışma Kapısı (`@original_hashes` Canlandırması)
- `Manager#apply!(target_paths = nil)` döngüsünde her kirli dosya için diske atomik yazım yapılmadan önce:
  ```ruby
  full_path = File.expand_path(rel_path, @root_dir)
  baseline = @original_hashes[rel_path]
  cur_hash = disk_hash(rel_path)

  # Çakışma durumu:
  # 1. Dosya tampona ilk alındığında diskte vardı ama şimdi disk hash'i baseline'dan farklı
  # 2. Veya dosya tamponda yeni oluşturuldu (baseline nil) ama diskte dosya zaten türedi
  conflict = if baseline && File.exist?(full_path)
               cur_hash != baseline
             elsif baseline.nil? && File.exist?(full_path)
               true
             else
               false
             end
  ```
- **DRY:** Özel yardımcı `disk_hash(rel_path)`:
  ```ruby
  def disk_hash(rel_path)
    full_path = File.expand_path(rel_path, @root_dir)
    return nil unless File.exist?(full_path)

    Digest::SHA256.hexdigest(Rubik::Platform.normalize_newlines(File.read(full_path)))
  rescue StandardError
    nil
  end
  ```
- **Politika & Yapılandırma:**
  - `buffer.on_external_modification`: `"skip"` (varsayılan, veri kaybını önleyici fail-safe) | `"overwrite"` (dış değişikliği göz ardı edip ezme).
  - `"skip"` durumunda: dosya diske yazılmaz, `@dirty_files` ve `@buffer` içinde korunmaya devam eder (kullanıcının diff inceleyip karar vermesi için).
  - `conflicts << rel_path` listesine eklenir ve `@event_bus&.emit(:buffer_apply_conflict, paths: conflicts, path: rel_path)` yayınlanır.
- **Geriye Dönük Uyumluluk:**
  - `Manager#apply!` dönüş tipi **kesinlikle `Array<String>`** (başarıyla diske yazılan dosyalar) olarak kalır. Tüm 8 çağrı noktası (`step_executor.rb`, `buffer.rb`, `agent_execution.rb`, `lifecycle.rb`) bozulmadan çalışır.
  - Çakışan dosyalar `attr_reader :last_conflicts` ile dışarı açılır.
- **Görünürlük:**
  - `ApplyBufferTool` ve `!apply`: Çakışma varsa çıktısına `[CONFLICT] <path>: disk content changed since last read — skipped to prevent data loss. Re-read the file to resolve.` ekler.

### 2.2. Bileşen 2: Gerçek Unified Diff (`diff-lcs` Motoru)
- **Bağımlılık:** `rubik.gemspec` ve `Gemfile` içine `spec.add_dependency "diff-lcs", ">= 1.5", "< 3.0"` eklenir. (Saf Ruby, sıfır C bağımlılığı, Windows/macOS/Linux/Wasm tam uyumlu, MIT).
- **Doğru Uygulama:** `diff-lcs` kütüphanesinde `Diff::LCS::Formatters::Unified` sınıfı **mevcut değildir**. Standart ve kanıtlanmış yaklaşım `Diff::LCS::Hunk` nesneleri üzerinden `hunk.diff(:unified)` ve `hunk.merge(oldhunk)` algoritmasıdır (kütüphanenin kendi `bin/ldiff` uygulamasında olduğu gibi):
  ```ruby
  require "diff/lcs"
  require "diff/lcs/hunk"

  module Rubik
    module Buffer
      class Diff
        def self.unified_diff(file_path, original_content, new_content, context: 3)
          orig_lines = (original_content || "").lines
          new_lines = (new_content || "").lines
          return "" if orig_lines == new_lines

          diffs = Diff::LCS.diff(orig_lines, new_lines)
          return "" if diffs.empty?

          output = "--- a/#{file_path}\n+++ b/#{file_path}\n"
          file_length_difference = 0
          oldhunk = hunk = nil

          diffs.each do |piece|
            hunk = Diff::LCS::Hunk.new(orig_lines, new_lines, piece, context, file_length_difference)
            file_length_difference = hunk.file_length_difference
            next unless oldhunk
            next if context.positive? && hunk.merge(oldhunk)

            output << oldhunk.diff(:unified) << "\n"
          ensure
            oldhunk = hunk
          end

          if oldhunk
            last = oldhunk.diff(:unified, true)
            last << "\n" unless last.empty? || last.end_with?("\n")
            output << last
          end

          output
        end
      end
    end
  end
  ```
- **DiffViewer Uyumu:** Üretilen `@@ -l,c +l,c @@` başlıkları, `+` ve `-` satırları, `lib/rubik/ui/diff_viewer.rb` renklendiricisi ile %100 uyumlu çalışır.
- **Tüketiciler:** `diff_all` ve `DiffViewer.render` arayüzü (`string-in / string-out`) korunur.

### 2.3. Bileşen 3: Oturum Kaydedicisi Bellek Üst Sınırı (Bounded Memory)
- `lib/rubik/session/recorder.rb` içine `MAX_RECENT_EVENTS = 500` sabiti eklenir.
- Özel yardımcı `push_event(event)` metodu:
  ```ruby
  def push_event(event)
    @events << event
    @events.shift while @events.size > MAX_RECENT_EVENTS
    event
  end
  ```
- Hem `record` hem de `switch_session_file` yükleme döngüsünde `@events <<` yerine `push_event` kullanılır.
- JSONL dosyası diskte her zaman eksiksiz tutulur; bellekteki `@events` dizisi ise O(1) tavanıyla korunur.

### 2.4. Bileşen 4: Sandbox İzolasyon Şeffaflığı ve Test-Uyumlu Çıktı
- **Otomatik Konteyner Seçimi:** `Driver.best_available("auto", ...)` zaten Docker → Podman → Process önceliğini işletir.
- **İzolasyon Açıklaması (Disclosure):**
  - `Runner#run` yürütme sonucuna `:isolation` anahtarını ekler:
    - Docker/Podman: `🔍 Isolation: container (#{driver.name}, network=#{allow_network? ? 'allowed' : 'none'}) — strong`
    - Process: `🔍 Isolation: process (advisory-only network guard) — weak`
    - Wasm: `🔍 Isolation: wasm (wasm/wasi sandbox) — strong`
- **Geriye Dönük Test Uyumluluğu:**
  - `RunCommandTool#execute` çıktısına `:isolation` etiketini **yalnızca `res[:isolation]` nil değilse** ekler:
    ```ruby
    out = "[#{status}]#{shell_tag} #{res[:output]}"
    out += "\n#{res[:isolation]}" if res[:isolation]
    ```
  - Bu sayede `test_expanded_tools.rb` gibi testlerde `@runner.stub :run, { ok: true, exit_code: 0, output: "plain result" }` şeklinde mock dönen testler kırılmaz (1.207 test %100 yeşil kalır).

### 2.5. Bileşen 5: Kök Dizin LICENSE Dosyası
- Proje köküne standart MIT Lisans metni `LICENSE` adıyla eklenir:
  - Telif: `Copyright (c) 2026 Rubik Team` (`rubik.gemspec` `spec.authors` ile uyumlu).

### 2.6. Bileşen 6: Guard Regex Sertleştirmesi ve Regresyon Testleri
- `lib/rubik/security/guard.rb` `DANGEROUS_COMMAND_PATTERNS` güncellenir:
  ```ruby
  DANGEROUS_COMMAND_PATTERNS = [
    %r{rm\s+(?:-[a-z0-9-]+\s+)*(?:-[a-z]*r[a-z]*f[a-z]*|-[a-z]*f[a-z]*r[a-z]*|(?:-[a-z]*r[a-z]*\s+-[a-z]*f[a-z]*)|(?:-[a-z]*f[a-z]*\s+-[a-z]*r[a-z]*))\s+(?:--\s+)?/(?:\*|\s|$)}i,
    /curl.*\|\s*sh/,
    /wget.*\|\s*sh/,
    /:\(\)\{\s*:\|:&\s*\};:/, # fork bomb
    %r{\bdd\s+.*if=}i,
    %r{\bmkfs(?:\.\w+)?\b}i,
    %r{del\s+.*/s.*[a-z]:\\}i,
    %r{erase\s+.*/s.*[a-z]:\\}i,
    %r{rmdir\s+.*/s.*[a-z]:\\}i,
    %r{rd\s+.*/s.*[a-z]:\\}i,
    /format\s+[a-z]:/i,
    /Remove-Item\s+.*-Recurse.*[a-z]:\\/i,
    /%0\|%0/
  ].freeze
  ```
- Yakalananlar: `rm -rf /`, `rm -fr /`, `rm -rf /*`, `rm -fr /*`, `rm -rf -- /`, `rm -r -f /`, `rm -f -r /`, `rm -v -r -f /`, `dd if=...`, `mkfs.ext4 ...`.

---

## 📋 3. Uygulama Adımları & Değişecek Dosyalar

1. **`lib/rubik/config/defaults.rb` & Satır Sınırı Hijyeni:**
   - `"network" => { "allow" => false }` bloğu tek satıra sıkıştırılarak 2 satır kazanılır (mevcut 149 satır).
   - `"buffer" => { ..., "on_external_modification" => "skip" }` eklenir. Dosya 148 satırda tutularak `test_module_hygiene.rb` (< 150 satır) kuralı %100 korunur.
2. **`rubik.gemspec` & `Gemfile`:**
   - `spec.add_dependency "diff-lcs", ">= 1.5", "< 3.0"` eklenir.
3. **`lib/rubik/buffer/diff.rb`:**
   - `Diff::LCS::Hunk` tabanlı gerçek unified diff algoritması uygulanır.
4. **`lib/rubik/buffer/manager.rb`:**
   - `attr_reader :last_conflicts`, `disk_hash(rel_path)` ve `apply!` çakışma kapısı eklenir.
5. **`lib/rubik/session/recorder.rb`:**
   - `MAX_RECENT_EVENTS = 500` ve `push_event` metodu eklenir.
6. **`lib/rubik/sandbox/runner.rb` & `lib/rubik/tools/builtins/exec.rb`:**
   - `Runner#run` içinde `:isolation` alanı; `RunCommandTool#execute` içinde nil-safe ekleme.
7. **`LICENSE` (Yeni):**
   - Kök dizine MIT lisans metni eklenir.
8. **`lib/rubik/security/guard.rb`:**
   - Gelişmiş tehlikeli komut regex'leri eklenir.
9. **`lib/rubik/repl/commands/buffer.rb` & `lib/rubik/tools/builtins/lifecycle.rb`:**
   - `[CONFLICT]` mesajları eklenir.
10. **Test Dosyaları:**
    - `test/unit/test_buffer_apply_conflict.rb` (yeni, 5+ senaryo).
    - `test/unit/test_buffer_diff.rb` (yeniden yazım, gerçek unified diff doğrulaması).
    - `test/unit/test_session_recorder_cap.rb` (yeni veya mevcut teste 500 üst sınır testi).
    - `test/unit/test_security_guard_bypasses.rb` (yeni veya `test_security_guard.rb` güncellemesi).
    - `test/unit/test_sandbox_isolation_disclosure.rb` (yeni).

---

## 🛡️ 4. Kalite ve Hijyen Garantileri

- **Spatiotemporal Protokol Uyumu:** `apply!` çakışma kapısı atomik ve deterministiktir; başarısız/çakışan dosya tamponda korunur, diske kısmi yazım yapılmaz.
- **Modül Satır Sınırı İnvariantları:**
  - `defaults.rb` < 150 satır (kesin kural, 148 satırda kalacak).
  - `exec.rb` < 300 satır (mevcut: 180).
  - `lifecycle.rb` < 300 satır (mevcut: 256).
  - `loop.rb` < 350 satır (mevcut: 348).
  - `shell.rb` <= 620 satır (mevcut: 620).
- **Geriye Dönük Uyumluluk:** 1.207 testin tamamı %100 yeşil kalacaktır.
- **GitNexus Graph Notu:** `apply!` çağrı noktaları (`step_executor.rb`, `buffer.rb`, `agent_execution.rb`, `lifecycle.rb`) dönüş tipinin `Array<String>` korunmasıyla güvence altındadır.

---

## 🎯 5. Doğrulama ve Kabul Kriterleri

- [x] `bundle exec rake test`: 1.224 test, 0 failure, 0 error (%100 yeşil).
- [x] `bundle exec rubocop`: 0 offenses (321 dosya tertemiz).
- [x] `test_module_hygiene.rb`: Tüm dosya boyutu limitleri yeşil.
- [x] `!diff` çıktısında gerçek bağlamlı diff hunks (`@@ -l,c +l,c @@`).
- [x] Dışarıdan değiştirilen dosyada `!apply` çakışmayı tespit edip diski ezmeden atlar (`[CONFLICT]`).
- [x] `read_file(path: "...", reload: true)` ile harici çakışma sonrası diskten zorla yeniden yükleme ve kirli tamponu temizleme sözleşmesi.
- [x] `operational_rules` ve `<buffer_status>` XML bloklarında çakışma durumsal farkındalığı ve yönlendirme.
- [x] `rm -fr /`, `rm -r -f /`, `rm -rf /*`, `dd if=...` güvenlik kalkanı tarafından engellenir.
- [x] `LICENSE` dosyası mevcuttur.
- [x] `TOOLS.md` ve `CONFIG.md` belgeleri yeni parametre ve ayarlar ile güncellenmiştir.
