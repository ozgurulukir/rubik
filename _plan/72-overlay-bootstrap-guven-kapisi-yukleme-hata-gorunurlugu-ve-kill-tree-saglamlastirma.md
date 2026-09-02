# Plan 72 — Overlay Bootstrap Güven Kapısı, Yükleme Hata Görünürlüğü ve kill_tree Sıkılaştırma

> **Domain:** Güvenlik / Overlay Storage / Platform Sağlamlaştırma
> **Kaynak:** Dış değerlendirme (Eylül 2026) — "Findings 1, 2, 5" (bootstrap trust path, swallowed load errors, string-form `taskkill`)
> **Durum:** ✅ Tamamlandı
> **Öncül Planlar:** [63](63-dis-degerlendirme-tavsiye-triyaji-ve-davranis-koruyucu-iyilestirmeler.md) · [64](64-overlay-yukleme-butunluk-kapisi-ve-eval-guvenligi.md) · [68](68-sifir-kurulum-kullanici-eklenti-mimarisi-dropin-dizinler-ve-yonetim-hatti.md) · [71](71-calisma-zamani-saglamlastirma-lsp-devre-kesici-buffer-thread-safety-ve-izole-testler.md)

---

## 1. Amaç

Eylül 2026 dış değerlendirmesindeki beş bulgudan üçünü gidermek:

1. **Bootstrap güven yolu kapatılır** (Faz A): sentinel başlık taşıyan herhangi bir dosya, manifest dolu olsa bile ilk açılışta otomatik güvenilip `eval` edilebiliyor. Bootstrap, gerçek anlamda **tek seferlik geçiş** haline getirilir.
2. **Yutulan yükleme hataları görünür olur** (Faz B): `load_all` / `load_tools` içindeki boş `rescue StandardError` blokları, bozuk overlay'in sessizce kaybolmasına neden oluyor; `[SECURITY]` uyarılarıyla aynı görünürlükte kayıt eklenir.
3. **`Platform.kill_tree` dizi-form `system` çağrısına geçer** (Faz C): Windows'taki string-interpolasyonlu `taskkill` çağrısı, kod tabanının geri kalanıyla tutarlı hale gelir.

## 2. Değerlendirme ve Triyaj (kod tabanından doğrulama)

| # | Bulgu | Hüküm | Kanıt | Karar |
| :--- | :--- | :--- | :--- | :--- |
| 1 | Bootstrap yolu sahte sentinel başlıklı dosyaya otomatik güveniyor | **Haklı (orta risk)** | `lib/rubik/runtime/overlay_storage.rb:99-111` — `verify_integrity`, manifestte **hiç kaydı olmayan** dosyayı yalnızca `# Rubik Custom Command:` başlığı varsa `:bootstrapped` yapıp hash'ini kaydediyor ve dosya aynı açılışta `eval` ediliyor (`load_all` → `eval_command`). Başlık sıfır çabayla taklit edilebilir; koşul manifestin varlığı/durumu ile hiç ilişkili değil → saldırı penceresi **kalıcı**. | Faz A |
| 2 | Yükleme hataları sessizce yutuluyor | **Haklı** | `overlay_storage.rb:172-174` (`load_all`) ve `:252-254` (`load_tools`) — gövdesiz/gereksiz `rescue StandardError`; `load_tools`'unki "# log and continue" yorumu taşıyor ama **hiç kayıt yok** (dürüst olmayan yorum). | Faz B |
| 3 | `Orchestrator::Loop#initialize`'te 8 ardışık `shell&.x` (Law of Demeter) | **Kısmen — kabul edilebilir** (değerlendiren de "fine" diyor) | `lib/rubik/orchestrator/loop.rb:28-34` — erişim Plan 54 D-5'in belgelenmiş accessor yüzeyinden; `@loop_context&.dispose` (`loop.rb:112`) protokole uygun ters etki geri sarması. | Kapsam dışı (izlenecek borç) |
| 4 | Tam unit paketi ~220 saniye sürüyor | **Tespit doğru, kod kusuru değil** | Değerlendiricinin sandbox timeout'u (180 s) yetersiz; Rakefile'da test timeout yapılandırması yok. | Kapsam dışı (operasyonel not) |
| 5 | `kill_tree` Windows'ta string `system` kullanıyor | **Haklı (düşük risk, tutarlılık)** | `lib/rubik/platform.rb:199` — `system("taskkill /F /T /PID #{pid} > NUL 2>&1")`. `pid`, `pid&.positive?` kapısıyla Numeric garantili; risk enjeksiyon değil, tutarsızlık. | Faz C |

