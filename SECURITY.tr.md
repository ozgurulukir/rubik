# Güvenlik Uygulamaları

> Bu belge, [`SECURITY.md`](SECURITY.md) dosyasının Türkçe çevirisidir ve güncelliğini yitirmiş olabilir; çelişki halinde İngilizce sürüm esastır.

Bu belge, kodda uygulandığı haliyle Rubik'in güvenlik mimarisini anlatır: komut gate'i, kritik yazma koruması (critical-write protection), sentez gate'leri, sandbox, çalışma alanı kapsaması (workspace containment) ve denetim günlüğü (audit log).

## Tehdit Modeli

Rubik bir agent harness'tır: bir LLM, kullanıcının makinesinde dosyalar yazar ve shell komutları çalıştırır. Güvenlik katmanı, model niyeti ile host üzerindeki etkiler arasındaki sınırdır — model çıktısı, her yürütme seam'inde güvenilmeyen bir girdidir. Her shell komutu, her dosya yazımı ve dinamik olarak sentezlenen her kod parçası, host'a ulaşmadan önce açık bir doğrulama gate'inden geçer. Gate'ler fail closed çalışır: bir karar üretilemediğinde (bilinmeyen binary, çözümlenemeyen yol, classifier hatası) eylem engellenir, izin verilmez.

## Komut Gate'i

Giriş noktası: `lib/rubik/security/guard.rb` içindeki `Guard#verify_command_safety!`; arkasında `lib/rubik/security/classifier/` altındaki classifier çalışır.

