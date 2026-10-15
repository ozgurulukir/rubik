# Ortam Değişkenleri

> Bu belge, [`ENV.md`](ENV.md) dosyasının Türkçe çevirisidir ve güncelliğini yitirmiş olabilir; çelişki halinde İngilizce sürüm esastır.

Rubik'in okuduğu her ortam değişkeni için birleştirilmiş başvuru kaynağı (`lib/`, `bin/`, `test/` taramasıyla doğrulanmıştır, 2026-09-29). `Dir.home` / `Dir.tmpdir`, `ENV`'e kendileri başvuran Ruby stdlib çağrılarıdır; ilgili yerlerde davranışları Ayrıntılar bölümlerinde not edilmiştir.

| Değişken | Amaç | Nerede okunur | Tanımsızken davranış |
| :--- | :--- | :--- | :--- |
| `HOME` | Yapılandırma/plugin/overlay/oturum depolaması için ev dizini | `platform.rb:74` (`Dir.home` üzerinden), `config.rb:26`, `plugin/storage.rb:18`, `runtime/overlay_storage.rb:21`; `test/test_helper.rb:8` tarafından yazılır | Fallback zincirleri devreye girer (aşağıda); son fallback `"."` |
| `USERPROFILE` | Windows ev dizini fallback'i | `platform.rb:76`, `config.rb:28`, `platform/path.rb:188` (sandbox kök listesi) | Zincirde atlanır; ayrıca Windows tehlikeli-kökler listesinden de hariç tutulur |
| `HOMEDRIVE`, `HOMEPATH` | Windows ev dizini fallback'i (sürücü + yol ikilisi) | `platform.rb:76-79` | **İkisi de** ayarlı olmadıkça atlanır |
| `PATH` | Komut çözümlemesi için çalıştırılabilir arama yolu | `platform/path.rb:36` | Boş (`""`) kabul edilir — PATH üzerinden hiçbir çalıştırılabilir bulunamaz |
| `PATHEXT` | Çözümleme sırasında denenen Windows çalıştırılabilir uzantıları | `platform/path.rb:56` | Sabit kodlanmış varsayılan `.COM;.EXE;.BAT;.CMD;.VBS;.JS;.WS;.MSC;.PS1` |
| `TERM` | Terminal yetenek algılaması (`dumb` rengi kapatır) | `ui/capability.rb:80` | Etkisi yok; renk TTY algılamasına göre belirlenir |
| `TEMP`, `TMP` | Geçici dizin fallback'leri | `platform.rb:85` (`Dir.tmpdir` rescue'su) | Son fallback `/tmp` |
| `TMPDIR` | Geçici dizin (yalnızca dolaylı) | `platform.rb:83`, Ruby'nin `Dir.tmpdir`'i üzerinden (stdlib); doğrudan asla okunmaz | stdlib bir sonraki adayı seçer (`TEMP`/`TMP`/sistem varsayılanı) |
| `NO_COLOR` | Tüm ANSI rengini kapatır (boş olmayan herhangi bir değer) | `ui/capability.rb:73`; `bin/rubik:55` tarafından yazılır (`--no-color`) | Etkisi yok |
| `CLICOLOR_FORCE` | TTY olmasa bile rengi zorlar (yalnızca `"1"`) | `ui/capability.rb:74`; `bin/rubik:59` tarafından yazılır (`--color`) | Etkisi yok |
| `RUBIK_DEBUG` | Koşula bağlı `[WARN]` teşhislerini etkinleştirir (truthy denetimi) | 11 nokta: `platform.rb:32`, `repl/lifecycle.rb:364` (yardımcılar) + doğrudan okumalar: `ast/extractor.rb:67`, `ast/treesitter_extractor.rb:97`, `config/store.rb:40`, `plugin/storage.rb:34`, `runtime/overlay_storage.rb:46,268,472`, `session/recorder.rb:23`, `ui/theme.rb:103` | Sessiz; bilinçli `rescue`-ve-fallback yolları görünmez kalır |
| `RUBIK_TEST` | Test modu: deterministik, etkileşimsiz davranış | `ui/capability.rb:44,72`, `repl/confirmations.rb:39`, `repl/lifecycle.rb:136,151` (`ast.async_warm` + `mcp.async_load` ortam-duyarlı varsayılanları), `runtime/overlay_storage.rb:221`, `tools/builtins/synthesis.rb:123`; `test/test_helper.rb:10` tarafından ayarlanır | Normal etkileşimli davranış |
| `RUBIK_VAKANUIS_FORCE` | Yalnızca test için kaçış kancası: RUBIK_TEST zırhını kaldırır, böylece Vakanüvis kronikçisi test kabuklarında bağlanır (yalnızca `"1"`) | `storage/vakanuvis/service.rb` (`enabled?`); `test/unit/test_vakanuvis_harness.rb` setup'ı tarafından ayarlanır | `RUBIK_TEST` altında kronikçi bağlanmamış kalır (betik kabuğu testlerinde arka plan damıtıcısı doğmaz) |
| `RUBIK_FIBER_SCHEDULER` | Fiber-scheduler olay döngüsü (`Rubik::Concurrency`) için kill-switch: `"off"` değeri (büyük/küçük harf duyarsız) zamanlayıcıyı devre dışı bırakır, böylece bloklayan I/O düz thread'lerde çalışır | `concurrency.rb:109` (`@disabled`) | Fiber scheduler etkin kalır (varsayılan) |
| `RUBIK_LOG_LEVEL` | `Rubik::Log` için log ayrıntı düzeyi kapısı (`debug`/`info`/`warn`/`error`) | `log.rb:19` | Varsayılan `"warn"` |
| `RUBIK_NATIVE` | Native tool hızlandırması için geçersiz kılma (`auto`/`on`/`off`); `tools.native` config değerini ezer | `tools/native_search.rb:64`, `context/git_lister.rb:32` | `tools.native` config değerine, o da yoksa `"auto"` değerine düşer |
| `RUBIK_RG_PATH` | `grep_search` hızlandırmasının kullandığı ripgrep binary'sinin tam yolu; PATH aramasını ezer | `tools/native_search.rb:51` | rg `PATH` üzerinden çözümlenir |
| `RUBIK_TRUST_OVERLAYS` | Güvenlik kaçış kancası: tüm plugin/overlay'lere hash doğrulaması olmadan güvenir (yalnızca `"1"`) | `plugin/storage.rb:77`, `runtime/overlay_storage.rb:352` (`trust_mode?`) | Tam SHA-256 manifest doğrulaması uygulanır |
| `RUBIK_BOOTSTRAP_OVERLAYS` | Opt-in: manifest yokken ilk taramada sentinel overlay dosyalarının kabulü (yalnızca `"1"`) | `runtime/overlay_storage.rb:412` (`bootstrap_opt_in?`) | Kayda geçirilmemiş sentinel dosyaları `[BOOTSTRAP]` bildirimiyle atlanır |
| `BASH_CLASSIFY_CONFIG_DIR` | Kullanıcı komut-sınıflandırma kuralları için dizin geçersiz kılması (önceliği vardır) | `security/classifier/database.rb:25` | Sıradaki aday (`RUBIK_COMMAND_CONFIG_DIR`), sonra varsayılan |
| `RUBIK_COMMAND_CONFIG_DIR` | Yukarıdakiyle aynı, önceliği düşük | `security/classifier/database.rb:25` | Varsayılan `~/.config/rubik/commands` |
| `XDG_CACHE_HOME` | Yalnızca test: `HOME` yönlendirilirken gerçek önbellek dizinini korur | yalnızca `test/test_helper.rb:7,9`; `lib/` içinde okuyan yok | `||=` onu yalnızca tanımsızsa geri yükler |
| `SystemRoot`, `ProgramFiles`, `ProgramFiles(x86)`, `CommonProgramFiles`, `SystemDrive` | Windows sandbox: "tehlikeli sistem kökleri" yasak listesini genişletir | `platform/path.rb:184-190` | Söz konusu kökler basitçe eklenmez (`c:/windows` gibi sabit literaller kalır) |

