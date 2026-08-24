# 📋 Plan 49: Tam Kapsamlı Cross-Platform Desteği ve Windows Ortamı Uyumluluk Mimarisi

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** Orta–Zor · **Faz:** 5 (Platform Bağımsızlığı & Çekirdek Dayanıklılık)  
> **İlgili Planlar:** [01](01-proje-iskeleti-ve-konfigurasyon.md), [02](02-repl-cekirdegi.md), [03](03-dosya-tamponu-snapshot-undo.md), [07](07-dil-adaptor-cercevesi.md), [12](12-guvenlik-diff-onay.md), [13](13-sandbox-izolasyon.md), [18](18-tree-sitter-ast-ve-lsp-entegrasyonu.md), [29](29-lsp-derin-entegrasyonu-tanilama-ve-reaktif-geri-bildirim.md), [39](39-asenkron-ve-kademeli-ast-onbellegi-persistent-lazy-indexing.md), [40](40-coklu-calisma-alani-ve-ek-kok-dizin-erisim-yonetimi.md), [45](45-spatiotemporal-oz-evrilen-calisma-zamani-ve-otonom-adaptor-sentezi.md), [48](48-harici-erisim-izinli-dizinler-ve-sifir-ast-sandbox-guvenlik-kapisi.md)

---

## 🎯 1. Problem ve Kapsam Analizi

### Mevcut Durum & Windows Ortamındaki Uç Noktalar:
Rubik mimarisi Linux, macOS ve Windows üzerinde kesintisiz çalışacak şekilde tasarlanmıştır. Ancak mevcut kod tabanında Windows 11 / Windows Server ortamlarında çalışan test süitinde 11 hata ve 1 exception tespit edilmiştir. Bu problemler aşağıdaki temel başlıklar altında toplanmaktadır:

1. **Unix Kabuk Yönlendirmeleri ve `which` Bağımlılığı (Subprocess Pollution):**
   - Kod tabanında (`Rubik::Runtime::Discovery`, `Rubik::Adapter::Base`, `Rubik::LSP::Client`, `Rubik::Sandbox::Driver::Docker/Podman/Wasm`) ikili dosyaların (binary) varlığını denetlemek için `system("which #{bin} > /dev/null 2>&1")` veya `ProcessRunner.run("which #{bin}")` çağrıları kullanılmaktadır.
   - Windows üzerinde yerel `which` komutu bulunmamaktadır ve `/dev/null` yönlendirmesi `cmd.exe` tarafından tanınmayarak `The system cannot find the path specified.` hatası vermekte, test çıktılarını yüzlerce satır kirletmekte ve derleyici/LSP tespitlerini yanlış negatif (false negative) yapmaktadır.
2. **Windows Güvenlik Kalkanı (`Guard`) ve Tehlikeli Dizin Ayrıştırması:**
   - `Rubik::Security::Guard` içinde `DANGEROUS_SYSTEM_ROOTS` sabitinde yalnızca Unix kök dizinleri (`/`, `/etc`, `/usr`, `/var`, `/home` vb.) yer almaktadır.
   - Windows ortamında `File.expand_path("/etc")` çağrısı `C:/etc` değerine genişlediğinden `DANGEROUS_SYSTEM_ROOTS.include?(expanded)` kontrolü başarısız olmakta; ayrıca Windows'a özgü `C:\`, `C:\Windows`, `C:\Program Files`, `C:\Users` gibi sistem kökleri ve sürücü harfleri korunmasız kalmaktadır.
3. **Audit Log Yolu ve `ENV["HOME"]` Eksikliği:**
   - `Rubik::Security::Guard` varsayılan log yolunda `File.join(ENV["HOME"], ".rubik", "audit.log")` kullanmaktadır. Windows üzerinde `ENV["HOME"]` tanımsız (nil) olduğunda `TypeError` oluşmaktadır (`ENV["USERPROFILE"]` veya `HOMEDRIVE`+`HOMEPATH` gereklidir).