1. **AST sınıflandırması.** Komutlar eksiksiz bir sözdizimi ağacına ayrıştırılır (bash ve PowerShell parser'ları) ve tool başına kural dosyalarıyla eşleştirilir — `lib/rubik/security/classifier/commands/` altındaki 172 YAML kural tanımı —; bu dosyalar alt komutları, flag'leri, delegasyonu (`bash -c`, `sudo`, `xargs`), pipeline'ları ve yönlendirmeleri (redirect) kapsar. Kararlar: `readonly` / `local_effects` / `external_effects` (izinli), `dangerous` ve `unknown` (engelli).
2. **Aşılamaz blocklist.** `lib/rubik/security/guard.rb` içindeki `DANGEROUS_COMMAND_PATTERNS`, her komut üzerinde yedek (fallback) regex olarak çalışır — allowlist'teki ve safe-probe komutlar dahil. `rm -rf /`, `mkfs`, `dd ... of=/dev/`, fork bombaları, `shutdown`/`reboot`, yıkıcı Windows cmdlet'leri ile `format` ve interpreter'a pipe ile verilen RCE kalıbını (`curl|wget ... | sh`) engeller. Allowlist'te olmak bu listeyi aşamaz.
3. **Fail-closed unknown yönetimi.** Kural veritabanında bulunmayan bir binary `unknown` olarak sınıflandırılır ve engellenir (Plan 111 ile sertleştirildi). Engelleme mesajı operatör vanasına işaret eder. Onaylanmış tek `allow_unknown: true` çağrı noktası, dahili sentez ön kontrolüdür (bkz. Sentez Gate'leri).
4. **Operatör allowlist'i.** `security.command_allowlist`, token-önekli (token-prefix) girdiler tutar; örn. `node` (geniş) veya `node .gitnexus/run.cjs` (dar — tercih edilir). Bir girdi, ancak HER segmenti özyinelemeli olarak kapsıyorsa engellenmiş bir komutu kurtarabilir — pipeline iç segmentleri, wrapper iç segmentleri ve güvenli kardeş segmentler dahil. Tehlikeli builtin'ler olan `source` ve `.` asla kurtarılamaz. Allowlist değerlendirmesinin kendisi de hata durumunda fail closed davranır; felaket seviyesindeki yedek regex sonrasında yine de çalışır.
5. **Safe probe'lar.** `security.allow_safe_probes: true` (varsayılan) iken, argümanları tamamen `--version`, `-v`, `--help` veya `-h` olan tek komut muaf tutulur — yedek regex yine de çalışır. Bilinmeyen binary'ler probe muafiyeti almaz: onların `--version`'u hâlâ denetlenmemiş bir binary çalıştırır; vana allowlist'tir.

Classifier'ın kendisi çökerse gate, koşulsuz bir uyarı ve bir denetim kaydıyla yalnızca yedek regex'e geriler (belgelenmiş kalıntı risk, Plan 111).

## Kritik Yazma Koruması

`lib/rubik/security/guard.rb` içindeki `Guard#verify_path_write!`:

- **Kritik desenler.** `DEFAULT_CRITICAL_PATTERNS`: `.git/**`, `.env*`, `secrets.*`, `*.pem`, `*.key`, `id_rsa*` — ham yol, genişletilmiş yol ve pwd'ye göreli biçim üzerinde eşleştirilir. Operatörler desen ekleyebilir.
- **Bloktan önce symlink çözümlemesi.** Lexiksel kontrollerin ardından yol, `Rubik::Platform.resolved_path(path, strict: true)` ile çözümlenir. Çalışma alanının içine yerleştirilmiş bir symlink (`foo -> .git/config`) çözümlenmiş hedefte yakalanır; sarkan (dangling) symlink'ler ve çözümleme başarısızlıkları (symlink döngüsü, izin duvarı) yazımı fail closed biçimde engeller.
- **Atomik yazmalar.** Disk yazmaları `atomic_write` üzerinden yapılır (`lib/rubik/platform/filesystem.rb`): geçici bir dosyaya yaz, `fsync` yap, sonra `rename` et — asla önce-unlink —; böylece yarım yazılmış bir dosya asla gözlemlenemez ve rename anındaki TOCTOU penceresi kapatılır. Geçici Windows rename kilitleri yeniden denenir.
- **Çalışma alanı kökü güvenliği.** `Guard#verify_root_safety!`, tehlikeli sistem köklerini (`/`, `/etc`, `/home`, sürücü kökleri, ev dizini) çalışma alanı kökü olarak reddeder.

## Sentez Gate'leri

Sentezlenen tool/komut kodu (`lib/rubik/tools/builtins/synthesis.rb`), `lib/rubik/security/guard.rb` içindeki `Guard#verify_synthesis_safety!` tarafından daha hiç `eval` edilmeden reddedilir:

1. **Shell-classifier ön kontrolü**, `allow_unknown: true` ile — onaylanmış tek seam: Ruby kaynağı, shell classifier'ından meşru biçimde `unknown` olarak sınıflanır; ama tehlikeli shell kalıpları yine de engellenir ve felaket regex'i yine de çalışır.
2. **Regex deny desenleri** (`DANGEROUS_SYNTHESIS_PATTERNS`): `send` ailesi ve method-object yansıması (reflection), `eval`/`instance_eval`/`binding.eval`, `const_get`/`const_set`, `system`/`exec`/`spawn`/`fork`/`syscall`, `IO.popen`, `Open3.*`, `Process.*`, `Kernel.*`, yönetilmeyen thread'ler, backtick'ler ve `%x`.
3. **AST gezinmesi** (`RubyVM::AbstractSyntaxTree`):
   - Yasak node türleri: `xstr`, `dxstr`, `defn`, `defs`, `class`, `sclass`, `alias`, `undef`, `gvar`, `gasgn`.
   - Yasak çağrılar (herhangi bir biçimde): eval ailesi, `system`/`exec`/`spawn`/`fork`, `popen`/`Open3` yakalama kümesi, `send` ailesi, dosya yıkıcıları (destructor), `load`/`autoload`.
   - Yalnızca **çıplak (bare)** çağrılar yasak: `require`, `require_relative`, `load`, `autoload` — alıcı (receiver) biçimindeki `ctx.require('database')` (her sentezlenen tool'un dayandığı coeffect erişicisi) tasarım gereği izinli kalır.
   - Yasak alıcı (receiver) sabitleri: `IO`, `File`, `Dir`, `FileUtils`, `Process`, `Kernel`, `Open3`, `RubyVM`, `Object`, `Class`, `Module`, `BasicObject`, `Thread`, `ENV`, `ObjectSpace`, `STDIN`/`STDOUT`/`STDERR`/`ARGF`, `Signal`.
   - Ağ/serileştirme sabitleri, yalnızca çağrı alıcısı olarak değil **herhangi bir** referansta yasaktır: `Socket`, `IPSocket`, `TCPSocket`, `TCPServer`, `UDPSocket`, `UNIXSocket`, `UNIXServer`, `Net`, `Marshal`. Üst düzey kapsam (`::TCPSocket`) ve takma ad kullanımı (aliasing) (`X = TCPSocket; X.new`) ikisi de kapsanır.

Her ret, değerlendirmeden önce `BlockedWriteError` fırlatır; sözdizimi hatası içeren kod, bir saldırı olarak yanlış sınıflanmak yerine normal `SyntaxError` yoluna bırakılır. İsteğe bağlı bir pre-flight yürütmesi, handler'ı kayıttan önce izole bir alt süreçte çalıştırır (`lib/rubik/tools/preflight_runner.rb`).

## Sandbox

Komut gate'i politiktir; sandbox (`lib/rubik/sandbox/`) ise isteğe bağlı çekirdek düzeyi izolasyondur. **Varsayılan olarak devre dışıdır** (`sandbox.enabled: false`): komutlar, komut gate'i aktif ve bir `chdir` kök kontrolü eşliğinde doğrudan güvenli host yürütmesi olarak çalışır; ağ izolasyonu yoktur — Rubik bu modda yanıltıcı proxy ortam değişkenleri enjekte etmez. Gerçek ağ/dosya sistemi izolasyonu sandbox'ı etkinleştirmeyi gerektirir: Bubblewrap (`--unshare-net`, host `/` salt okunur, çalışma alanı okuma-yazma) veya Docker/Podman (`--network none`, mount ve cgroup limitleri). Bir `process` driver'ı doğrudan-host modunu sağlar; ek driver'lar eklenti (plugin) olarak kaydedilebilir.

| Anahtar | Varsayılan | Anlam |
| :--- | :--- | :--- |
| `sandbox.enabled` | `false` | İzolasyon kafesini etkinleştir (veya `!sandbox on`) |
| `sandbox.driver` | `bwrap` | `bwrap`, `docker`, `podman`, `process` veya plugin driver |
| `sandbox.image` | `rubik-sandbox:latest` | Container driver'lar için container imajı |
| `sandbox.timeout_seconds` | `15` | Komut başına yürütme zaman aşımı |
| `sandbox.memory_limit_mb` | `512` | Bellek limiti |
| `sandbox.cpus` | `"1.0"` | CPU limiti |
| `sandbox.allow_network` | `false` | Kafes içinde ağ erişimi |
| `sandbox.shell` | `auto` | Komut başına shell seçimi (`auto`, `bash`, `pwsh`, `cmd`, `sh`) |
| `network.allow` | `false` | Agent kaynaklı istekler için global ağ erişimi |

## Çalışma Alanı Kapsaması

Tüm tool dosya erişimi `Buffer::Manager#sanitize_path` üzerinden geçer (`lib/rubik/buffer/manager.rb`):

- Kapsama (containment), önek kontrolünün **her iki** tarafında da symlink'leri çözümler; böylece çalışma alanının içine yerleştirilmiş bir link, okumaları veya yazmaları alanın dışına yönlendiremez. İhlaller `Buffer::InvalidPathError` fırlatır.
- Yazmalar, ek olarak köke sabitlenmiş genişletilmiş yol üzerinde de `Guard#verify_path_write!` kontrolünden geçer.
- Dış konumlar **opt-in**'dir: birincil çalışma alanı kökünün dışına yazmak için `workspace.allow_external_writes: true` gerekir (ya da kök/dizinin `--rw` ile eklenmesi).

| Anahtar | Varsayılan | Anlam |
| :--- | :--- | :--- |
| `workspace.additional_roots` | `[]` | Ek çalışma alanı kökleri |
| `workspace.allowed_external_dirs` | `[]` | Agent'ların dokunabileceği tekil dış dizinler |
| `workspace.allow_external_writes` | `false` | Dış kök/dizinler için global yazma izni |

**Apply anında TOCTOU yeniden doğrulaması.** `Buffer::Manager#apply!`, her atomik yazmadan hemen önce kapsamayı yeniden kontrol eder: buffering ile apply arasında değiştirilmiş bir symlink, yazının çalışma alanının dışına düşmesine izin vermek yerine yazımı gürültülü biçimde engeller.

## Denetim Günlüğü

- **Varsayılan konum:** `~/.rubik/audit.log` (`lib/rubik/security/guard.rb` içindeki `Guard.default_audit_log_path`; çağrı anında `Platform.home_dir`'den çözümlenir).
- **Anahtar:** `security.audit_log_path` çalışma zamanında bağlanır (canlı yeniden yapılandırılabilir, sıfır restart) ama `lib/rubik/config/defaults.rb` içindeki şema varsayılanlarında bilinçli olarak yer almaz — varsayılanın tek kaynağı Guard'dır. Açık bir `null`/boş değer denetimi **devre dışı bırakır**; yol olmayan bir değer uyarı verir ve devre dışı bırakır.
- **Biçim:** JSON Lines — `{ts, action, details}`. Olaylar arasında `blocked_write`, `blocked_command`, `blocked_synthesis`, `allowed_command`, `safe_probe` ve `classifier_error` yer alır. Detaylar, yazılmadan önce redactor'dan (`lib/rubik/security/redactor.rb`) geçer.
- **Bilinen sınırlar** (Plan 111'in ertelenmiş borçları): günlük, kurcalama kanıtı olmayan (HMAC/zincir yok) düz bir append'dir; allow-path'lerinden dönüşler kayda geçmez. Denetim izini, yükseltilene kadar bir uyumluluk kontrolü olarak değil, teşhis aracı olarak değerlendirin.

| Anahtar | Varsayılan | Anlam |
| :--- | :--- | :--- |
| `security.audit_log_path` | `~/.rubik/audit.log` | Denetim hedefi; `null`/boş devre dışı bırakır |
| `security.command_allowlist` | `[]` | Token-önekli komut allowlist girdileri |
| `security.allow_safe_probes` | `true` | `--version`/`--help` biçimli probe'ları muaf tutar |

## Güvenlik Açıklarını Bildirme

Bir güvenlik açığı bulursanız, lütfen **herkese açık bir issue açmayın**. GitHub'ın **özel güvenlik açığı bildirimi** (private vulnerability reporting) akışını kullanın: deponun **Security** sekmesini açın ve **Report a vulnerability** düğmesine tıklayın — bildirim, sürdürücülere özel olarak iletilir; düzeltme ve advisory süreçlerini GitHub üzerinden koordine edebilirsiniz. (Sekme kullanılamıyorsa, sürdürücüyle GitHub profili üzerinden doğrudan iletişime geçin.) Lütfen bir açıklama, yeniden üretim adımları ve etkilenen commit'i ekleyin; kamuya açıklamadan önce düzeltme için zaman tanıyın.

## Doğrulama Yüzeyi

Yukarıdaki gate'ler, `test/unit/` altındaki unit test takımlarıyla sabitlenmiştir:

- `test_command_classifier_{bash_parser,pwsh_parser,matcher,database,models,integration,sweep}.rb` — komut classifier'ı ve onun kural veritabanı.
- `test_critical_write_guard.rb` — kritik yazma desenleri, symlink çözümlemesi, komut gate'i ve allowlist semantiği.
- `test_synthesis_security.rb` — sentez deny katmanları; `ctx.require` regresyon koruması dahil.

Burada anlatılan davranışı kendi checkout'unuz üzerinde doğrulamak için test takımını depo kökünden çalıştırın.
