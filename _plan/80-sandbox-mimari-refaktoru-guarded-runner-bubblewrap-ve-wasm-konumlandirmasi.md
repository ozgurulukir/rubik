# 📋 Plan 80: Sandbox Mimari Sadeleştirmesi: `process` ve `wasm` Sürücülerinin Kaldırılması, Her Zaman Aktif Safe Execution, Linux Bubblewrap (bwrap), Modüler Tak-Çıkar Sürücü Mimarisi (Firejail / AGENTS.md) ve REPL !sandbox

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı (Eksiksiz Uygulandı ve Doğrulandı — 1,252/1,252 Test %100 Yeşil, RuboCop 0 Offense)** · **Zorluk:** Orta–Zor · **Faz:** 6  
> **İlgili Planlar:** [12](12-guvenlik-diff-onay.md), [13](13-sandbox-izolasyon.md), [19](19-container-ve-wasm-sandbox-izolasyonu.md), [20](20-spatiotemporal-composability-eklenti-dongusu.md), [71](71-calisma-zamani-saglamlastirma-lsp-devre-kesici-buffer-thread-safety-ve-izole-testler.md), [78](78-calisma-zamani-thread-safety-ast-teshis-ve-kapsulleme-tamiri.md), [79](79-guvenlik-baslatma-izolasyonu-sandbox-seffafligi-ve-repl-sh-tamiri.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

Kod incelemelerinde (Code Reviews) düzenli olarak gelen haklı eleştiriler iki temel sahte soyutlamayı işaret etmiştir:
1. *"Process sandbox yanıltıcı ve zayıftır; hiçbir OS izolasyonu sağlamayan standart bir child-process'e 'Sandbox Driver' demek güvenlik açısından yanıltıcıdır."*
2. *"Wasm sandbox genel amaçlı shell komutlarını çalıştıramaz; wasmtime 'bundle exec rake test' veya 'git' çağrıldığında anında patlamaktadır; sandbox eklentisinin wasm sandbox içinde çalışması da mantıksal bir çıkmazdır."*

Bu iki eleştirinin temelinde yatan yanıltıcı kavramlar kökten temizlenmektedir:
👉 **`sandbox.driver: "process"` ve `WasmDriver` (`wasm.rb`) kod tabanından tamamen çıkartılmaktadır.**

### 1.1. Mimari Temel: Her Zaman Aktif Safe Execution vs Gerçek Sandbox
1. **Safe Execution (Güvenli Çalıştırma — Evrensel Politika, Her Zaman Aktif):**
   - `Security::Guard` (tehlikeli komut ve regex bloklama),
   - `Platform.path_under?` ve `verify_chdir_safety!` (çalışma alanı kök dizin sınırları),
   - `verify_command_safety!` (yetkisiz kabuk müdahaleleri),
   - `ShellResolver` (platform bazlı güvenli interpreter yönlendirmesi).  
   Bu katman bir "sandbox sürücüsü" değildir; Rubik'in doğuştan gelen, **kapatılamayan evrensel güvenlik kalkanıdır**.
2. **Sandbox (İzolasyon Kafesi — İsteğe Bağlı, Donanımsal/Kernel Düzeyinde İzolasyon):**
   - İşletim sistemi çekirdeği düzeyinde (kernel namespaces, mount sınırları, cgroups) çalışan gerçek izolasyon katmanıdır.
   - `sandbox.enabled`: `false` (varsayılan — doğrudan güvenli host çalıştırması, sıfır ek yük).
   - `sandbox.enabled`: `true` (sandbox aktif — Linux'ta varsayılan olarak `bwrap`, istenirse `docker`, `podman` veya eklenti olarak `firejail`).

### 1.2. `bwrap` (Bubblewrap) — Linux İçin Varsayılan Gerçek Sandbox
- Linux'ta Docker kurmaya gerek duymadan, root yetkisi olmadan (unprivileged user namespaces) çalışan modern izolasyon aracı `bwrap`'tır.
- Kök dizini (`/`) Read-Only yapar, sadece proje dizinini Read-Write bağlar, `--unshare-net` ile ağı donanımsal olarak keser.
- **OS-Gated:** Yalnızca Linux üzerinde aktiftir (`Rubik::Platform.linux?`).
- **Default OFF:** Varsayılan olarak kapalıdır (`sandbox.enabled: false`). Kullanıcı açıkça istemedikçe standart doğrudan güvenli host çalıştırması devam eder.

### 1.3. `AGENTS.md` ile %100 Uyum: Modüler Tak-Çıkar Sürücü Kaydı (Firejail Desteği)
- Sürücüler artık donuk bir `DRIVERS = { ... }.freeze` tablosuna hapsolmayacaktır.
- `Rubik::Sandbox::Driver.register(name, driver_class, ctx: nil)`:
  - Dinamik sürücü ekleme/çıkarma yeteneği.
  - **Temporal Composability (Revertible Inverses):** `ctx` verildiğinde, `ctx.on_dispose { unregister(name) }` ters işlemi LIFO monoidine (`Ω`) kaydedilir. Bir eklenti kaldırıldığında veya reload edildiğinde, eklediği sandbox sürücüsü otomatik ve temiz bir şekilde çalışma zamanından sökülür.
  - **Zero-Downtime Hot-Swapping:** Ajan oturumu, bellek grafı veya tamponlar kaybolmadan canlı sürücü değişimi.
  - **Firejail Desteği:** Bir eklenti veya kullanıcı scripti `Rubik::Sandbox::Driver::Base`'ten türeyen bir `FirejailDriver` yazıp anında sisteme kaydedebilir ve `!sandbox firejail` komutuyla kullanabilir!

### 1.4. İlk Açılışta Akıllı Sandbox Önerisi (Onboarding Hint)
- Linux ortamında açılışta `bwrap` tespit edildiğinde ve sandbox kapalıysa kullanıcıya nazik öneri:  
  `💡 [Sandbox] Linux & Bubblewrap algılandı! Gerçek donanımsal OS izolasyonu için '!sandbox on' komutunu kullanabilirsiniz.`
- `sandbox.prompt_on_startup: true` knob'u ile yönetilir.

### 1.5. REPL `!sandbox` Bang Komutu
- `!sandbox` / `!sandbox status`: Mevcut durumu gösterir (Kapalı / Açık, aktif motor, network durumu, kayıtlı sürücüler).
- `!sandbox on`: Sandbox'ı açar (Linux'ta otomatik olarak `bwrap` seçilir).
- `!sandbox off`: Sandbox'ı kapatır (doğrudan güvenli çalıştırmaya döner).
- `!sandbox bwrap` / `!sandbox docker` / `!sandbox podman` / `!sandbox firejail`: İstenen sandbox motorunu seçer.
- `--project` (`-p`) ve `--global` (`-g`) bayrakları ile kalıcı kaydı destekler.

### 1.6. Reaktif Yapılandırma ve Temiz Knob'lar
- `lib/rubik/config/defaults.rb` içinden `sandbox.driver: "process"` ve `wasm` blokları silinir:
  ```ruby
  "sandbox" => {
    "enabled" => false,
    "driver" => "bwrap",
    "image" => "rubik-sandbox:latest",
    "timeout_seconds" => 15,
    "memory_limit_mb" => 512,
    "cpus" => "1.0",
    "allow_network" => false,
    "prompt_on_startup" => true
  },
  ```
- Geriye dönük uyumluluk: Eski yapılandırmalardan veya testlerden `"process"` veya `"none"` gelirse, `sandbox.enabled = false` olarak ele alınır ve asla hata vermez.

---

## 🏛️ 2. Mimari Tasarım ve Yeni Yürütme Modeli

```
                               ┌────────────────────────────────┐
                               │   Rubik Command / Tool Call    │
                               └───────────────┬────────────────┘
                                               │
                                               ▼
                             ┌───────────────────────────────────┐
                             │    SAFE EXECUTION POLICY (GATE)   │
                             │  (Her Zaman Aktif — Security::Guard)│
                             │  • Regex kara listesi             │
                             │  • Çalışma alanı & chdir kısıtı   │
                             └─────────────────┬─────────────────┘
                                               │
                       ┌───────────────────────┴───────────────────────┐
                       │                                               │
          [ sandbox.enabled == false ]                    [ sandbox.enabled == true ]
                       ▼                                               ▼
          ┌─────────────────────────┐                     ┌─────────────────────────┐
          │   DIRECT HOST RUNNER    │                     │  PLUGGABLE SANDBOX REG  │
          │   (Doğrudan Süreç)      │                     │  (AGENTS.md Composable) │
          ├─────────────────────────┤                     ├─────────────────────────┤
          │ • Güvenli yerel çalışma │                     │ • Bubblewrap (Linux Def)│
          │ • Sıfır ek yük          │                     │ • Docker / Podman (OCI) │
          │ • Çıktı: direct/safe    │                     │ • Firejail (Ext Plugin) │
          │ 🔍 safe host execution  │                     │ • Custom (ctx.provide)  │
          └─────────────────────────┘                     └─────────────────────────┘
```

### 2.1. İzolasyon Seviyesi ve Dürüst Açıklama Matrisi

| Mod | Motor / Sürücü | İzolasyon Gücü | Ağ Kısıtı | Dosya Sistemi Kısıtı | Platform / Kaynak |
| :--- | :--- | :---: | :--- | :--- | :--- |
| **Sandbox Kapalı (Varsayılan)** | Doğrudan Host (Safe) | **İzolesiz (Advisory)** | Yalnızca advisory env proxy | Yalnızca başlangıç `chdir` denetimi | Tüm platformlar |
| **Sandbox Açık** | **`bwrap` (Bubblewrap)** | **Güçlü (Strong)** | Kernel `--unshare-net` | Host `/` Read-Only, workspace RW | **Yalnızca Linux (OS-Gated)** |
| **Sandbox Açık** | **`docker`** | **Güçlü (Strong)** | OCI `--network none` | Mount sınırları, cgroups | Linux / macOS / Windows (Daemon) |
| **Sandbox Açık** | **`podman`** | **Güçlü (Strong)** | Rootless network netns | Mount sınırları, cgroups | Linux / macOS / Windows (CLI) |
| **Sandbox Açık (Eklenti)** | **`firejail`** | **Güçlü (Strong)** | Firejail `--net=none` | Whitelist/Blacklist profili | Linux (Tak-Çıkar Eklenti) |

---

## 🔧 3. Bileşen Detayları ve Uygulama Planı

### 3.1. Bileşen 1: `BubblewrapDriver` Sürücüsü (`lib/rubik/sandbox/driver/bubblewrap.rb`)
- **Konum:** `lib/rubik/sandbox/driver/bubblewrap.rb`
- **Sınıf:** `Rubik::Sandbox::Driver::BubblewrapDriver < Base`
- **Kullanılabilirlik (`available?`):**
  ```ruby
  def available?
    Rubik::Platform.linux? && !Rubik::Platform.which("bwrap").nil?
  end
  ```
- **Komut Argümanları:**
  ```ruby
  bwrap_cmd = [
    "bwrap",
    "--ro-bind", "/", "/",
    "--dev", "/dev",
    "--proc", "/proc",
    "--tmpfs", "/tmp",
    "--bind", workspace, workspace,
    "--chdir", chdir
  ]
  bwrap_cmd.push("--unshare-net") unless allow_network
  bwrap_cmd.push("--unshare-pid", "--die-with-parent")
  bwrap_cmd.push("sh", "-c", cmd)
  ```

### 3.2. Bileşen 2: `Driver` Dinamik Kayıt Defteri (`AGENTS.md` Revertible Modülerlik) & `wasm.rb` Kaldırılması
- `lib/rubik/sandbox/driver/wasm.rb` dosyası silinir.
- `lib/rubik/sandbox/driver.rb`:
  - Dinamik, iş parçacığı güvenli (Monitor) kayıt defteri kurulur:
    ```ruby
    module Driver
      @drivers = {}
      @mutex = Monitor.new

      def self.register(name, driver_class, ctx: nil)
        key = name.to_s.downcase
        @mutex.synchronize { @drivers[key] = driver_class }
        ctx&.on_dispose { unregister(key) }
        driver_class
      end

      def self.unregister(name)
        @mutex.synchronize { @drivers.delete(name.to_s.downcase) }
      end

      def self.registered_drivers
        @mutex.synchronize { @drivers.dup }
      end

      def self.resolve(name, options = {})
        key = name.to_s.downcase
        driver_class = @mutex.synchronize { @drivers[key] }
        return nil unless driver_class
        driver_class.new(options)
      end
    end
    ```
  - Başlangıçta `bwrap`, `docker`, `podman` kaydedilir.
  - Harici eklentiler (örneğin `firejail`) veya kullanıcı scriptleri `Driver.register("firejail", FirejailDriver, ctx: ctx)` ile anında yeni sandbox motorları ekleyebilir veya sökebilir.

### 3.3. Bileşen 3: `Runner` Safe Execution & Sandbox Ayrımı
- `lib/rubik/sandbox/runner.rb`:
  - `sandbox_enabled?`: `config.fetch("sandbox.enabled", false)`
  - Eğer `sandbox_enabled?` ise kayıtlı sürücüyü (`bwrap`, `docker`, `podman`, `firejail` vb.) çalıştırır.
  - Eğer kapalıysa doğrudan güvenli yerel süreç çalıştırır (`Open3.popen3`).
  - `isolation_disclosure`:
    - Sandbox kapalı: `🔍 Execution: direct (safe execution guardrails active; sandbox disabled)`
    - Sandbox açık: `🔍 Isolation: sandbox (#{driver.name}, network=#{net}) — strong`

### 3.4. Bileşen 4: REPL `!sandbox` Bang Komutu
- **Dosya:** `lib/rubik/repl/commands/agent_execution.rb`
- **Komutlar:**
  - `!sandbox` / `!sandbox status`: Mevcut sandbox durumunu, aktif motoru, ağ durumunu ve sisteme kayıtlı tüm sandbox motorlarını listeler.
  - `!sandbox on`: Sandbox'ı açar (Linux'ta bwrap, varsa docker).
  - `!sandbox off`: Sandbox'ı kapatır (doğrudan güvenli host moduna geçer).
  - `!sandbox [bwrap|docker|podman|firejail]`: İlgili motoru aktif eder.
  - `--project` / `--global` scope bayrakları ile kalıcı kaydeder.