## Ayrıntılar

### HOME / USERPROFILE / HOMEDRIVE / HOMEPATH

Üç farklı fallback zinciri mevcuttur (doğrulanmıştır):

- `Rubik::Platform.home_dir` (`platform.rb:73-80`): `Dir.home`; başarısızlık durumunda → `USERPROFILE` → `HOMEDRIVE + HOMEPATH` (birleştirilir; yalnızca **ikisi de** ayarlıyken) → `HOME` → `"."`.
- `Rubik::Config` (`config.rb:22-30`): tanımlıysa `Platform.home_dir`'i tercih eder; tek başına çalışırken fallback, `Dir.home` rescue'sudur (`USERPROFILE` → `HOME` → `"."`) — burada `HOMEDRIVE`/`HOMEPATH` ayağı yoktur.
- `Plugin::Storage` (`plugin/storage.rb:18`) ve `Runtime::OverlayStorage` (`runtime/overlay_storage.rb:21`): constructor kwarg'ı `ENV.fetch("HOME", nil)` varsayılanını kullanır, ardından `home_dir || ENV["HOME"] || "."` gelir. Yalnızca düz `HOME` — `HOME`'un olmadığı bir Windows sisteminde bunlar `"."`'e çözümlenirken `Platform.home_dir` `USERPROFILE`'ı çözümlerdi. Açık bir `home_dir:` geçen çağıranlar `ENV`'i tamamen bypass eder.

