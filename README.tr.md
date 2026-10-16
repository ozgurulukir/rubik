# 🎲 Rubik — Autonomous AI Coding Agent & REPL Harness

> Bu belge, [`README.md`](README.md) dosyasının Türkçe çevirisidir ve güncelliğini yitirmiş olabilir; çelişki halinde İngilizce sürüm esastır.

> **Spatiotemporal Composability & Self-Evolving Runtime** mimarisiyle inşa edilmiş, saf Ruby ile yazılmış yeni nesil otonom eşli kodlama (pair programming) ve REPL harness'ı.

[![Ruby Version](https://img.shields.io/badge/ruby-3.4%2B-red.svg)](https://www.ruby-lang.org)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-blue.svg)](https://github.com/ozgurulukir/rubik/actions/workflows/ci.yml)
[![Protocol](https://img.shields.io/badge/protocol-AGENTS.md-blue.svg)](AGENTS.md)
[![Commands Guide](https://img.shields.io/badge/docs-COMMANDS.md-yellow.svg)](COMMANDS.md)
[![Config Guide](https://img.shields.io/badge/docs-CONFIG.md-green.svg)](CONFIG.md)
[![CI](https://github.com/ozgurulukir/rubik/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ozgurulukir/rubik/actions/workflows/ci.yml)
[![Test Suite](https://img.shields.io/badge/tests-3696%20runs%20%7C%20verified%202026--10--15-brightgreen.svg)](https://github.com/ozgurulukir/rubik/actions/workflows/ci.yml)

---

## 👋 Rubik Nedir?

Rubik, saf Ruby ile yazılmış, terminal-doğal bir otonom kodlama ajanı ve etkileşimli REPL'dir. Bir **maestro** ajan, 34 araçlık kemer üzerinde uzmanlaşmış subagent'ları (research / coder / self) orkestre eder: dosya düzenlemeleri bellek içi sanal bir tamponda hazırlanır (`!diff` → `!apply`, yapılandırılabilir model yetkisi ve otomatik uygulama politikalarıyla), yönetilen çalışma zamanı yan etkileri süreç yeniden başlatması gerektirmeyen dinamik yeniden yükleme ve sökümleri desteklemek üzere LIFO ters işlemleri kaydeder ve bozulan servisler canlı teşhis edilip onarılabilir. Sınırlandırılmış CI matrisinde Linux, macOS ve Windows'u destekler; OpenAI uyumlu uç noktalara, Anthropic'e veya yerel Ollama'ya bağlanır ve tüm çalışma zamanı `require "rubik"` ile Ruby'den gömülebilir.

---

## 🚀 Hızlı Başlangıç

### Gem üzerinden

**Ruby 3.4+** gerektirir:

```bash
gem install rubik
```

Kurulum, `rubik` başlatıcısını RubyGems'in bin dizinine (PATH'inizde zaten var) koyar; böylece herhangi bir proje dizininden başlatabilirsiniz:

```bash
rubik
```

veya Bundler ile:

```ruby
gem "rubik"
```

#### Platform notları

| Platform | Kurulum deneyimi |
| :--- | :--- |
| 🐧 Linux / 🍎 macOS | `gem install rubik` — bağımlılıklar önceden derlenmiş gelir. |
| 🪟 Windows | `tree_sitter_language_pack`'in Windows ön-derlemesi yoktur ve kaynaktan derlenir: kurulumdan önce GNU toolchain'li Rust kurun ve `RUST_TARGET=x86_64-pc-windows-gnu` tanımlayın. Tam çalışan tarif: [`.github/workflows/ci.yml`](.github/workflows/ci.yml). |

### Kaynaktan

**Gereksinimler**

- **Ruby:** 3.4.0 veya üzeri (`ruby -v`)
  - **Linux / macOS:** Sistem paket yöneticisi, `rbenv`, `rvm` veya `asdf` ile.
  - **Windows:** [Scoop](https://scoop.sh) (`scoop install ruby`) veya [RubyInstaller with DevKit](https://rubyinstaller.org).
- **Git:** Git 2.30+ (`git -v`)
- **LLM Sağlayıcısı:** Yerel [Ollama](https://ollama.ai) (`ollama run qwen2.5-coder:7b`) veya DeepSeek, OpenRouter, Anthropic, OpenAI API anahtarı.

Projeyi klonlayın, bağımlılıkları yükleyin ve REPL'i başlatın:

```bash
git clone https://github.com/ozgurulukir/rubik.git
cd rubik
bundle install
```

#### 🐧 Linux & 🍎 macOS (POSIX)

```bash
# Proje dizininden doğrudan çalıştırma
./bin/rubik

# Veya sistemde global kullanmak için ~/.local/bin dizinine bağlayın:
ln -sf $(pwd)/bin/rubik ~/.local/bin/rubik
rubik
```

> [!NOTE]
> **Gem ve klon birlikte yaşayabilir.** POSIX'te sembolik bağ her zaman klonunuzu çalıştırır: `bin/rubik`, `lib/` yolunu kendi gerçek konumundan çözer; `rubik` gem'i kurulu kalsa bile `git pull` bir sonraki açılışta canlıya geçer. Gem'den kurulan `rubik`, `gem update rubik` koşana dek son yayınlanan sürümü sunmaya devam eder. Windows'ta `PATH`'te önce gelen `bin` klasörü kazanır — `where.exe rubik` kazananı gösterir.

#### 🪟 Windows (PowerShell / Command Prompt)

Rubik, Windows için yerleşik `.cmd`, `.bat` ve `.ps1` sarmalayıcılarıyla birlikte gelir:

```powershell
# PowerShell üzerinden çalıştırma
.\bin\rubik.ps1

# veya Command Prompt / Terminal üzerinden
.\bin\rubik.cmd

# veya Ruby üzerinden doğrudan
ruby bin\rubik
```

> [!TIP]
> **Windows'ta Global `rubik` Komutu:**  
> Rubik'in `bin` klasörünü ortam değişkenlerinize (User PATH) ekleyerek herhangi bir terminalden doğrudan `rubik` yazarak başlatabilirsiniz:
> ```powershell
> [Environment]::SetEnvironmentVariable("PATH", "$env:PATH;$PWD\bin", "User")
> ```

### Sağlayıcı (Provider) & Model Ekleme

İstediğiniz OpenAI uyumlu herhangi bir sağlayıcıyı tek satırla bağlayabilirsiniz:

```bash
# REPL içerisinden sağlayıcı ekleme:
rubik > !provider add deepseek openai_compatible https://api.deepseek.com/v1/chat/completions --key=sk-... --model=deepseek-coder --context=64000
rubik > !model deepseek/deepseek-coder
```

Anthropic, **native Messages API'si** üzerinden konuşur (OpenAI sarmalayıcı değil): `anthropic` sağlayıcısı kutudan çıkmış kayıtlıdır — `ANTHROPIC_API_KEY` tanımlayıp model seçmeniz yeterli:

```bash
rubik > !model anthropic/claude-sonnet-5-5
```

### İlk Oturum Örneği

```text
╭── rubik ─────────────────────────────────────────────────╮
│ 🎲 Rubik v0.1.0                                          │
│ deepseek/deepseek-coder                                  │
│ my_project · main                                        │
│ !help komutlar · ctrl+c kes · !config ayarlar            │
╰──────────────────────────────────────────────────────────╯
deepseek/deepseek-coder · ctx 3% · temiz · sandbox kapalı
rubik (my_project) [main] > !status
Project: my_project (main)
Default Model: deepseek/deepseek-coder
Dirty buffer: false

rubik (my_project) [main] > Kullanıcı kayıt formunu doğrulayan bir helper fonksiyonu yaz
✻ Düşünüyor… · 1s (ctrl+c: kes)
⏺ write_file — lib/validator.rb
  ⎿ 3 lines · 18ms

[Rubik] In-memory buffer updated. Type `!diff` to view, `!apply` to save.

rubik (my_project) [main] [DIRTY: 1 ✎] > !diff
+ def validate_user(params)
+   raise "Invalid email" unless params[:email]&.include?("@")
+ end

rubik (my_project) [main] [DIRTY: 1 ✎] > !test
Applied 1 file(s) before test. All 12 tests passed!
```

> [!TIP]
> **Safe Execution (Tree-Sitter AST) ve Tak-Çıkar OS İzolasyonu (Bubblewrap / Container):**
>
> Komut çalıştırmadan önce Rubik, `Security::Guard` kalkanını aktif tutar (Safe Execution); Bash ve PowerShell için Tree-Sitter sözdizim ağacı (AST) analizi ile 172 CLI YAML kuralı üzerinden tehlikeli komutları, boru hattı zehirlemelerini ve dizin kaçışlarını denetler. Komut kapısı tanınmayan sözdizim veya sınıflandırıcı hatalarında fail-closed davranır (engeller). Donanımsal OS izolasyonu isteğe bağlıdır ve varsayılan olarak kapalıdır (`sandbox.enabled: false`); Linux'ta devreye almak Bubblewrap (`bwrap`) veya OCI container (`docker`/`podman`) gerektirir:
> ```bash
> !sandbox on                                  # Linux'ta Bubblewrap ile donanımsal OS izolasyonunu açar
> !config set sandbox.allow_network true -p   # Ağ erişimi gerektiren komutlar için izin verir
> ```

---

## ⚡ Öne Çıkan Özellikler

- 🌐 **Cross-Platform Desteği (Linux, macOS, Windows):** POSIX sistemlerin (Linux, macOS) yanı sıra Windows 11 / Windows Server ortamlarında (PowerShell, Command Prompt, Windows Terminal) çalışır. Pure-Ruby ikili araç çözümü, NTFS büyük/küçük harf duyarsızlığı, RFC 8089 LSP URI standardı ve yerel Windows CLI (`.cmd`, `.bat`, `.ps1`) sarmalayıcıları içerir. Sınırlandırılmış CI matrisiyle doğrulanmıştır (Windows'ta `tree_sitter_language_pack` derlemesi Rust GNU araç zinciri gerektirir; [.github/workflows/ci.yml](.github/workflows/ci.yml) dosyasına bakın).
- 🛡️ **Bellek İçi Sanal Tampon ve Aşamalı Yazım (Staging):** Model kod ürettiğinde dosya değişiklikleri diske yazılmadan önce bellek içi sanal bir tamponda aşamalanır (stage). Değişiklikleri `!diff` ile inceleyebilir, `!apply` ile uygulayabilir veya uygulanmamış tampon düzenlemelerini `!undo` ile geri alabilirsiniz.
  - **Yetki ve İnceleme Kapıları:** Tamponlama tek başına insan incelemesini zorunlu kılmaz. Varsayılan olarak `buffer.auto_apply: manual` aşamalama yapar ancak `buffer.model_can_apply: true` değeri modelin `apply_buffer` aracıyla değişiklikleri kendi inisiyatifiyle diske yazmasına izin verir. Disk yazımlarından önce kesin insan onayını şart koşmak için `buffer.auto_apply: manual` ile birlikte `buffer.model_can_apply: false` ayarlanmalıdır. `buffer.auto_apply` ayarı `on_test`, `on_finish` veya `always` yapıldığında ise tampon tetikleyici sınırlarında otomatik olarak diske yazılır.
  - **Tekil Dosya Atomik Yazımı vs Çok Dosyalı İşlem (Transaction):** Her dosya tekil olarak atomik yazılır (geçici dosyaya yazma + atomik rename), ancak birden fazla dosyayı kapsayan apply işlemi hepsi-ya-da-hiç türünde bir dağıtık işlem (multi-file transaction) DEĞİLDİR. Yazım sırasında bir hata oluşursa (örneğin izin hatası veya sınır dışına taşma), daha önce diske yazılmış dosyalar diskte kalır; başarısız ve bekleyen dosyalar ise yapılandırılmış bir kısmi ilerleme raporuyla (`applied`, `failed`, `pending`, `conflicts`) tamponda kirli kalmaya devam eder.
- 🏢 **Çoklu Çalışma Alanı & Ek Kök Dizinler (Multi-Workspace Roots):** Monorepo veya kardeş paket mimarilerinde (`../shared-kernel`, `../proto`) harici kök dizinleri güvenle ekleyip (`!workspace add`), salt-okunur veya yazılabilir (`--rw`) modda tampon ve AST indeksine dahil edebilirsiniz.
- ⚡ **Canlı LSP Derleyici Teşhisleri:** Yapılandırılmış dil sunucusu ikili dosyaları (`rust-analyzer`, `gopls`, `ruff`, `typescript-language-server`, `typeprof` vb.) sistemin `PATH` yolunda kurulu olduğunda, Rubik stdio JSON-RPC üzerinden bağlanarak düzenleme sonrası derleyici teşhislerini ajana iletir. Dil sunucuları harici bağımlılıklardır; ikili dosya eksikse, yapılandırılmamışsa veya el sıkışma (handshake) başarısız olursa Rubik oturumu kesintiye uğratmadan saf sözdizim ve AST analizine çekilir (bkz. [LSP.md](LSP.md)).
- 🌳 **Çok Dilli Tree-Sitter & Prism Hibrit AST Motoru:** Sembol ayrıştırmada yorum/string karmaşasını önlemek için Ruby'de yerleşik **Prism** ayrıştırıcısını; Python, Go, Rust, TypeScript, TSX, JavaScript, C, C++ ve Zig için **Tree-Sitter** dilbilgisini kullanır. Tree-Sitter dilbilgisi veya C uzantıları mevcut olmadığında ya da ayrıştırma hatası verdiğinde motor, eski regex çıkarıcılara (karmaşık veya iç içe yapılarda yapısal sınırları bulunan) geri çekilir. Sembol ve çağrı grafı (`!symbols`, `!outline`, `!refs`) arka planda asenkron taranır ve yeniden başlatmalarda ilk indeksleme gecikmesini azaltmak için disk önbelleğinden (`.rubik/cache/ast_index.json`) yararlanır.
- 🤖 **Dinamik LLM Sağlayıcıları & Çoklu Rol Yönlendirmesi:** OpenAI uyumlu tüm endpoint'ler (DeepSeek, Groq, OpenRouter, Mistral, vLLM), Anthropic Claude, OpenAI ve yerel Ollama desteği ile hafif/ağır görev yönlendirmesi.
- 🧬 **Spatiotemporal Composability & Kendi Kendine Evrilen Çalışma Zamanı:** Model çalışma anında yeni REPL komutları (`synthesize_command`) veya yerleşik araçlar (`synthesize_tool`) üretebilir; context üzerinden yönetilen çalışma zamanı yan etkileri LIFO ters işlemleriyle ($\Omega$) geri alınır.
- 🩹 **Kendi Kendini Onaran Runtime (Servis Onarım Düzlemi):** Runtime bileşenleri için asla süreç yeniden başlatması gerekmez. `inspect_runtime` canlı fiber/coeffect/servis durumunu açığa çıkarır; `repair_runtime_service` bozulan bir bileşeni (LSP sunucusu, test koşucusu, linter veya kabuk komutu) teşhis eder, yedek komutları izole bir alt-bağlamda ön-uçuş doğrulamasından geçirir ve onarılmış servisi canlı yeniden sağlar — oturum durumu, önbellekler ve konuşmalar korunur. `provide_service` yeni servisleri çalışma anında kaydeder. Onarım probe’ları süre sınırlı ve disposable’dır; başarısız promotion veya persistence oturum durumunu geri yükler. Başarıyla kaydedilen operator config’i lifecycle cleanup sonrasında kalır. Probe ve rollback sözleşmesi için [runtime repair](RUNTIME_REPAIR.md) belgesine bakın.
- 📋 **Yapılandırılmış Goal Defteri (SKILL.state uyarlaması):** `!goal` döngüsü, kayıplı konuşma belleğine güvenmek yerine rev-korumalı bir ΔΣ defteri tutar (hedef, görevler, bulgular, kararlar, açık sorular, ortam notları). Maestro onu salt-kök `update_goal_ledger` aracıyla günceller (sınıflandırılmış syntax/schema/conflict geri bildirimi, sınırlı retry); güncel Σ her sıkıştırma katmanından sabitlenerek geçer ve her adımda yeniden enjekte edilir; her revizyon depoya eklenir (`goal-ledger` ref); bildirimsel `verify` spec'leri adım sınırlarında yeniden kontrol edilir (başarısız kontrol görevi `stale`e çevirir — dünya-kayması sinyali); banked araç sonuçları satır-bazlı `<absorbed_into_ledger>` mezar taşlarına sıkışır. Varsayılan AÇIK (`goal.ledger.*`, operatör-only; anahtar bazında opt-out).
- 🧹 **Bağlam Budayıcı (yarı deterministik pencere temizliği):** Uzun oturumlar maestro'nun konuşma penceresinde bayat keşif izleri biriktirir. Vakanüvis tarzı iki-düzeyli budayıcı bunları temizler: sessiz bir LLM subagent'ı keep/drop/summarize planı önerir; harness planı deterministik olarak doğrular (hedef sabitleme, araç-use eşleşmesi, baş/kuyruk koruma bantları, token bütçesi) ve turn sınırında atomik olarak uygular — asla turn ortasında değil. Girdi tavanının %60'ında (kör drop-oldest trim'inden önce) otomatik ateşlenir ya da `prune_context` aracı ve `!prune` ile isteğe bağlı çalışır. 2026-10-10'dan beri DEFAULT AÇIK (`subagents.pruner.*`, operatör-only; opt-out `enabled: false`); deterministik sıkıştırma yığını her zaman güvenlik ağı olarak kalır.
- 🔌 **Drop-in Eklenti Sistemi (Kullanıcı Eklentileri):** `~/.rubik/plugins` (küresel) veya `.rubik/plugins` (proje) altındaki drop-in `.rb` dosyaları veya dizin paketleri dinamik olarak yüklenir (`!plugin add`, `!plugin reload`). Bütünlük, `.manifest.json` içindeki SHA-256 özetleriyle (dizin paketleri için tüm dosya ağacı) doğrulanır. Eklentiler ana süreçte doğrudan Ruby kodu çalıştırır; manifest mekanizması izinsiz veya değiştirilmiş dosyaları engeller ancak eklentinin çalışma anı davranışını izole/sandbox etmez. Manifest içermeyen yabancı depolarda açık operatör onayı gerekir (`RUBIK_BOOTSTRAP_OVERLAYS=1` / `RUBIK_TRUST_OVERLAYS=1`). Bkz. [PLUGINS.md](PLUGINS.md).
- 🔌 **Model Context Protocol (MCP) ve Spatiotemporal Araç İzolasyonu:** Harici MCP sunucularını (`filesystem`, `fetch`, veritabanları, GitHub vb.) stdio taşıması üzerinden dinamik ekler (`!mcp connect`, `!mcp add`). Keşfedilen araçlar kayıt defterine `Rubik::Tools::BaseTool` proxy'si olarak katılır; bir sunucu durduğunda veya çöktüğünde kayıtlı LIFO temizlik ters işlemleri ($\Omega$) alt süreçleri durdurup proxy araçlarını kaldırır; bu işlemler başarılı olduğunda artık süreç ve geçersiz araç çağrısı riskini azaltır.
- 📺 **Kademeli Canlı Ajan İzleme (Step Formatter & Verbosity):** `quiet`, `normal`, `verbose` ve `debug` düzeyleriyle adım ilerlemesi, araç çağrıları, yürütüm süreleri ve ara düşünceler gerçek zamanlı izlenir (`!verbosity`, `!verbose`).
- 🎨 **Hibrit TUI Display Katmanı:** `⏺/⎿` ajan akış dili, Türkçe fiil döngülü canlı spinner (`✻ Kavuruyor… 4sn`), prompt üstü statusline (model · bağlam yüzdesi · kirli tampon), canlı markdown render'ı, renkli diff görüntüleyici, tek tuş hızlı onaylar ve `!agents` etkileşimli fiber panosu. `NO_COLOR`/`--no-color` ve boru modunda çıktı düz metne döner; oturum kayıtları asla ANSI kodu içermez (`!config set ui.*` ile canlı ayar).
- ⚡ **Native Araç Hızlandırma:** Sistemde varsa `grep_search` ripgrep'e, bağlam taraması `git ls-files`'a devredilir; AST sembolleri tembel gövde yüklemesiyle ısınır. rg/git yoksa, `tools.native: off` ya da `RUBIK_NATIVE=off` ile her yol saf Ruby'ye özdeş çıktıyla döner — çıktı formatı asla değişmez.
- 🧵 **Sessiz Eşzamanlılık (Fiber Scheduler Olay Döngüsü):** Saf-stdlib `Rubik::Concurrency` katmanı, mevcut bloklayan I/O çağrı noktalarını (Net::HTTP, sleep, Open3 boruları, Mutex/CV/Thread#join) DEĞİŞTİRMEDEN tek iş parçacığında işbirlikçi eşzamanlılık sağlar: binlerce eşzamanlı ağ isteği, MCP boot fan-out'u ve subagent provider havuzu `Concurrency.silently`/`.map` sınırı üzerinden koşar (GVL nedeniyle CPU paralelliği değil). Kill-switch: `RUBIK_FIBER_SCHEDULER=off`.
- 📜 **Vakanüvis Kronikçisi (Oturum Annalleri):** Deterministik harness, REPL kök-turn'lerini ve subagent yaşam olaylarını `rubik://storage` annal'ına kaydeder; bütçe-sınırlı LLM damıtıcısı (distiller) bu annallerden bellek ve wiki iskeleti damıtır. Tüm düzlemler `subagents.vakanuvis.*` ile yönetilir; Vakanüvis aracı ile kronikler geri çağrılabilir (`recall`/`record`/`forget`/`digest`).

> 🛡️ **Güvenlik notu — yabancı depo klonlarken:** `.rubik/commands` ve `.rubik/tools` dizinleri çalışma anında yorumlanabilen overlay dosyaları içerir. SHA-256 manifest doğrulaması sonradan değişimi engeller; manifest'siz sentinel başlıklı dosyalar ise yalnızca `RUBIK_BOOTSTRAP_OVERLAYS=1` açık rızasıyla ilk taramada kabul edilir. Bilmediğiniz bir depoyu klonladıysanız ilk çalıştırmadan önce `.rubik/` dizinini denetleyin.

---

## 🕹️ REPL Bang Komutları

Tüm 30+ etkileşimli komutun detaylı parametreleri, bayrakları ve kullanım senaryoları için:  
👉 **[COMMANDS.md — Kapsamlı REPL Komut Kılavuzu](COMMANDS.md)** belgesine göz atın.

### Özet Komut Tablosu

| Komut Grubu | Önemli Komutlar | Açıklama |
| :--- | :--- | :--- |
| **Model & Sağlayıcı** | `!provider`, `!providers`, `!model` | Sağlayıcı ekleme/silme (CRUD), model rol ataması ve akıllı yönlendirme. |
| **Ajan & Planlama** | `!plan`, `!goal`, `!steps` | Adım adım planlama, otonom hedef döngüsü ve adım bütçesi yönetimi. |
| **Tampon & Snapshot** | `!diff`, `!apply`, `!autoapply`, `!undo` | Bellek içi sanal dosya tamponu inceleme, diske kaydetme ve geri alma. |
| **Runtime & Fiberler** | `!runtime`, `!fibers`, `!services` | Coeffect servisleri, aktif/bekleyen fiberler ve $\Omega$ ters işlem derinliği. |
| **Kod Zekası & LSP** | `!lsp`, `!symbols`, `!outline`, `!refs` | Derleyici hata teşhisi ve semantik AST graf aramaları. |
| **Test & Yürütüm** | `!test`, `!lint`, `!format`, `!sh`, `!sandbox` | Çok dilli test koşumu, Safe Execution ve tak-çıkar sandbox (bwrap/docker/podman). |
| **Oturum & Ayarlar** | `!session`, `!history`, `!config`, `!verbosity`, `!status` | Oturum kaydetme, `rubik -c` ile devam etme, ayrıntı düzeyi ve canlı ayarlar. |
| **Çalışma Alanı & Kökler** | `!workspace`, `!roots`, `!allow` | Çoklu kök dizin ekleme/çıkarma (`add`/`remove`), harici izinler (`!allow`) ve durum listeleme. |

### Ajan Yüzeyi Kontratı

Her komut kayıt anında bir `audience` kitlesiyle tip'lenir: `:human` (yalnız operatör), `:agent`, `:both`. Ajan-görünür built-in komutlar (`!diff`, `!status`, `!undo`, `!rollback`, `!autoapply`, `!context`, `!steps`, `!config`, `!model`, `!providers`, `!runtime`, `!fibers`, `!services`, `!agents`, `!lint`, `!format`, `!history`, `!prune`) sistem isteminde `<agent_commands>` olarak yayınlanır ve `exec_repl_command` aracıyla çağrılabilir; dosya, kod, test ve kabuk işlemleri ise her zaman doğrudan araçlarla (`read_file`, `write_file`, `run_tests`, `run_command`) yapılır. Yalnız-insan komutları (`!provider`, `!workspace`, `!allow`, `!verbosity`, …) ajana steering mesajıyla bildirilir; oturum yaşam döngüsü komutları (`!quit`, `!exit`, `!clear`, `!reset`) ajan için sert blokludur, `!plan`/`!goal` ise reentrancy korumasıyla "finish" aracına yönlendirilir. İki not: `!model` geçişi etkinliği bir sonraki ajan koşusunda başlar; `!undo`/`!rollback`, henüz diske uygulanmamış tampon değişikliklerini geri alırken `buffer.auto_apply` = `on_test`/`always` modunda koşum öncesi otomatik uygulama tetikleyebilir.

---

## ⚙️ Yapılandırma

Tüm model, LSP, tampon politikası, sağlayıcılar ve sandbox ayarları hakkında detaylı bilgi için:  
👉 **[CONFIG.md — Rubik Yapılandırma Kılavuzu](CONFIG.md)** belgesine göz atın.

---

## 🖥️ Ajan Kabuk Davranışı

`run_command` komutları örtük bir yorumlayıcıya bırakılmaz: Safe Execution altyapısı, her komutu **çözülmüş bir kabukla** açık argv dizisiyle çalıştırır. `sandbox.shell: auto` (varsayılan) komut başına sözdizimi kapısıyla seçer — bash-zorunlu sözdizimi (`<(...)`, `/dev/null`, heredoc) ve `$`-ikameleri **bash**'e, PowerShell parmak izi (`$env:`, `Select-String`, `Get-*` vb. cmdlet'ler) **pwsh**'e, düz komutlar ise Windows'ta hızlı yoldan **cmd**'e gider (diğer platformlarda bash). Seçim sonuçta etiketlenir (`[EXIT 1] (bash)`) ve sistem istemi, kabuk davranışını `<environment>` satırıyla modele önceden bildirir — model artık hangi kabuk için komut yazdığını bilir. Sabit tercih için `sandbox.shell: bash|pwsh|cmd|sh` kullanın (bkz. [CONFIG.md](CONFIG.md) §7).

---

## 🧪 Test Paketi

Tam paket: `rake` (veya `rake test`). Tek dosya: `ruby -Itest test/unit/test_repl.rb`.

Windows notları:
- Testler tek süreçte sırayla koşar; `ruby -Itest a.rb b.rb` biçimindeki çoklu dosya argümanı yalnızca **ilk** dosyayı çalıştırır — tam paket için daima `rake` kullanın.
- `rake test TEST="a b"` gibi boşluklu `TEST` değeri Windows'ta tek yol olarak yorumlanır; dosya başına ayrı çağrı yapın.
- Geçici dizin silinimi (`teardown`) Windows'ta tanıtıcı henüz kapanmadığında `Errno::EACCES` ile başarısız olabilir; `test_helper.rb` içindeki `remove_temp_dir` yardımcısı en iyi çaba yeniden denemesiyle bunu yutar ve test sonucunu bulanıklaştırmaz.

Çevresel test atlamaları (*Environmental test skips*):
- Sistemde `pwsh` (PowerShell Core) ikilisi bulunmadığında PowerShell kabuk yürütüm testleri atlanır (`skip`).
- Sistemde `prism` gem'i veya C eklentisi bulunmadığında alternatif AST ayrıştırıcı testleri atlanır.
- Non-interactive / headless CI ortamlarında doğrudan TUI/reline uçbirim testleri otomatik olarak non-blocking modda koşar veya kontrollü atlanır.
- Yetenek atlamaları (skips) nedenlerini raporlar; beklenmeyen hatalar CI'ı başarısız kılar. Başarılı bir koşu, o commit ve çalıştırıcı ortamını yansıtır; evrensel bir platform garantisi anlamına gelmez.

---

## 📦 Sürüm Politikası & SemVer 2.0 (Pre-1.0 Kararlılık Yol Haritası)

Rubik, [Semantic Versioning 2.0.0](https://semver.org/) standardını benimser. Mevcut pre-1.0 sürümünde (`0.1.0`), Spatiotemporal Composability çekirdek mimarisi, fiber yaşam döngüsü ve ajan protokolleri sertleştirilmekte olup:
- **0.x Sürümleri:** Hızlı mimari evrim ve deneysel yeteneklerin rafine edilmesi aşamasıdır. Çekirdek API'lerdeki geliştirmeler plan dokümanları eşliğinde yönetilir.
- **1.0.0 Hedefi:** Çekirdek SPI arayüzlerinin, Revertible Effects LIFO protokolünün ve ajan yüzeyi kontratının dondurulması ile üretim kararlılığına ulaşılmasıdır.
- **Geriye Dönük Uyumluluk:** Her minör sürüm öncesinde kapsamlı geriye dönük uyumluluk ve SPI kırılma analizleri (GitNexus knowledge graph & PDG analizi ile) zorunlu kılınmıştır.

---

## 📚 Dokümantasyon

Her kılavuz ikili bir çift olarak gelir — `X.md` (İngilizce, esas) yanında `X.tr.md` (Türkçe çeviri).

### Mimari & İç Yapı

| Kılavuz | Kapsam |
| :--- | :--- |
| 🌌 [AGENTS.md](AGENTS.md) | Spatiotemporal Composability Protokolü — kuram, değişmezler, fiber yaşam döngüsü durum makinesi. |
| 🏗️ [ARCHITECTURE.md](ARCHITECTURE.md) | 30 çekirdek domain ve sorumluluk matrisi. |
| 🧬 [SELF_EVOLUTION.md](SELF_EVOLUTION.md) | LLM'in araçları nasıl sentezlediği, servisleri onardığı ve kendi runtime'ını nasıl evrilttiği. |
| 🔌 [API.md](API.md) | Runtime'ı Ruby'den gömme: config, araç kayıt defteri, sağlayıcı kontratı, orkestratör döngüsü, hata kontratları. |

### Kullanıcı & Operatör Kılavuzları

| Kılavuz | Kapsam |
| :--- | :--- |
| 🕹️ [COMMANDS.md](COMMANDS.md) | Parametreleri ve kullanım senaryolarıyla tüm 30+ REPL bang komutu. |
| 🧰 [TOOLS.md](TOOLS.md) | 34 yerleşik ajan aracı kataloğu: parametreler, risk sınıfları, teşhisler. |
| ⚙️ [CONFIG.md](CONFIG.md) | Tüm yapılandırma ayarları (modeller, LSP, tampon politikası, sandbox, subagents, pruner…). |
| 🌍 [ENV.md](ENV.md) | Ortam değişkenleri — tek konsolide referans tablosu. |
| 🖥️ [LSP.md](LSP.md) | Adım adım dil sunucusu kurulumu ve teşhis gezintisi. |
| 🔌 [PLUGINS.md](PLUGINS.md) | Drop-in eklenti sistemi: yerleşim, manifest'ler, sıfır-kesinti yeniden yüklemeler. |

### Proje & Politika

| Kılavuz | Kapsam |
| :--- | :--- |
| 🤝 [CONTRIBUTING.md](CONTRIBUTING.md) | Geliştirici kurulumu, test komutları, commit/PR kuralları, güvenlik bildirimi. |
| 🧪 [TESTING.md](TESTING.md) | Süiti koşma, adlandırma kuralları, test şablonları, flaky-test politikası. |
| 🔒 [SECURITY.md](SECURITY.md) | Komut kapısı, kritik-yazı koruması, sentez kapıları, sandbox, denetim günlüğü. |
| 📜 [ATTRIBUTION.md](ATTRIBUTION.md) | Açık kaynak atıfları ve üçüncü taraf bildirimleri. |
| 📜 [CHANGELOG.md](CHANGELOG.md) | Tematik sürüm geçmişi; tam kayıt `git log`'da. |
| 📄 [LICENSE](LICENSE) | Yazılım lisansı (MIT). |