### 3.5. Bileşen 5: Çalışma Alanı Açılışında Akıllı Öneri (Onboarding Hint)
- **Dosya:** `lib/rubik/ui/banner.rb` ve `lib/rubik/repl/shell.rb`
- Eğer Linux ortamı, `bwrap` mevcut, `sandbox.enabled == false` ve `sandbox.prompt_on_startup == true` ise:
  - REPL açılışında sarı renkle öneri:
    `💡 [Sandbox Önerisi] Linux ortamı ve Bubblewrap algılandı! Gerçek donanımsal OS izolasyonu için '!sandbox on' komutunu çalıştırabilirsiniz.`

### 3.6. Bileşen 6: Konfigürasyon ve Reaktif Kablolama
- **Dosya:** `lib/rubik/config/defaults.rb`:
  - `sandbox.driver: "process"` ve `wasm` blokları silinir.
  - `sandbox.enabled: false` ve `sandbox.driver: "bwrap"` eklenir.
  - Satır sayısı hijyeni (< 150 satır) korunur (~146 satır).
- **Dosya:** `lib/rubik/ui/statusline.rb`:
  - `sandbox_segment`: Sandbox açıksa `bwrap:izole`, kapalıysa `kapalı` gösterir.

### 3.7. Bileşen 7: Dokümantasyon Güncelleme Detayları
1. **`CONFIG.md`:**
   - `sandbox.driver: "process"` ve `wasm` referansları tamamen silinir.
   - `sandbox.enabled` (boolean, varsayılan `false`) ve `sandbox.driver` (`bwrap`, `docker`, `podman`, `firejail` vb.) detaylandırılır.
   - Safe Execution (her zaman aktif) ve Sandbox (isteğe bağlı izolasyon) matrisi güncellenir.
