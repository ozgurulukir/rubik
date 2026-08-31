# Plan 68 — Sıfır-Kurulum Kullanıcı Eklenti Mimarisi: Drop-in Dizinler, Reaktif Fiber Yaşam Döngüsü ve !plugin Yönetim Hattı

> **Domain:** Plugin / Runtime / REPL (Spatiotemporal Composability & Extensibility)
> **Kaynak:** Kullanıcı ve Dış Değerlendirme İncelemesi (Ağustos 2026) — "Gap: No User Plugin Directory & No !plugin install Command"
> **Durum:** ⏳ Planlandı
> **Öncül Planlar:** [14](14-eklenti-sistemi.md) · [20](20-spatiotemporal-composability-eklenti-dongusu.md) · [24](24-kendi-kendini-gelistiren-arac-sentezi.md) · [33](33-spatiotemporal-coeffect-inverses-ve-runtime-gorsellestirme.md) · [64](64-overlay-yukleme-butunluk-kapisi-ve-eval-guvenligi.md) · [65](65-plugin-runtime-fiber-koprusu-ve-alias-saglamlastirma.md)

---

## 1. Amaç

Rubik'in mimari vizyonu "her şey bir eklentidir" (spatiotemporal composability, reaktif fiberler, revertible effects). Ancak mevcut durumda eklenti yükleme yalnızca RubyGems (`gem install`) veya yapılandırma (`plugins.load`) ile sınırlıdır; kullanıcıların veya otonom ajanların VS Code eklentilerine benzer şekilde **sıfır-kurulumlu (Zero-Install / Drop-in)** eklenti ekleyebileceği bir dizin yapısı (`~/.rubik/plugins/` ve `.rubik/plugins/`) ve bunu yönetecek etkileşimli REPL komut hattı (`!plugin add/install/remove/reload`) bulunmamaktadır.

Bu plan:
1. **İkili Drop-in Dizin Mimarisi** (`.rubik/plugins/` [proje] ve `~/.rubik/plugins/` [global]) ile tek dosya (`.rb`) ve dizin tabanlı eklenti desteği getirir.
2. **SHA-256 Bütünlük ve Yükleme Kapısı** (Plan 64 standartlarıyla tahrifat koruması ve dinamik `$LOAD_PATH` yönetimi) sağlar.
3. **AGENTS.md Uyumlu Standart Eklenti Kontratı (`Rubik.plugin` DSL / `Plugin::Base`)** ile coeffect bağımlılık bildirimleri (`inject:`), geri alınabilir etkiler (LIFO Ω accumulator) ve zero-downtime hot-swapping sunar.
4. **REPL `!plugin` Yönetim Hattı** (`list`, `add`, `remove`, `reload`, `enable`, `disable`, `info`) ile eklenti yaşam döngüsünü insan operatöre ve otonom ajana açar.

---

## 2. Kanıt ve Mimari Tasarım

### 2.1 İkili Dizin Yapısı (Spatiotemporal Scoping)

Tıpkı komut ve araçlarda olduğu gibi (`OverlayStorage`), eklentiler de çalışma alanı ve kullanıcı düzeyinde ayrıştırılır:

| Kapsam | Dizin | Yaşam Döngüsü / İzolasyon |
| :--- | :--- | :--- |
| **Proje (Project)** | `<root_dir>/.rubik/plugins/` | Yalnızca o depoda/çalışma alanında aktiftir. Depo ile birlikte sürümlenebilir. |
| **Global (User)** | `~/.rubik/plugins/` | Kullanıcının tüm oturumlarında ve projelerinde aktiftir. |

Eklenti Formatları:
- **Tek Dosyalı Drop-in:** `.rubik/plugins/code_metrics.rb`
- **Dizin/Paket Drop-in:** `.rubik/plugins/git_lens/` (içerisinde `git_lens.rb` veya `lib/git_lens.rb` + isteğe bağlı `plugin.json` metaverisi)

### 2.2 Güvenli Yükleme ve $LOAD_PATH Yönetimi (`Plugin::Storage` / `Plugin::Scanner`)

- Scanner açılışta `project_plugins_dir` ve `global_plugins_dir` dizinlerini tarar.
- Dizin tabanlı eklentilerin `lib/` (varsa) veya kök dizinini güvenli şekilde `$LOAD_PATH.unshift` eder.
- **Bütünlük Kapısı (Plan 64 emsali):** Dizin başına `.manifest.json` tutularak eklenti giriş dosyasının SHA-256 özeti doğrulanır. Tahrif edilmiş veya izinsiz bırakılmış dosyalar güvenlik uyarısıyla atlanır (`RUBIK_TRUST_OVERLAYS=1` escape hatch geçerlidir).

### 2.3 Reaktif Eklenti Protokolü (`Rubik.plugin` DSL)

AGENTS.md §1-§4 kurallarına tam uyumlu, context-mediated deklaratif eklenti arayüzü:

