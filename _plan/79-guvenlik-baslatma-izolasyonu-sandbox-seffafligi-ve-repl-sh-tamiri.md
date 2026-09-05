# 📋 Plan 79: Güvenlik Başlatma İzolasyonu (Lazy-Init Guard), Sandbox İzolasyon Şeffaflığı, REPL !sh Entegrasyonu ve Kod Tabanı Kozmetik Sertleştirmesi

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** Kolay–Orta · **Faz:** 6  
> **İlgili Planlar:** [12](12-guvenlik-diff-onay.md), [13](13-sandbox-izolasyon.md), [19](19-container-ve-wasm-sandbox-izolasyonu.md), [71](71-calisma-zamani-saglamlastirma-lsp-devre-kesici-buffer-thread-safety-ve-izole-testler.md), [78](78-calisma-zamani-thread-safety-ast-teshis-ve-kapsulleme-tamiri.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

Bağımsız dış kod tabanı incelemesi (*Code Review: Rubik*), kod tabanının yüksek kalitesini, sıfır teknik borcunu (0 TODO/FIXME), `AGENTS.md` Spatiotemporal Composability protokolüne tam uyumunu ve 1,240 testlik yeşil süitini teyit etmiş; bununla birlikte tasarım tercihleri ve kozmetik iyileştirmeler kapsamında haklı 5 gözlem sunmuştur:

### 1.1. `Security::Guard` Constructor Dosya Sistemi Yan Etkisi (P1 — Initialization Purity)
- **Problem:** `lib/rubik/security/guard.rb:88` satırında `initialize` içinde `FileUtils.mkdir_p(File.dirname(@audit_log_path))` çağrılmaktadır.
- **Risk:** Nesne yönelimli tasarım ve fonksiyonel saflık ilkelerine göre constructor'lar dosya sistemi üzerinde yan etki (I/O) üretmemelidir. Salt doğrulama amaçlı `Guard.new` çağrılarında veya test ortamlarında, henüz hiçbir denetim günlüğü (`audit.log`) yazılmayacakken gereksiz dizin oluşturulmakta; salt-okunur dosya sistemlerinde veya kısıtlı izinlerde `Errno::EACCES` riski doğmaktadır.
- **Çözüm:** `initialize` içinden `FileUtils.mkdir_p` kaldırılmalı; `log_audit` metodu içinde denetim kaydı diske yazılmadan hemen önce dizin yoksa açılmalı (`lazy initialization`) ve `rescue StandardError` ile hata izolasyonuna alınmalıdır.

### 1.2. REPL `!sh` Komutunun Sandbox Runner ile Kopukluğu (P2 — Architectural Consistency)
- **Problem:** `lib/rubik/repl/commands/agent_execution.rb:170` satırında `!sh` komutu çalıştırılırken çıplak `runner = Rubik::Sandbox::Runner.new` örneği oluşturulmaktadır.
- **Risk:** Shell nesnesi üzerinde yapılandırılmış olan `@sandbox_runner` (ve onun taşıdığı `sandbox.driver`, `timeout_seconds`, `allowed_external_dirs`, `allow_network` ayarları) yok sayılmakta; kullanıcı REPL üzerinden `!config set sandbox.driver docker` yapsa dahi `!sh` komutu varsayılan process sürücüsünde kalmaktadır.
- **Çözüm:** `runner = shell.sandbox_runner || Rubik::Sandbox::Runner.new(root_dir: Dir.pwd, config: shell.config)` şeklinde merkezi runner kullanılmalı ve izolasyon seviyesi çıktısı korunmalıdır.

### 1.3. Sandbox İzolasyon Seviyeleri ve Şeffaflık Rehberi (P2 — Security Transparency)
- **Problem:** İncelemede vurgulandığı üzere, varsayılan `process` sürücüsü doğası gereği "zayıf" (weak) izolasyon sağlar (sezgisel komut kara listesi ve chdir kısıtı; işletim sistemi düzeyinde ağ/süreç izolasyonu yoktur). Güçlü izolasyon için `docker`, `podman` veya `wasm` sürücülerinin tercih edilmesi gerekmektedir.
- **Risk:** Kullanıcılar veya ajanlar `process` sürücüsünün gerçek bir OS sandbox'ı olduğunu varsayabilir.
- **Çözüm:** `Runner#isolation_disclosure` çıktısındaki dürüst açıklama korunarak, `CONFIG.md`, `COMMANDS.md` ve `README.md` dokümanlarına "İzolasyon Güvenlik Matrisi" tablosu ve açık uyarılar eklenmelidir.

### 1.4. Motor İçi Yorum Dili ve Tutarlılık İyileştirmesi (P3 — International Codebase Consistency)
- **Problem:** Çekirdek motor dosyalarında (özellikle `lib/rubik/runtime/manager.rb:82`) Türkçe kalan `rubocop:disable` gerekçe yorumu uluslararası açık kaynak standartlarıyla çelişmektedir.
- **Çözüm:** Çekirdek motor kodlarındaki tüm inline gerekçeler ve mimari notlar temiz ve tutarlı İngilizceye çevrilmelidir (`fiber.rb` ve `context.rb` ile tam uyum).

### 1.5. Pre-1.0 Sürüm Politikası & Test Metrikleri Açıklaması (P3 — Documentation & Metrics)
- **Problem:** Rubik henüz pre-1.0 (`VERSION = "0.1.0"`) aşamasındadır; API kararlılık garantileri ve çevresel test atlamaları (`pwsh`, `prism`, `headless reline`) belgelenmelidir.
- **Çözüm:** `README.md` içinde SemVer 2.0 kararlılık yol haritası ve çevresel test atlamaları dipnotu eklenmelidir.

---

## 🏛️ 2. Mimari Tasarım ve Çözüm Bileşenleri

```
                   ┌──────────────────────────────────────────────┐
                   │                   PLAN 79                    │
                   └──────────────────────┬───────────────────────┘
                                          │
          ┌───────────────────────────────┼───────────────────────────────┐
          ▼                               ▼                               ▼
 ┌──────────────────┐            ┌──────────────────┐            ┌──────────────────┐
 │  Security::Guard │            │     REPL !sh     │            │    İzolasyon     │
 │  Lazy Audit Init │            │  Runner Wiring   │            │   Şeffaflığı     │
 ├──────────────────┤            ├──────────────────┤            ├──────────────────┤
 │ Constructor saf  │            │ shell.sandbox_   │            │ CONFIG / COMMANDS│
 │ mkdir_p log_audit│            │ runner kullanımı │            │ İzolasyon matrisi│
 │ içine taşınır    │            │ Config knobs akt.│            │ Zayıf/Güçlü rehber│
 └──────────────────┘            └──────────────────┘            └──────────────────┘
```

### 2.1. Bileşen 1: `Security::Guard` Tembel (Lazy) Başlatım
- `lib/rubik/security/guard.rb`:
  ```ruby
  def initialize(custom_patterns: [], audit_log_path: File.join(Rubik::Platform.home_dir, ".rubik", "audit.log"))
    @critical_patterns = (DEFAULT_CRITICAL_PATTERNS + custom_patterns).uniq
    @audit_log_path = audit_log_path
    # Constructor dosya sistemi yan etkisinden (mkdir_p) arındırıldı.
  end

  def log_audit(action, details = {})
    masked_details = details.transform_values { |v| mask_text(v.to_s) }

    entry = {
      ts: Time.now.iso8601,
      action: action,
      details: masked_details
    }

    dir = File.dirname(@audit_log_path)
    FileUtils.mkdir_p(dir) unless File.directory?(dir)

    File.open(@audit_log_path, "a") do |f|
      f.puts(JSON.dump(entry))
    end
  rescue StandardError => e
    warn "[WARN] Failed to write audit log #{@audit_log_path}: #{e.message}" if ENV["RUBIK_DEBUG"]
  end
  ```

### 2.2. Bileşen 2: REPL `!sh` Komutunun `shell.sandbox_runner` ile Bağlanması
- `lib/rubik/repl/commands/agent_execution.rb`:
  ```ruby
  cmd = args.join(" ")
  shell.guard.verify_command_safety!(cmd)
  runner = shell.sandbox_runner || Rubik::Sandbox::Runner.new(root_dir: Dir.pwd, config: shell.config)
  res = runner.run(cmd)
  shell.output.puts res[:output]
  ```

### 2.3. Bileşen 3: Sandbox İzolasyon Matrisi & Rehberlik
- `CONFIG.md` ve `COMMANDS.md` içine eklenecek tablo:
  | Sürücü | İzolasyon Gücü | Ağ İzolasyonu | Dosya Sistemi | Önerilen Kullanım |
  | :--- | :---: | :---: | :---: | :--- |
  | **`docker`** | **Güçlü (Strong)** | OCI Network namespace (`--network none`) | Mount izolasyonu | Üretim ortamı / Güvenilmeyen kod |
  | **`podman`** | **Güçlü (Strong)** | Rootless network namespace | Mount izolasyonu | Root yetkisi olmayan CI/CD |
  | **`wasm`** | **Güçlü (Strong)** | WASI sandbox (Sıfır socket erişimi) | Sanal preopened dizin | Güvenli hafif scriptler |
  | **`process`** | **Zayıf (Weak)** | Yalnızca sahte proxy değişkenleri | Yalnızca chdir/path denetimi | Yerel güvenli geliştirme |

### 2.4. Bileşen 4: Motor İçi Yorum Dili & Pre-1.0 Yol Haritası
- `lib/rubik/runtime/manager.rb:82`:
  ```ruby
  when :failed
    fiber.activate!(@context) if fiber.satisfiable?(@context) # rubocop:disable Lint/DuplicateBranch -- :pending and :failed intentionally share activation reaction; state machine branches kept explicit
  ```
- `README.md`: SemVer 2.0 ve 0.x sürüm kararlılık politikası paragrafı.

---

## 📋 3. Uygulama Adımları

1. **`lib/rubik/security/guard.rb`:** `initialize` içindeki `FileUtils.mkdir_p` kaldırılır; `log_audit` içine taşınır.
2. **`lib/rubik/repl/commands/agent_execution.rb`:** `!sh` komutu `shell.sandbox_runner`'ı kullanacak şekilde güncellenir.
3. **`lib/rubik/runtime/manager.rb`:** Satır 82'deki rubocop-disable açıklaması İngilizceye dönüştürülür.
4. **Dokümantasyon:** `CONFIG.md`, `COMMANDS.md` ve `README.md` dosyalarına İzolasyon Güvenlik Matrisi ve Pre-1.0 kararlılık ilkeleri eklenir.
5. **Birim Testleri:** `test/unit/test_security_guard.rb` içine `test_initialize_has_no_filesystem_side_effects` testi eklenir; `test_repl_command_decoupling.rb` ve `test_module_hygiene.rb` doğrulanır.
6. **Doğrulama:** `rake test` (1240+ test %100 yeşil) ve `rubocop` (0 offense) bağımsız olarak çalıştırılır.