4. **CLI Başlatıcı ve Süreç Yürütme (`ENOEXEC`):**
   - `bin/rubik` dosyası shebang (`#!/usr/bin/env ruby`) ile çalışmakta olup Windows komut istemcisi üzerinden doğrudan çağrıldığında `Errno::ENOEXEC` hatası vermektedir. Yerel `bin/rubik.cmd`, `bin/rubik.bat` ve `bin/rubik.ps1` sarmalayıcıları gereklidir.
5. **Çoklu Sürücü (Multi-Drive) ve Göreli Yol Hatası:**
   - Windows ortamında farklı sürücü harflerindeki (`C:\repo` ve `D:\shared_libs`) ek çalışma alanı kökleri arasında `Pathname#relative_path_from` çağrısı yapıldığında `ArgumentError: different prefix` hatası fırlatılmaktadır.
6. **LSP URI ve Dosya Yolu Standartları (RFC 8089):**
   - Windows üzerinde LSP URI formatı (`file:///C:/path/to/file` RFC 8089) ile Unix URI formatı (`file:///path/to/file`) farklılık göstermektedir. `file://C:/...` şeklindeki iki bölülü formatlar bazı LSP sunucuları tarafından geçersiz sayılmakta; URI decode (`%20`, `%3A`) dönüşümleri eksik kalmaktadır.
7. **Büyük/Küçük Harf Duyarlılığı (Case Insensitivity) & NTFS:**
   - Windows NTFS dosya sistemi büyük/küçük harf duyarsızdır (`C:/Github/rubik` == `c:/github/rubik`). `Buffer::Manager`, `Security::Guard` ve `Sandbox::Runner` yol denetimleri birebir dizgi eşitliği yerine normalleştirilmiş karşılaştırma gerektirmektedir.
8. **Süreç Ağacı Sonlandırma (Process Tree Termination & Zombie Processes):**
   - Windows üzerinde `Process.kill("KILL", pid)` yalnızca ana kabuk/wrapper sürecini kapatır, alt süreçleri (ör. `node.exe`, `ruby.exe`, `gopls.exe`) arkada açık (zombie) bırakır. Windows için `taskkill /F /T /PID <pid>` uygulanmalıdır.
9. **Atomik Dosya Yazma (File Replacement on Windows):**
   - Windows Win32 dosya sisteminde hedef dosya mevcutken `File.rename(tmp, target)` çağrısı `Errno::EACCES` veya `Errno::EEXIST` üretebilir. Güvenli atomik değiştirme (`Platform.atomic_write`) gereklidir.
10. **Satır Sonu Formatı (CRLF vs LF):**
    - Windows ortamında dosyalar `\r\n` (CRLF) satır sonlarına sahip olabilir. Unified diff üretimi ve SHA-256 hash hesaplamalarında CRLF normalizasyonu güvenceye alınmalıdır.

---

## 🏛️ 2. Mimari Tasarım ve Platform Soyutlama Katmanı