```ruby
Rubik.plugin(:git_assistant, version: "1.0.0", inject: [:shell, :tools, :events]) do |ctx|
  shell = ctx.require(:shell)
  tools = ctx.require(:tools)
  events = ctx.require(:events)

  # 1. Geri Alınabilir Araç Kaydı (Revertible Tool)
  git_tool = MyGitTool.new
  tools.register(git_tool)
  ctx.on_dispose { tools.unregister(git_tool.name) }

  # 2. Geri Alınabilir REPL Komutu (Revertible Command)
  shell.register_command("git_status", description: "Smart git status") do |args|
    # ...
  end
  ctx.on_dispose { shell.unregister_command("git_status") }

  # 3. Geri Alınabilir Olay Dinleyicisi (Revertible Event Listener)
  unsub = events.on(:prompt_received) do |payload|
    # ...
  end
  ctx.on_dispose { unsub.call if unsub.respond_to?(:call) }
end
```

Eklenti kaldırıldığında veya `reload` edildiğinde, context'in Ω akümülatörü LIFO sırasında geri sarılır: kayıtlı komutlar, araçlar ve listener'lar **tek bir artık (residual state) bırakmadan** sistemden temizlenir.

### 2.4 REPL `!plugin` Yönetim Hattı

Mevcut tekil `!plugins` okuma komutu, zengin bir yönetim paketine dönüştürülür:

- `!plugin list` (veya `!plugins`): Yüklü gem'leri, drop-in proje ve global eklentilerini, fiber durumlarını (`:active`, `:pending`, `:failed`), coeffect'lerini ve alias'larını tablo olarak gösterir.
- `!plugin add <path|git-url|gem-name> [--global|--project]`: Belirtilen yerel dizini/dosyayı kopyalar, manifest'e SHA-256 hash'ini kaydeder ve süreci yeniden başlatmadan **canlı olarak (hot)** aktive eder.
- `!plugin remove <name>`: Eklentinin fiber'ını dispose eder (tüm inversler işletilir), dosyayı/dizini temizler.
- `!plugin reload <name>`: Zero-downtime swapping — eski fiber dispose edilir, güncel dosya taranıp yeniden yüklenir.
- `!plugin enable <name>` / `!plugin disable <name>`: Eklentiyi diskten silmeden fiber bazında deaktive/aktive eder.
- `!plugin info <name>`: Eklentinin sağladığı araçları, komutları ve durumunu ayrıntılandırır.

---

## 3. Kapsam — Fazlar

### Faz A — Drop-in Dizinleri ve Eklenti Depolama Motoru (`Plugin::Storage`)
- `lib/rubik/plugin/storage.rb` oluşturulması:
  - `project_plugins_dir` (`.rubik/plugins`) ve `global_plugins_dir` (`~/.rubik/plugins`) yolları.
  - `ensure_directories` (otomatik dizin oluşturma).
  - SHA-256 `.manifest.json` yönetimi (`load_manifest`, `save_manifest`, `record_hash`, `verify_integrity`).
  - `discover_plugins`: Tek dosya (`*.rb`) ve alt dizin paketlerini (`<name>/<name>.rb` veya `<name>/lib/`) tespit etme.
- Testler: Dizin tespiti, tekil ve paket eklenti ayrıştırma, manifest doğrulama.

### Faz B — Standart Eklenti Kontratı & Reaktif DSL (`Rubik.plugin` / `Plugin::Base`)
- `lib/rubik/plugin/base.rb` ve `lib/rubik/plugin/dsl.rb`:
  - `Rubik.plugin(name, version: "...", inject: [], &block)` kayıt metodu.
  - `Plugin::Definition` yapısı (ad, sürüm, açıklama, inject/coeffects, factory bloğu).
  - `Plugin::Manager`'ın `Storage` üzerinden taranan drop-in eklentileri `Runtime::Manager`'a fiber bileşeni (`plugin_<name>`) olarak bağlaması.
  - `$LOAD_PATH` dinamik yönetimi ve dispose anında $LOAD_PATH temizliği.
- Testler: DSL ile tanımlanan eklentilerin fiber olarak çalışması, eksik coeffect durumunda `:pending` kalması, coeffect sağlandığında reaktif `:active` olması, dispose anında LIFO temizliği.

### Faz C — REPL `!plugin` Yönetim Komutları (`lib/rubik/repl/commands/plugins.rb`)
- `lib/rubik/repl/commands/plugins.rb` genişletilmesi:
  - Alt komut ayrıştırıcı (`list`, `add`/`install`, `remove`/`uninstall`, `reload`, `enable`, `disable`, `info`).
  - Canlı eklenti ekleme (`!plugin add ./my_ext`) ve anında hot-load.
  - Canlı eklenti kaldırma (`!plugin remove my_ext`) ve LIFO unwinding doğrulaması.
  - Canlı eklenti yenileme (`!plugin reload my_ext`) ile zero-downtime hot-swap.
- Testler: REPL üzerinden alt komutların çalıştırılması, sahte eklenti ekleme/kaldırma/yenileme akışları.

### Faz D — Shell Açılış ve Konfigürasyon Entegrasyonu
- `Shell#initialize` / `Composition.build`:
  - Açılışta hem `config.fetch("plugins.load")` gem'lerinin hem de `Plugin::Storage` drop-in eklentilerinin taranıp yüklenmesi.
  - Hata veren drop-in eklentilerin REPL açılışını durdurmadan `:failed` durumunda raporlanması.