**Kritik ek kanıt (Faz A'yı zorunlu kılan):** Plan 64'ün özgün spesifikasyonu açıkça şunu söylüyordu: *"Manifest varsa ama dosya manifestte değilse: bootstrap uygulanmaz, atlanır."* Mevcut uygulama (`overlay_storage.rb:99-111`) bu kuralı **ihlal ediyor** — satır içi yorum ("manifest var ama dosya manifestlerden önce eklendi" senaryosu) uygulama sırasında bilinçli eklenmiş bir sapma. Faz A, Plan 64 semantiğini — çok dosyalı geçişi koruyan bir rafineriyle — geri getirir.

## 3. Bilinen Etki Yarıçapı (statik analiz)

Düzenlenecek semboller ve yukarı doğru çağıranlar (uygulama öncesi GitNexus `impact({target:, direction: "upstream"})` ile teyit edilecek; HIGH/CRITICAL çıkarsa kullanıcıya bildirilir):

| Sembol | Çağıranlar | Risk |
| :--- | :--- | :--- |
| `verify_integrity` | Yalnız `overlay_storage.rb` içi: `list_commands` (:146, :153), `list_tools` (:230, :235) | Düşük |
| `list_commands` / `list_tools` | `load_all` (:162), `load_tools` (:243) → `repl/shell.rb:124` (REPL açılışı), `tools/registry.rb:113` (registry kurulumu) | Orta (davranış değişimi Faz A'da) |
| `load_all` / `load_tools` | Yukarıdakiler + `test_overlay_integrity.rb` (8 test) | Orta |
| `Platform.kill_tree` | `adapter/process.rb:55`, `lsp/client.rb:145`, `sandbox/driver/process.rb:73` | Düşük (imza/dönüş değişmiyor) |

## 4. Kapsam — Fazlar

### Faz A — Bootstrap'ı tek seferlik geçişe sabitlemek

Mevcut mantıkta bootstrap koşulu dosya başına "manifestte kayıt yok + sentinel var"dır. Yeni mantık **dizin taraması başına** belirlenir:

1. **Tarama-başı uygunluk:** `list_commands` / `list_tools`, her dizin glob'u öncesinde manifest **dosyasının** durumunu bir kez hesaplar:
   - **Yok** → tarama boyunca bootstrap uygun (ilk geçiş). Tarama başında hesaplandığı için, aynı taramadaki ilk dosyanın manifest yazması ikinci dosyayı dışlamaz — mevcut `test_multi_file_bootstrap_does_not_reject_second_file` davranışı korunur.
   - **Var ve geçerli JSON** → bootstrap **hiç uygulanmaz**; manifestte kayıtsız her dosya (sentinel olsa bile) mevcut `[SECURITY] Unknown overlay file` uyarısıyla reddedilir.
   - **Var ama bozuk JSON** → dizin **tamamen atlanır** + dizin başına tek satır `[SECURITY] Corrupt manifest in <dir>; skipping N overlay(s)` uyarısı. (Bugün bozuk manifest `{}` sanılıp sahte başlıklı dosya bootstrap edilebiliyor — `test_corrupt_manifest_does_not_crash`'in mevcut beklentisi tam da bu güvenlik açığını belgeleyip onaylıyor.)
2. **İmza değişikliği:** `verify_integrity(file_path, dir, bootstrap_eligible: false)` — yalnız sınıf içi çağıranlar etkilenir (bkz. §3).
3. **Görünür geçiş bildirimi:** bir dizinde bootstrap gerçekleştiyse tarama sonunda tek satır, koşulsuz görünen özet: `[BOOTSTRAP] First scan of <dir>: recorded N overlay(s) into .manifest.json; unknown files will be rejected from now on.` (Değerlendiricinin "notify" önerisi; global kapsam için ayrı onay akışı bilinçli olarak alınmadı — bkz. §5.)
4. **Değişmeyenler:** `RUBIK_TRUST_OVERLAYS=1` escape hatch (`:trusted`, `overlay_storage.rb:82`), hash doğrulama (`:verified`/`:rejected`), CRLF normalizasyonu, `flock`'lu manifest yazımı aynen kalır.

**Tasarım gerekçesi (değerlendiricinin iki seçeneğine göre):** (a) "global kapsam için etkileşimli onay" başlangıçta insan sarfı gerektirir; headless/tek atımlık çalıştırmaları ve testleri bozar. Bunun yerine deterministik (b) seçeneği ("sentinel başlık **VE** öncesi-boş manifest") + koşulsuz bildirim alındı; aynı güvenlik kazanımı, yeni UI yüzeyi yok.

### Faz B — Yükleme hatalarını kayda geçirmek

- `load_all` (`overlay_storage.rb:172-174`):
  ```ruby
  rescue StandardError => e
    warn "[OVERLAY] Failed to load custom command '#{cmd_name}' from #{file_path}: #{e.class}: #{e.message}"
  ```
- `load_tools` (`:252-254`): aynı kalıp (`custom tool '#{@name}'`). Yanıltan "# log and continue" yorumu kaldırılır (artık gerçekten log var).
- Kayıt koşulsuzdur (`RUBIK_DEBUG` bağımlı değil) — `[SECURITY]` uyarılarıyla aynı görünürlük felsefesi; başlangıç devam etme davranışı değişmez.

### Faz C — `kill_tree` dizi-form çağrı

`platform.rb:199`:
```ruby
system("taskkill", "/F", "/T", "/PID", pid.to_s, out: File::NULL, err: File::NULL)
```
- Shell yönlendirmesi (`> NUL 2>&1`) `out:`/`err:` seçeneklerine taşınır (`File::NULL` Windows'ta `NUL`'dur); davranış ve dönüş değeri (başarısızlıkta `nil`) korunur, mevcut `rescue` bloğu kalır.
- UNIX dalı (TERM/KILL) **dokunulmaz** — davranış-koruyucu disiplin.

### Faz D — Testler ve dokümantasyon

Mevcut `test/unit/test_overlay_integrity.rb` (8 test) ve `test/unit/test_platform.rb` (kill_tree testi yok) üzerinden:

1. **Yeni (Faz A çekirdek):** manifestte en az bir kayıt **varken** dizine bırakılan sentinel başlıklı dosya reddedilir + `[SECURITY] Unknown overlay file` uyarısı; `loaded` listesinde yok.
2. **Güncellenen:** `test_corrupt_manifest_does_not_crash` — bozuk manifest + sentinel dosya artık **yüklenmez**; `[SECURITY] Corrupt manifest` uyarısı assert edilir; çökme yok (kalan adı aynı, beklenti terst çevrilir).
3. **Korunan (regression guard):** `test_manifest_bootstrap_with_sentinel` ve `test_multi_file_bootstrap_does_not_reject_second_file` — manifest yokken tek/çok dosyalı bootstrap yeşil kalır.
4. **Yeni:** ilk-tarama bootstrap'ında `[BOOTSTRAP]` özet satırı yayınlanır.
5. **Yeni (Faz B):** açılışta exception fırlatan overlay kodu `loaded`'a girmez, `[OVERLAY] Failed to load custom command` uyarısı çıkar, diğer overlay'ler yüklenmeye devam eder; `load_tools` için eşdeğeri.
6. **Yeni (Faz C):** geçersiz pid'ler (`nil`, `0`, `-1`) exception fırlatmaz; Windows dalında `system` stub'lanıp argümanların dizi-form + `out:`/`err:` taşıdığı ve string yönlendirme içermediği assert edilir (`skip unless Rubik::Platform.windows?`).
7. **Dokümantasyon:** `SELF_EVOLUTION.md` (:126 civarı) ve `PLUGINS.md` (:199 civarı) — bootstrap'ın tek seferlik olduğu, bozuk manifest durumunun ve `RUBIK_TRUST_OVERLAYS=1` kaçış kapısının güncel tanımı.

## 5. Kapsam Dışı (bilinçli)

- **Bulgu 3 (Demeter):** Değerlendirici de kabul edilebilir buluyor; accessor yüzeyi Plan 54 D-5 ile belgeli. Bir `ShellDeps` façade'i `StepExecutor`/`StreamManager`/`BudgetManager`'ın tüm `loop.rb` erişimlerini yeniden düzenlemeyi gerektirir — fayda/maliyet düşük. **İzlenecek teknik borç** olarak kayıtlı; `shell` yüzeyi genişlemeye devam ederse ayrı plan.
- **Bulgu 4 (test süresi ~220 s):** Kod kusuru değil. Operasyonel not: dış değerlendirme/otomasyon ortamlarında test komutu timeout'u ≥ 300 s ayarlanmalı; Rakefile'da değişiklik gerekmez.
- **Global bootstrap için etkileşimli onay akışı:** Faz A'nın deterministik kapısı + bildirim + escape hatch ikame eder (gerekçe §4-Faz A).
- **İmzalı manifest (HMAC/PGP):** Plan 64'ten devreden ertleme; hash manifesti tehdit modelini karşılıyor.
- **UNIX `kill_tree` dalı, sentinel başlık formatı, eval çekirdeği:** dokunulmaz (AGENTS.md §3 kendi kendini genişletme çekirdeği).

## 6. Riskler ve Notlar

- **Davranış değişikliği — el yazımı overlay'ler:** Artık ilk taramadan **sonra** el ile eklenen sentinel başlıklı dosyalar reddedilir. Çare yolları: `RUBIK_TRUST_OVERLAYS=1` (belgeli) veya sentez akışı (`!synthesize_command` / `!synthesize_tool`) — bunlar manifeste hash yazdığından sorunsuz. Faz D dokümantasyon maddesi bunu açıkça belirtir.
- **Bozuk manifest artık dizini geçersiz kılar:** Yasgın neden (yarıda kalan yazım) `flock` + truncate düzeninden düşük olasılıklı; kullanıcı çaresi manifest dosyasını silmek (tek seferlik toplu bootstrap yeniden açılır — kasıtlı eylem) veya trust modu. Kalıntı risk kabulü: manifesti silebilen bir saldırgan zaten dosya sistemi yazma erişimine sahiptir (Plan 64 tehdit modeli: "oyun bitmiştir").
- **Taze kurulum penceresi:** Hiç manifest olmayan makinede, ilk taramadan önce bırakılmış sahte başlıklı dosya güvenilir (değerlendiricin (b) seçeneğinin açık kalan payı). Tek seferliktir; kalıcı pencere kapanır.
- **`verify_integrity` imza değişikliği** yalnız sınıf içi çağıranları etkiler; doğrudan test çağrısı yok (testler `load_all` üzerinden).
- **Windows'ta array-form `system`** harici `taskkill.exe`'yi shell'siz çağırır; builtin değildir, uyumluluk sorunu yok.

## 7. Kabul Kriterleri

- [ ] Faz D test 1–6 uygulandı ve yeşil: sahte başlık + dolu manifest → red; bozuk manifest → dizin atlama + uyarı; taze dizinde tek/çoklu bootstrap hâlâ çalışıyor; `[BOOTSTRAP]` bildirimi; `[OVERLAY]` hata kaydı; `kill_tree` dizi-form.
- [ ] Mevcut 8 overlay bütünlük testinden yalnızca `test_corrupt_manifest_does_not_crash` beklentisi değişti (gerekçeli) — diğerleri değişmeden yeşil.
- [ ] Tam `rake test` yeşil (beklenen süre ~220 s; komut timeout'u ≥ 300 s verilir), `rubocop` 0 ihlal.
- [ ] GitNexus: düzenlenen her sembol öncesi `impact` çalıştırıldı; commit öncesi `detect_changes()` yalnız beklenen sembolleri/akışları gösteriyor.
- [ ] `SELF_EVOLUTION.md` + `PLUGINS.md` güncel; el yazımı overlay geçiş yolu belgeli.

## 8. Disiplin

Her faz sonrası: tam `rake test` + `rubocop` kapısı; Windows'ta LF normalizasyonu (`perl -i -pe 's/\r\n/\n/'`); faz başına anlamlı commit; commit öncesi `detect_changes()` (AGENTS.md GitNexus kuralları). HIGH/CRITICAL etki uyarısı gelirse düzeltme öncesi kullanıcı bilgilendirilir. Davranış-koruyucu ilke: UNIX `kill_tree` dalı, hash doğrulama ve escape hatch semantiği birebir korunur.

## 9. Uygulama Sonucu

- **Faz A:** `manifest_state(dir)` tri-state yoklaması (Hash-olmayan geçerli JSON — `null`/`[]` — da `:corrupt` sınıflandırıldı; bugünkü gizli NoMethodError kapantı) + `verified_dir_entries(dir, scope)` yardımcısı eklendi; `list_commands`/`list_tools`'taki dört kopya glob+verify döngüsü tek yardımcıya indirgendi. `verify_integrity` `bootstrap_eligible:` (varsayılan `false`, fail-closed) aldı; trust modu manifest durumundan bağımsız erken döner ("trust güvendir"). Bozuk manifest dizini dışlar + `[SECURITY]` uyarısı; ilk bootstrap sonrası tek satır `[BOOTSTRAP]` bildirimi. `test_corrupt_manifest_does_not_crash` beklentisi plan uyarınca ters çevrildi (adı korundu); sahte-sentinel / ilk-tarama-bildirimi / bootstrap-sonrası-red testleri eklendi (commit `9616f27`).
- **Faz B:** `load_all`/`load_tools`'taki boş `rescue` blokları koşulsuz `[OVERLAY] Failed to load custom command/tool ...` kaydına çevrildi; yanıltıcı yorumlar silindi; komut ve araç düzeyinde yükleme-hatası testleri eklendi (commit `3d9860b`).
- **Faz C:** `kill_tree` Windows dalı `system("taskkill", "/F", "/T", "/PID", pid.to_s, out: File::NULL, err: File::NULL)` dizi-formuna geçti; UNIX dalı ve `begin/rescue` birebir korundu. Plan §4-6'daki "skip unless windows" önerisinden iyileştirme olarak testler `Rubik::Platform.stub(:system, ...)` dikişiyle **her platformda** koşar (evin `stub :which` kalıbı); dizi-form argv, hata yutma, TERM→KILL sırası ve geçersiz-pid no-op testleri eklendi (commit `1c2d76b`).
- **Faz D:** `SELF_EVOLUTION.md` "Tek Seferlik Bootstrap Kapısı" koruma maddesi ve `PLUGINS.md` eklenti yolu bootstrap içermez açıklaması eklendi; plan durumu tamamlandıya çekildi.
- **Doğrulama:** 13 overlay bütünlük testi + 14 platform testi yeşil; tam paket 1065 run — düşen 8 test, `git stash` ile temiz ağaçta birebir yeniden üretilen LLM stream loopback kararsızlığı ("connection was aborted"), bu değişiklikle ilgisiz. `rubocop` 0 ihlal. Testlerdeki `root==home` dizin çakışması nedeniyle sayaç türü iddialar varlık yoklamalarına çevrildi.
- **Sapma notu:** GitNexus MCP bu oturumda erişilebilir değildi; Plan 63/64 emsalindeki gibi explorer-agent etki analizi + commit öncesi `git diff --stat` incelemesi yapıldı.
- **İnceleme düzeltmeleri (3 reviewer sonrası, kullanıcı onayıyla):** `eval_command` artık `register_command`'ın built-in çakışma reddini (`false`) raise'e çevirip `[OVERLAY]` yoluna bağlıyor (`loaded` doğru kalır); `save_manifest` tmp+rename atomik yazıma geçti (kilitsiz okuyucuların yarım manifest görüp kayıtlı overlay'leri dışlaması kapatıldı; Platform.atomic_write yeniden kullanıldı); `trust_mode?` predicate'i iki kopya kapıyı tek noktaya indirdi; `eval_tool` kullanılamaz sonuç döndürünce `[OVERLAY]` uyarısı basılıyor; test dosyasına `capture_stderr` ensure'lı yardımcısı + açık `require "stringio"` / `require_relative` hijyeni. Kalan bilinen kalıntı: eşzamanlı süreçlerin read-modify-write yarışı (son yazan kazanır) — planın tehdit modeli kapsamında kabul; tam çözüm kilitli okuma gerektirir (ayrı konu).

## 10. Kırmızı Takı Takibi (Eylül 2026) — Kalıntı Kapanışı

Uygulanan değişiklik kırmızı takı diff incelemesinden geçirildi; beş saldırı senaryosu PoC ile yeniden üretildi. Sonuçlar ve müdahale:

| Senaryo | PoC sonucu | Müdahale |
| :--- | :--- | :--- |
| A. Taze kurulum: manifest'siz dizin + sahte sentinel | İlk taramada `eval` edildi | **Kapandı:** bootstrap artık `RUBIK_BOOTSTRAP_OVERLAYS=1` açık rızası gerektirir; rıza yokken sentinel dosyalar tek satırlık `[BOOTSTRAP] ... requires RUBIK_BOOTSTRAP_OVERLAYS=1` bildirimiyle atlanır, manifest oluşturulmaz |
| B. Manifest silme → yeniden bootstrap | Silme kapıyı yeniden açtı | Tehdit modeli kapsamında kabul: FS yazma erişimi olan saldırgan zaten manifesti doğrudan düzenleyebilir (senaryo C). Belgelemede "kasıtlı eylem" olarak tanımlı |
| C. Manifest doğrudan düzenleme | `:verified` | Plan 64'ten beri kabul: manifest kendi bütünlüğünü doğrulamaz (HMAC imzası ileriki plan) |
| D. Bozuk manifest + `save_command` heal-tahliyesi | Tüm kayıtlı overlay'ler dışlandı | **Kapandı:** `record_hash` bozuk manifestte kaydı reddeder (`save_command`/`save_tool` `{ ok: false }` döner), manifest üzerine yazılmaz |
| E. Trust × bozuk manifest | Her şey yüklendi | Tasarım gereği korundu ("trust güvendir") ve artık testle sabitlendi (`test_trust_mode_bypasses_corrupt_manifest`) |

Ek düzeltmeler: sentinel başlıklar `COMMAND_SENTINEL`/`TOOL_SENTINEL` sabitlerine indirgendi (yazıcı/denetleyici sürünme riski); `plugin/storage.rb` `save_manifest` atomik yazıma geçti (parite); her iki storage dosyasına açık `require_relative "../platform"` eklendi — tek dosya require'ında `Platform` NameError'u gerçek bir test kırılması olarak yakalandı ve giderildi. Kalan bilinen kalıntılar: eşzamanlı süreç RMW yarışı; `Platform.atomic_write` Windows `EACCES` fallback'ında doğrudan yazıma düşebiliyor (koşullu atomiklik); uyarı metinlerinde dosya adı/istisna mesajı kaynaklı log-forging (kozmetik).

**Davranış notu:** Opt-in gereksinimi, ilk planlamada kullanıcı tarafından reddedilen "env onayı" seçeneğidir; kırmızı takı incelemesi taze-kurulum saldırısını somutlayınca kullanıcı onayıyla uygulandı. Mevcut kullanıcıların kayıtlı manifestleri etkilenmez; yalnızca manifest'siz dizinler rıza ister.