`Platform.home_dir` tüketicileri: `config.rb:23`, `ast/cache_store.rb:33` (AST önbelleği), `security/guard.rb:125` (`~/.rubik/audit.log` içindeki denetim günlüğü), `security/guard.rb:350` (ev-yolu eşitlik denetimi). İki storage sınıfı da global durumu `<home>/.rubik/` altına yerleştirir — `plugins` (`plugin/storage.rb:27`), `commands` ve `tools` (`runtime/overlay_storage.rb:30,38`); proje kapsamlı ikizler `<root_dir>/.rubik/` altında yaşar ve `ENV`'e dokunmaz. `Dir.home` kendisi POSIX'te `HOME`'u, Windows'ta ise `HOME`/`USERPROFILE`/`HOMEDRIVE+HOMEPATH`'i çözümler (Ruby stdlib); dolayısıyla açık rescue zincirleri yalnızca bunların tümü tanımsız veya geçersizken devreye girer.

### RUBIK_DEBUG

Bilerek yutulan istisnalar/rescue-fallback yollarına ait `warn "[WARN] ..."` teşhislerini koşula bağlar (bu gelenek `config/store.rb` içinde kurulmuştur; ayrıca hangi güvenlik uyarılarının bilerek koşula *bağlanmadığını* anlatan `security/guard.rb` yorumlarına bakın: 147/475/853). Denetim düz bir truthiness denetimidir: `if ENV["RUBIK_DEBUG"]` — Ruby'de ayarlı herhangi bir değer bunu etkinleştirir, **boş string dahil** (`RUBIK_DEBUG=""` truthy'dir). Yeniden kullanılabilir iki yardımcı vardır: `Rubik::Platform.debug_warn` ve `REPL::Lifecycle#debug_warn` (ikisi de asla raise etmez).

Alt sisteme göre okuma noktaları (tümü `if ENV["RUBIK_DEBUG"]`):

- `ast/`: çıkarım başarısızlığı uyarıları (`extractor.rb:67`, `treesitter_extractor.rb:97`)
- `config/`: config dizini oluşturma başarısızlığı (`store.rb:40`)
- `plugin/`: plugin dizini oluşturma başarısızlığı (`storage.rb:34`)
- `repl/`: yutulan lifecycle istisnaları (`lifecycle.rb:355`, kendi yardımcısı üzerinden)
- `runtime/`: overlay dizini oluşturma (`overlay_storage.rb:46`), tool kaydetme başarısızlığı (`:268`), sentinel denetimi başarısızlığı (`:472`)
- `session/`: sessions dizini oluşturma başarısızlığı (`recorder.rb:23`)
- `ui/`: bilinmeyen tema stilinin düz işlenmesi (`theme.rb:103`, stil başına bir kez)
- `platform/`: UTF-8 sanitasyonu ve atomik-yazma fallback'leri (`debug_warn` üzerinden, `platform.rb:28`)

### RUBIK_TEST

`test/test_helper.rb:10` tarafından `"1"` olarak ayarlanır. Üretimdeki semantiği karışıktır:

- Tam `"1"` karşılaştırmaları: renk zorla kapatılır ve spinner devre dışı bırakılır (`ui/capability.rb:44,72`); etkileşimli girdi/onaylar devre dışı bırakılır (`repl/confirmations.rb:39`); `ast.async_warm` ve `mcp.async_load`, tanımsızken `false` varsayılanına döner (yani testler altında senkron ısınma/açılış — `repl/lifecycle.rb:136,151`).
- Truthiness (`unless ENV["RUBIK_TEST"]`): bir overlay/özel komut, dispatch `CommandContext`'i olmadan çağrıldığında bir uyarıyı bastırır (`runtime/overlay_storage.rb:221`, `tools/builtins/synthesis.rb:123`) — burada `"0"` dahil herhangi bir değerin etkisi vardır.

### NO_COLOR / CLICOLOR_FORCE önceliği

Çözümleme sırası `UI::Capability.resolve_mode` içinde (`ui/capability.rb:71-85`): `RUBIK_TEST=1` → `NO_COLOR` (boş olmayan herhangi bir değer) → `CLICOLOR_FORCE=1` → config `ui.color: always|never` → `TERM=dumb` (büyük/küçük harf duyarsız) → TTY olmayan → Windows VT algılaması. **`NO_COLOR`, `CLICOLOR_FORCE`'u yener** (önce denetlenir). `NO_COLOR` boş olmayan herhangi bir değeri kabul eder; `CLICOLOR_FORCE` tam olarak `"1"` olmalıdır, diğer değerler yok sayılır. `bin/rubik` CLI bayrakları `--no-color` / `--color`, bu değişkenleri ayarlayarak çalışır (`bin/rubik:55,59`).