- `DEFAULT_CONFIG`: `plugins.autoload_dropin: true` seçeneği (varsayılan açık).
- Testler: Açılışta otomatik drop-in yükleme, bozuk drop-in eklenti izolasyonu.

### Faz E — Doğrulama, Dokümantasyon, Hijyen ve AGENTS.md Uyumu
- **Kapsamlı Dokümantasyon Güncellemeleri:**
  - `PLUGINS.md`: Sıfır-kurulum drop-in dizinleri (`.rubik/plugins/`, `~/.rubik/plugins/`), `Rubik.plugin` DSL'i, coeffect bağımlılıkları ve LIFO ters kayıt (`ctx.on_dispose`) rehberinin eklenmesi.
  - `COMMANDS.md`: `!plugin` ve alt komutlarının (`list`, `add`, `remove`, `reload`, `enable`, `disable`, `info`) detaylı kullanım kılavuzu ve örnekleri.
  - `CONFIG.md`: `plugins.load`, `plugins.aliases`, `plugins.autoload_dropin` yapılandırma seçeneklerinin belgelenmesi.
  - `README.md`: Sıfır-kurulum eklenti ekosistemi ve genişletilebilirlik özetinin güncellenmesi.
- **Test Paketleri:**
  - `test/unit/test_plugin_storage.rb` ve `test/unit/test_plugin_dsl_and_lifecycle.rb` test paketleri.
- **Modül Hijyeni:**
  - `test/unit/test_module_hygiene.rb` satır tavanı kontrolleri (`storage.rb < 200`, `manager.rb < 200`).
- **Kalite Kapısı:**
  - Tam `rake test` (%100 yeşil) ve `rubocop` 0 ihlal.

---

## 4. Kapsam Dışı (Bilinçli)

- **Harici Git Depolarından Otomatik `git clone` ile İndirme** — Ağ erişimi ve harici bağımlılık gerektirdiği için güvenlik Sandbox/Network kurallarına tabidir; `!plugin add <local-path|gem-name>` önceliklidir (URL desteği temel indirme kancası olarak bırakılır).
- **C-Extension / Native Derleme** — Eklentiler saf Ruby veya Rubik API'leri ile sınırlıdır.
- **WASM İçi Eklenti İzolasyonu** — Plan 19 kapsamı.

---

## 5. Riskler ve Çözümler

| Risk | Etki | Çözüm |
| :--- | :--- | :--- |
| **Drop-in Dosyada `eval`/`require` Güvenliği** | Kötü niyetli kod çalıştırma | Plan 64'teki SHA-256 `.manifest.json` kalkanı uygulanır. İmzalanmamış veya sonradan değiştirilmiş dosyalar reddedilir. |
| **$LOAD_PATH Kirliliği** | Çakışan modül yüklemeleri | Eklenti kaldırıldığında `ctx.on_dispose { $LOAD_PATH.delete(path) }` ile $LOAD_PATH temizlenir. |
| **Zombi Event Listener / Komutlar** | Bellek sızıntısı ve yan etki | Eklentinin tüm kayıtları `ctx.on_dispose` ile tersine eşlenir (AGENTS.md LIFO Ω kuralı). |
| **Bozuk Eklentinin REPL'i Çökertmesi** | Oturum kaybı | Eklenti yükleme hataları Fiber `:failed` durumuna alınır, kısmi ters kayıtlar işletilir ve REPL çalışmaya devam eder. |

---

## 6. Kabul Kriterleri

- [ ] `.rubik/plugins/` ve `~/.rubik/plugins/` dizinleri açılışta taranır ve eklentiler otomatik olarak Fiber bileşeni olarak yüklenir.
- [ ] `Rubik.plugin` DSL'i ile tanımlanan araçlar, komutlar ve listener'lar eklenti dispose edildiğinde LIFO sırasında geri alınır.
- [ ] `!plugin add`, `!plugin remove`, `!plugin reload`, `!plugin list` REPL komutları sorunsuz çalışır.
- [ ] SHA-256 bütünlük kontrolü tahrif edilmiş eklentileri engeller ve güvenlik uyarısı üretir.
- [ ] Dokümantasyon dosyaları (`PLUGINS.md`, `COMMANDS.md`, `CONFIG.md`, `README.md`) yeni eklenti mimarisi ve `!plugin` komutlarıyla eksiksiz güncellenir.
- [ ] Tam `rake test` yeşil (mevcut 861 test + yeni eklenti testleri), `rubocop` 0 ihlal.
- [ ] AGENTS.md spatiotemporal composability standartlarına %100 uyum.

---

## 7. Uygulama Sonucu

*(Uygulama sonrası doldurulacak: commit tablosu, test sayıları, sapmalar.)*

---

## 8. Disiplin

Her faz sonrası: tam `rake test` + `rubocop` kapısı, Windows'ta LF normalizasyonu, faz başına anlamlı commit. Sembol düzenlemelerinden önce GitNexus `impact` analizi.