2. **`COMMANDS.md`:**
   - `!sandbox` komutu tüm varyasyonlarıyla eklenir (`!sandbox on`, `!sandbox off`, `!sandbox status`, `!sandbox bwrap`, `!sandbox firejail`).
   - `!sh` komutu açıklamasındaki `sandbox.driver: process` ve `wasm` referansları kaldırılır.
3. **`README.md` & `ARCHITECTURE.md`:**
   - Güvenlik ve Çalıştırma mimarisi güncellenir; Safe Execution politikası ve Linux için Bubblewrap OS sandbox desteği vurgulanır.
4. **`AGENTS.md`:**
   - Protokol §3 ve §4'e Modüler Sandbox Kayıt Defteri ve Revertible Inverses örneği eklenir (Firejail örneği ile).

---

## 🧪 4. Test Stratejisi ve Doğrulama

1. **`test/unit/test_bubblewrap_driver.rb` (Yeni):**
   - `available?` kontrolü (Linux ve bwrap varlığı).
   - Komut argümanları inşası (`--ro-bind / /`, `--bind workspace`, `--unshare-net`, `--unshare-pid`).
2. **`test/unit/test_sandbox_drivers.rb`:**
   - `bwrap`, `docker`, `podman` sürücü testleri.
   - `Driver.register` ve `Driver.unregister` dinamik tak-çıkar testleri (Firejail mock sürücüsü ile).
   - `ctx.on_dispose` ile otomatik unregister ters işlem (inverse) testi.
   - Eski `test_wasm_driver_execution_arguments` testi kaldırılır; temiz modüler testler eklenir.