### TEMP / TMP / TMPDIR

`Platform.tmp_dir` (`platform.rb:82-86`), `TEMP || TMP || "/tmp"` rescue'suna sahip `Dir.tmpdir`'dir. `TMPDIR`'i Rubik kodu asla okumaz; `Dir.tmpdir`'e yalnızca Ruby'nin stdlib `tmpdir` kütüphanesi aracılığıyla ulaşır — bu kütüphane sistem varsayılanlarından önce `TMPDIR`/`TEMP`/`TMP`'i sınar (yazılabilirliği doğrulayarak). `Platform.tmp_dir`'in şu anda `lib/` içinde hiçbir çağıranı yoktur — tüketiciler için tutulan bir platform API'sidir (testler geçici dizinleri doğrudan `Dir.mktmpdir` ile oluşturur).

### Güvenlikle ilgili geçersiz kılmalar

- `RUBIK_TRUST_OVERLAYS=1` (tam eşleşme gerekir): plugin dosyaları için SHA-256 manifest doğrulamasını bypass eder (`plugin/storage.rb:77` derhal `:trusted` döner) ve `trust_mode?` aracılığıyla manifest durumu — eksik, bozuk veya kayda geçirilmemiş — ne olursa olsun **her** `*.rb` overlay dosyasını güvenilir sayar (`runtime/overlay_storage.rb:92-94, 385`). Overlay dosyaları `eval`'lendiğinden (`overlay_storage.rb:340`) bunu yalnızca güvenilir-geliştirme kaçış kancası olarak değerlendirin; güvenilmeyen klonlara karşı asla ayarlamayın.
- `RUBIK_BOOTSTRAP_OVERLAYS=1` (tam eşleşme): yalnızca bir dizinin `.manifest.json`'u **yokken** etkilidir. Sentinel başlıklı overlay dosyalarının (`# Rubik Custom Command:` / `# Rubik Custom Tool:`) tek seferlik kabulüne izin verir; hash'leri ardından kalıcı olarak manifest'e yazılır, böylece sonraki çalıştırmalarda ortam değişkenine gerek kalmaz. Bu olmadan, ilk taramadaki sentinel dosyalar görünür bir bildirimle atlanır; bilinmeyen dosyalar her durumda reddedilir (`overlay_storage.rb:105-108, 388-404`).
- `BASH_CLASSIFY_CONFIG_DIR` / `RUBIK_COMMAND_CONFIG_DIR` (`security/classifier/database.rb:24-28`): öncelik `BASH_CLASSIFY_CONFIG_DIR`'dedir; değer bir config köküdür — yükleyici sonuna `commands` ekler ve bu dizin varsa onu kullanır, aksi halde `Dir.home/.config/rubik/commands` yoluna düşer (o da yalnızca varsa). Kullanıcı kuralları, yerleşik komut sınıflandırma veritabanını genişletir.

### XDG_CACHE_HOME (yalnızca test)

Hiçbir `lib/` kodu onu okumaz. `test/test_helper.rb:7-9`, `HOME`'u geçici bir dizinle değiştirmeden önce gerçek önbellek dizinini yakalar ve onu yalnızca tanımsızsa geri yükler — böylece XDG önbellek konumlarına saygı duyan gem'ler/araçlar test altında çalışmaya devam eder.

### Windows sandbox kökleri

`Platform::Path#dangerous_system_roots` (`platform/path.rb:180-193`), Windows'ta ayarlı olduklarında `SystemRoot`, `ProgramFiles`, `ProgramFiles(x86)`, `CommonProgramFiles`, `USERPROFILE` ve `SystemDrive`'ı (`X:/` ve `X:` olarak) yazma-yasak listesine ekler. Her giriş koşulludur: tanımsız değişkenler, sabit literal köklerin ötesinde hiçbir şeye katkıda bulunmaz.

### Değer kabul kuralları (özet)

- Tam `"1"` gerekir: `RUBIK_TEST` (çoğu nokta), `RUBIK_TRUST_OVERLAYS`, `RUBIK_BOOTSTRAP_OVERLAYS`, `CLICOLOR_FORCE`.
- Boş olmayan herhangi bir değer: `NO_COLOR`.
- Ayarlı herhangi bir değer (truthy; boş string dahil): `RUBIK_DEBUG` ve `unless ENV["RUBIK_TEST"]` uyarı bastırma noktaları (`runtime/overlay_storage.rb:221`, `tools/builtins/synthesis.rb:123`).
- Dizin yolu: `BASH_CLASSIFY_CONFIG_DIR` / `RUBIK_COMMAND_CONFIG_DIR` (yalnızca `<value>/commands` varsa kullanılır).