```
                                  ┌──────────────────────────────────────────────┐
                                  │             Rubik Application Core           │
                                  └──────────────────────┬───────────────────────┘
                                                         │
                                                         ▼
                         ┌───────────────────────────────────────────────────────────────┐
                         │                     Rubik::Platform                           │
                         │          (Cross-Platform Capabilities & OS SSOT)              │
                         ├───────────────────────────────────────────────────────────────┤
                         │ • OS Detection: windows?, linux?, macos?, unix?               │
                         │ • Binary Discovery: Platform.which(bin) (Pure-Ruby + PATHEXT) │
                         │ • Path Normalization: normalize_path, path_under?, path_eq?   │
                         │ • System Roots: dangerous_system_roots, drive_root?           │
                         │ • File URI (RFC 8089): to_file_uri(path), from_file_uri(uri)  │
                         │ • Subprocess & Signals: dev_null, kill_tree, safe_popen3      │
                         │ • Atomic FS: atomic_write(target_path, content)               │
                         │ • Text Normalization: normalize_newlines(content)             │
                         └──────────────────────┬────────────────────────┬───────────────┘
                                                │                        │
                       ┌────────────────────────┘                        └────────────────────────┐
                       ▼                                                                          ▼
       ┌───────────────────────────────┐                                          ┌───────────────────────────────┐
       │   Windows Specific Handling   │                                          │    POSIX / Unix Handling      │
       ├───────────────────────────────┤                                          ├───────────────────────────────┤
       │ • PATHEXT (.exe, .cmd, .bat)  │                                          │ • POSIX Permissions (chmod)   │
       │ • Builtins (echo, dir, cls)   │                                          │ • Null device: '/dev/null'    │
       │ • Null device: 'NUL'          │                                          │ • Case-sensitive paths        │
       │ • Case-insensitive paths      │                                          │ • Single root '/' hierarchy   │
       │ • Multi-drive letter roots    │                                          │ • POSIX Signals (SIGTERM/INT) │
       │ • Safe process tree kill      │                                          │ • Direct shebang execution    │
       │ • bin/rubik.cmd wrapper       │                                          │ • Standard atomic rename      │
       └───────────────────────────────┘                                          └───────────────────────────────┘
```

---

## ⚙️ 3. Modüler İyileştirmeler ve Kodlama Spesifikasyonları