3. **`test/unit/test_repl_command_execution_and_synthesis.rb`:**
   - `!sandbox on`, `!sandbox off`, `!sandbox status`, `!sandbox bwrap` REPL komut testleri.
4. **`test/unit/test_repl_command_decoupling.rb`:**
   - `expected_commands` listesine `"sandbox"` eklenmesi.
   - `shell.rb <= 620 satır` kontrolü.
5. **Genel Süit:**
   - Tüm testlerin %100 yeşil kalması (`bundle exec rake test`).
   - RuboCop 0 offense (`bundle exec rubocop`).
   - Modül hijyen kurallarının sağlanması.

---

## 👥 5. Çoklu Ajan İşbirliği Uygulama Adımları (Reviewer → Executor → Auditor)

1. **Aşama 1: Plan Reviewer & Architectural Analyst**
   - GitNexus etki analizi (`impact`) ve sembol bağımlılıklarının denetimi.
   - `wasm.rb` dosyasının silinmesinin ve `Driver.register` dinamik mimarisinin etki analizi.
2. **Aşama 2: Plan Executor & Backend Engineer**
   - `lib/rubik/sandbox/driver/bubblewrap.rb` dosyasının yazılması.
   - `lib/rubik/sandbox/driver/wasm.rb` dosyasının silinmesi.
   - `driver.rb` dosyasının dinamik kayıt defterine dönüştürülmesi.
   - `runner.rb`, `defaults.rb`, `agent_execution.rb`, `banner.rb`, `statusline.rb` dosyalarının güncellenmesi.
   - Test dosyalarının yazılması ve güncellenmesi.
   - Dokümantasyonların (`CONFIG.md`, `COMMANDS.md`, `README.md`, `ARCHITECTURE.md`, `AGENTS.md`) güncellenmesi.
3. **Aşama 3: Execution Reviewer & Quality Auditor**
   - Bağımsız test koşumu (`bundle exec rake test`).
   - Kod kalitesi ve lint kontrolü (`bundle exec rubocop`).
   - GitNexus `detect_changes` analizi ve plan indekslerinin güncellenmesi.