### 3.1. `Rubik::Platform` Çekirdek Modülü Oluşturulması
[`lib/rubik/platform.rb`](file:///C:/Github/rubik/lib/rubik/platform.rb) dosyası oluşturularak tek doğruluk kaynağı (SSOT) sağlanır:

```ruby
# frozen_string_literal: true

require "rbconfig"
require "tmpdir"
require "fileutils"
require "cgi"

module Rubik
  module Platform
    WINDOWS_SHELL_BUILTINS = %w[
      echo dir cd cls set type copy move del md rd exit rem ver vol
    ].freeze

    class << self
      def windows?
        Gem.win_platform? || (RbConfig::CONFIG["host_os"] =~ /mswin|mingw|cygwin|bccwin|wince/i) != nil
      end

      def macos?
        (RbConfig::CONFIG["host_os"] =~ /darwin/i) != nil
      end

      def linux?
        !windows? && !macos?
      end

      def unix?
        !windows?
      end

      def dev_null
        windows? ? "NUL" : "/dev/null"
      end

      def home_dir
        Dir.home rescue (ENV["HOME"] || ENV["USERPROFILE"] || (ENV["HOMEDRIVE"] && ENV["HOMEPATH"] && "#{ENV["HOMEDRIVE"]}#{ENV["HOMEPATH"]}") || ".")
      end

      def tmp_dir
        Dir.tmpdir rescue (ENV["TEMP"] || ENV["TMP"] || "/tmp")
      end

      # Pure-Ruby cross-platform binary resolver
      def which(cmd)
        return nil if cmd.nil? || cmd.to_s.strip.empty?
        cmd_str = cmd.to_s.strip.split.first
        return nil if cmd_str.nil? || cmd_str.empty?

        # Windows shell builtins (e.g. echo, dir, cls)
        if windows? && WINDOWS_SHELL_BUILTINS.include?(cmd_str.downcase)
          return cmd_str
        end

        # If full/relative path is provided
        if cmd_str.include?("/") || (windows? && cmd_str.include?("\\"))
          return File.expand_path(cmd_str).gsub("\\", "/") if File.file?(cmd_str) && executable_file?(cmd_str)
          if windows?
            pathext.each do |ext|
              candidate = "#{cmd_str}#{ext}"
              return File.expand_path(candidate).gsub("\\", "/") if File.file?(candidate) && executable_file?(candidate)
            end
          end
          return nil
        end

        # Search in PATH
        paths = (ENV["PATH"] || "").split(File::PATH_SEPARATOR)
        exts = windows? ? pathext : [""]

        paths.each do |dir|
          next if dir.empty? || !File.directory?(dir)
          exts.each do |ext|
            target = File.join(dir, "#{cmd_str}#{ext}")
            return File.expand_path(target).gsub("\\", "/") if File.file?(target) && executable_file?(target)
          end
        end
        nil
      end

      def pathext
        (ENV["PATHEXT"] || ".COM;.EXE;.BAT;.CMD;.VBS;.JS;.WS;.MSC;.PS1").split(";").map(&:downcase)
      end

      def executable_file?(path)
        return false unless File.file?(path)
        windows? ? true : File.executable?(path)
      end

      # RFC 8089 Compliant File URI (e.g. file:///C:/path/file vs file:///path/file)
      def to_file_uri(path)
        normalized = normalize_path_raw(path)
        if windows? && normalized =~ /^([a-zA-Z]):\/(.*)$/
          "file:///#{$1}:/#{$2}"
        else
          normalized.start_with?("/") ? "file://#{normalized}" : "file:///#{normalized}"
        end
      end

      def from_file_uri(uri)
        str = uri.to_s.sub(/^file:\/\//, "")
        str = CGI.unescape(str)
        if windows?
          # Handles file:///C:/... and file://C:/...
          if str =~ /^\/([a-zA-Z]:\/.*)$/
            $1
          elsif str =~ /^([a-zA-Z]:\/.*)$/
            $1
          else
            str
          end
        else
          str.start_with?("/") ? str : "/#{str}"
        end
      end

      def normalize_path_raw(path)
        expanded = File.expand_path(path.to_s)
        expanded.gsub("\\", "/")
      end

      # Normalizes separators and casing for comparison
      def normalize_path(path)
        raw = normalize_path_raw(path)
        windows? ? raw.downcase : raw
      end

      def path_equal?(p1, p2)
        normalize_path(p1) == normalize_path(p2)
      end

      def path_under?(child, parent)
        n_child = normalize_path(child)
        n_parent = normalize_path(parent)
        n_child == n_parent || n_child.start_with?("#{n_parent}/")
      end

      def dangerous_system_roots
        roots = %w[/ /root /home /etc /usr /var /bin /sbin /lib /lib64 /opt /boot /dev /proc /sys]
        if windows?
          # Add expanded Unix root equivalents on current drive (e.g. C:/etc, C:/usr)
          roots += roots.map { |r| File.expand_path(r) }
          roots += %w[c:/ c:/windows c:/windows/system32 c:/program\ files c:/program\ files\ (x86) c:/users c:/programdata]
          roots << ENV["SystemRoot"] if ENV["SystemRoot"]
          roots << ENV["ProgramFiles"] if ENV["ProgramFiles"]
          roots << ENV["ProgramFiles(x86)"] if ENV["ProgramFiles(x86)"]
          roots << ENV["CommonProgramFiles"] if ENV["CommonProgramFiles"]
          roots << ENV["USERPROFILE"] if ENV["USERPROFILE"]
          roots << ENV["SystemDrive"] if ENV["SystemDrive"]
        end
        roots << home_dir
        roots.compact.map { |r| normalize_path(r) }.uniq
      end

      def drive_root?(path)
        return false unless windows?
        normalize_path(path) =~ /^[a-z]:\/?$/
      end

      def kill_tree(pid)
        return unless pid && pid > 0
        if windows?
          system("taskkill /F /T /PID #{pid} > NUL 2>&1") rescue nil
        else
          Process.kill("TERM", pid) rescue nil
          Process.kill("KILL", pid) rescue nil
        end
      end

      def atomic_write(target_path, content)
        dir = File.dirname(target_path)
        FileUtils.mkdir_p(dir) unless File.directory?(dir)
        tmp_file = "#{target_path}.tmp.#{Process.pid}.#{rand(10000)}"
        File.write(tmp_file, content)

        if File.exist?(target_path)
          File.unlink(target_path) rescue nil
        end
        File.rename(tmp_file, target_path)
      rescue StandardError
        File.write(target_path, content)
      ensure
        File.unlink(tmp_file) if File.exist?(tmp_file) rescue nil
      end

      def normalize_newlines(content)
        content.to_s.gsub("\r\n", "\n")
      end
    end
  end
end
```

---

### 3.2. Runtime Discovery, Canlı Probing ve Adapter Refaktörü
- **[`lib/rubik/runtime/discovery.rb`](file:///C:/Github/rubik/lib/rubik/runtime/discovery.rb):**
  - `binary_available?(cmd)` metodundaki `system("which ... > /dev/null 2>&1")` kaldırılır; `Rubik::Platform.which(cmd) != nil` ile değiştirilir.
  - Windows üzerinde `.cmd` / `.bat` / `.exe` uzantılı araçlar (ör. `npm`, `yarn`, `pnpm`, `pytest`, `rake`, `bundle`, `pyright-langserver`, `solargraph`) anında ve sıfır alt-süreç maliyetiyle tespit edilir.
- **[`lib/rubik/adapter/base.rb`](file:///C:/Github/rubik/lib/rubik/adapter/base.rb):**
  - `available?` metodu `Rubik::Platform.which(@binary_name) != nil` olarak güncellenir.
- **[`lib/rubik/sandbox/driver/docker.rb`](file:///C:/Github/rubik/lib/rubik/sandbox/driver/docker.rb), [`podman.rb`](file:///C:/Github/rubik/lib/rubik/sandbox/driver/podman.rb), [`wasm.rb`](file:///C:/Github/rubik/lib/rubik/sandbox/driver/wasm.rb):**
  - Tüm `which` çağrıları `Rubik::Platform.which(...)` ile değiştirilir.

---

### 3.3. Güvenlik Kalkanı (`Guard`) ve Sandbox İzolasyonu
- **[`lib/rubik/security/guard.rb`](file:///C:/Github/rubik/lib/rubik/security/guard.rb):**
  - Varsayılan parametre: `audit_log_path: File.join(Rubik::Platform.home_dir, ".rubik", "audit.log")`
  - `verify_root_safety!(path)`:
    - Normalleştirilmiş yol `Rubik::Platform.dangerous_system_roots.include?(Rubik::Platform.normalize_path(expanded))` veya `Rubik::Platform.drive_root?(expanded)` veya `Rubik::Platform.path_equal?(expanded, Rubik::Platform.home_dir)` ile denetlenir.
  - `DANGEROUS_COMMAND_PATTERNS` genişletilir: Windows tehlikeli komutları (`/del\s+.*\/s.*[a-z]:\\/i`, `/erase\s+.*\/s.*[a-z]:\\/i`, `/rmdir\s+.*\/s.*[a-z]:\\/i`, `/rd\s+.*\/s.*[a-z]:\\/i`, `/format\s+[a-z]:/i`, `/Remove-Item\s+.*-Recurse.*[a-z]:\\/i`, `/%0\|%0/`) eklenir.
- **[`lib/rubik/sandbox/runner.rb`](file:///C:/Github/rubik/lib/rubik/sandbox/runner.rb):**
  - `verify_chdir_safety!(chdir)`: `allowed_paths.any? { |allowed| Rubik::Platform.path_under?(expanded, allowed) }` ile kontrol edilir.

---

### 3.4. LSP Client & Server Process Yönetimi
- **[`lib/rubik/lsp/client.rb`](file:///C:/Github/rubik/lib/rubik/lsp/client.rb):**
  - `available?`: `Rubik::Platform.which(binary_name) != nil` ile güncellenir.
  - `start`: `rootUri: Rubik::Platform.to_file_uri(@root_dir)` RFC 8089 standardına uyarlanır.
  - Belge URI'ları: `Rubik::Platform.to_file_uri(abs_path)` ile gönderilir.
  - Gelen diagnostik parametreleri: `Rubik::Platform.from_file_uri(uri)` ile çözümlenir.
  - `stop`: `Rubik::Platform.kill_tree(@wait_thr.pid)` ile süreç ağacı temiz şekilde kapatılır.

---

### 3.5. Buffer, Context Scanner & Cache Store Normalizasyonu
- **[`lib/rubik/buffer/manager.rb`](file:///C:/Github/rubik/lib/rubik/buffer/manager.rb):**
  - `sanitize_path`: `Rubik::Platform.path_under?` ve `Rubik::Platform.path_equal?` ile eşleştirilir.
  - `apply!`: `Rubik::Platform.atomic_write` ile atomik ve hatasız dosya yazımı sağlanır.
  - `read`, `write`, `diff`: `Rubik::Platform.normalize_newlines` ile satır sonları güvenceye alınır.
- **[`lib/rubik/context/scanner.rb`](file:///C:/Github/rubik/lib/rubik/context/scanner.rb):**
  - Multi-drive taramasında `Pathname#relative_path_from` çağrısı `rescue ArgumentError` ile yakalanarak `full_path` fallback'i uygulanır.
- **[`lib/rubik/ast/cache_store.rb`](file:///C:/Github/rubik/lib/rubik/ast/cache_store.rb):**
  - `.rubik/cache/ast_index.json` yazımında `Rubik::Platform.atomic_write` kullanılır.

---

### 3.6. REPL, Terminal Girişi ve Windows CLI Başlatıcıları
- **[`bin/rubik.cmd`](file:///C:/Github/rubik/bin/rubik.cmd) & [`bin/rubik.bat`](file:///C:/Github/rubik/bin/rubik.bat):**
  ```cmd
  @echo off
  @ruby "%~dp0rubik" %*
  ```
- **[`bin/rubik.ps1`](file:///C:/Github/rubik/bin/rubik.ps1):**
  ```powershell
  & ruby "$PSScriptRoot/rubik" @args
  ```

---

### 3.7. Standart OS/Platform Tespiti ve Gating Katmanı
- **[`lib/rubik/platform.rb`](file:///C:/Github/rubik/lib/rubik/platform.rb):**
  - `host_os`: `RbConfig::CONFIG["host_os"]` üzerinden ana işletim sistemi dizesi.
  - `ruby_platform`: `RUBY_PLATFORM` sabiti.
  - `os_family`: Sembolik işletim sistemi ailesi (`:windows`, `:macos`, `:linux`, `:unknown`).
  - `windows?`, `macos?`, `linux?`, `unix?`: RubyGems `Gem.win_platform?` ve `host_os` tabanlı sağlam gating fonksiyonları.

---

### 3.8. Süre Aşımı (Timeout) Anında Zombi Süreç Ağacı Temizliği
- **[`lib/rubik/sandbox/driver/process.rb`](file:///C:/Github/rubik/lib/rubik/sandbox/driver/process.rb) & [`lib/rubik/adapter/process.rb`](file:///C:/Github/rubik/lib/rubik/adapter/process.rb):**
  - `Timeout::Error` istisnası fırlatıldığında `wait_thr.pid` kaydedilir ve `Rubik::Platform.kill_tree(pid)` çağrılarak hem Windows (`taskkill /F /T /PID`) hem POSIX (`SIGTERM/KILL`) ortamında tüm alt süreçlerin (child processes) arkada zombi olarak kalması engellenir.

---

### 3.9. Otomatik /chat/completions Endpoint Normalizasyonu ve Windows Yapılandırma Kalıcılığı
- **[`lib/rubik/llm/openai_compatible.rb`](file:///C:/Github/rubik/lib/rubik/llm/openai_compatible.rb):**
  - `OpenAICompatibleProvider.normalize_endpoint(url)`: Base URL (`https://api.deepseek.com`, `https://openrouter.ai/api/v1`, `https://api.cline.bot`, `http://localhost:8000`) verildiğinde platformdan bağımsız olarak `/chat/completions` yolunu otomatik ekler.
- **[`lib/rubik/config.rb`](file:///C:/Github/rubik/lib/rubik/config.rb):**
  - `initialize`: Windows ortamında `Platform.home_dir` (`C:/Users/<User>`) kullanılarak global yapılandırma yolu güvenceye alınır.
  - `load_merged_config` & `set_model_spec`: Eski yerel Ollama yapılandırmasından kalan `host` artıklarının temizlenmesi ve `endpoint` ile standartlaştırılması sağlandı.

---

## 🧪 4. Test ve Kalite Güvencesi

1. **`test/unit/test_platform.rb` (Kapsamlı Platform Testleri):**
   - `Platform.os_family`, `Platform.host_os`, `Platform.ruby_platform` tespit testleri.
   - `Platform.which`: `ruby`, `gem`, `git`, Windows builtins (`echo`, `dir`, `cls`), hayali binary'ler ve `PATHEXT` uzantı çözümleme testleri.
   - `Platform.to_file_uri` ve `Platform.from_file_uri`: RFC 8089 3-slash formatı, URI decode (`%20`, `%3A`) çift yönlü testleri.
   - `Platform.path_under?` ve `Platform.path_equal?`: Windows (büyük/küçük harf duyarsız) ve Unix davranış testleri.
   - `Platform.dangerous_system_roots` ve `Platform.drive_root?`: `C:/`, `C:/Windows`, `/etc`, `C:/etc` güvenlik testleri.
   - `Platform.atomic_write`: Varolan ve yeni dosyaların atomik yazım doğrulaması.
2. **`test/unit/test_config.rb` & `test/unit/test_llm_provider.rb`:**
   - Yeniden başlatma (restart / Ctrl+C) sonrası yapılandırma kalıcılığı ve model yönlendirme testleri.
   - Endpoint otomatik normalizasyon ve modern model varsayılanları testleri.
3. **Genel Başarı Ölçütü:**
   - 340 test ve 2450+ assertion'ın tamamı Windows 11 üzerinde 0 hata ve 0 uyarı ile %100 yeşil çalışmaktadır.

---

## 📊 5. Uygulama Adımları ve Doğrulama Kontrol Listesi

- [x] **Adım 1:** `lib/rubik/platform.rb` oluşturulması ve `lib/rubik.rb` içine dahil edilmesi.
- [x] **Adım 2:** `Rubik::Runtime::Discovery`, `Rubik::Adapter::Base`, `Rubik::Sandbox::Driver` modüllerinde `Platform.which` refaktörü.
- [x] **Adım 3:** `Rubik::Security::Guard` ve `Rubik::Sandbox::Runner` içinde Windows sistem kökleri ve `Platform.path_under?` entegrasyonu.
- [x] **Adım 4:** `Rubik::LSP::Client` içinde RFC 8089 URI, `.cmd` binary çözümlemesi ve `Platform.kill_tree`.
- [x] **Adım 5:** `Rubik::Buffer::Manager`, `Rubik::Context::Scanner` ve `Rubik::AST::CacheStore` içinde multi-drive prefix, path normalizasyonu ve `Platform.atomic_write`.
- [x] **Adım 6:** `bin/rubik.cmd`, `bin/rubik.bat` ve `bin/rubik.ps1` Windows başlatıcılarının eklenmesi.
- [x] **Adım 7:** `Platform.os_family`, `Platform.host_os` ve `Platform.ruby_platform` gating katmanının eklenmesi.
- [x] **Adım 8:** `ProcessDriver` ve `Adapter::ProcessRunner` içinde timeout anında `Platform.kill_tree` ile zombi süreçlerin temizlenmesi.
- [x] **Adım 9:** `test/unit/test_platform.rb` yazılması, test süitinin tamamının Windows üzerinde 340 run / %100 yeşil koşulması.
