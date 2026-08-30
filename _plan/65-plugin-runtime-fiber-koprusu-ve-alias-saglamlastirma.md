# Plan 65 — Plugin ↔ Runtime Fiber Köprüsü ve Alias Sağlamlaştırma

> **Domain:** Plugin / Runtime (Spatiotemporal Composability)
> **Kaynak:** Dış değerlendirme (Ağustos 2026) — "Concern 6: Plugin System is Minimal" + "Key Recommendation 1: Bridge Plugin Manager with Runtime" + "Key Recommendation 6: Instrument Plugin Aliases"
> **Durum:** ✅ Tamamlandı
> **Öncül Planlar:** [14](14-eklenti-sistemi.md) · [20](20-spatiotemporal-composability-eklenti-dongusu.md) · [33](33-spatiotemporal-coeffect-inverses-ve-runtime-gorsellestirme.md) · [63](63-dis-degerlendirme-tavsiye-triyaji-ve-davranis-koruyucu-iyilestirmeler.md)

---

## 1. Amaç

`Plugin::Manager`, projenin kendi anayasası olan AGENTS.md protokolünün (revertible effects + reactive coeffects) dışında, yaşam döngüsüz minimal bir implementasyon olarak duruyor ve çalışma zamanına bağlı bile değil. Bu plan eklenti yüklemeyi **Runtime fiber yaşam döngüsüne** taşır, alias çözümlemesindeki gerçek sağlamlık boşluklarını kapatır ve Manager'ı yapılandırma güdümlü olarak Shell açılışına bağlar.

## 2. Kanıt ve Triyaj (kod tabanından)

### 2.1 "Plugin system is minimal" — haklı

- `lib/rubik/plugin/manager.rb` toplam 53 satır.
- **Çalışma zamanında kullanılmıyor:** `grep` sonucu lib/ ve bin/ içinde tek kullanım yok; yalnızca `test/unit/test_plugin_manager.rb` ve `test/fixtures/plugins/rubik-plugin-example` referans ediyor. Manager, Plan 14'den kalma kamusal bir API ama ölü bir kol.
- `load_plugin_gem` (`manager.rb:40-50`): çıplak `require` — fiber yaşam döngüsü yok, ters kayıt (inverse) yok, coeffect bildirimi yok, tekrar yükleme koruması yok. AGENTS.md §3.2 ("Deterministic Tool Registration: unregister the old tool version before activating the new version") ve §5 ("Leaked Side Effects" anti-pattern) ile çelişir. Değerlendirmenin "Contrasts with the sophisticated Runtime::Manager" tespiti doğru.

### 2.2 Alias robustness (R6) — haklı, ve somut bir hata var

- `manager.rb:22`: `@aliases[short_name.to_s.downcase] = full_command.to_s` — **anahtar downcase edilir, değer edilmez.**
- `resolve_alias` (`manager.rb:26-38`) yalnızca girişi downcase eder (`curr = cmd_name.to_s.downcase`), zincirdeki ham değerlerle devam eder: büyük/küçük harfli bir `full_command` yazıldığında `@aliases["MyCmd"]` araması nil döner (anahtarlar downcase) ve zincir sessizce kırılır.
- Döngü koruması iki katmanlı: `register_alias`'in `resolve_alias(full_command) == short_name` kontrolü (`:16-19`) yeni kenarla kapanan döngüleri yakalar; `resolve_alias`'in `seen` guard'ı sonsuz döngüyü önler. Yapı doğru ama harf normalizasyonu bozukken güvenilmez; ayrıca zincir uzunluğu sınırsız.

### 2.3 Hedef API'ler zaten mevcut

- `Runtime::Manager#register_component(name, inject: [], config: {}, &factory)` (`runtime/manager.rb:16`), `#register_fiber` (`:22`), `#unregister_component` (`:28`).
- `Runtime::Context#register_disposable` / `on_dispose` (ters kayıt accumulator'ı Ω).
- Fazlı yaşam döngüsü (Pending → Active → Failed → Disposed) ve atomik geri alma Plan 20/33'te hazır.

## 3. Kapsam — Fazlar

### Faz A — Alias sağlamlaştırma (bağımsız, önce)
- Kayıt ve çözümlemede **değerler de downcase** normalizasyonu ve bang (`!`) öneki temizliği (`@aliases` artık tamamen downcase ve `!`süz bir alan; `!rt` veya `rt` aynı algılanır, hedef komuttaki `!` de temizlenip zincire katılır).
- `resolve_alias` döngü guard'ını açık `visited` kümesiyle korur; 8'den uzun zincir şüpheli kabul edilip logger uyarısı alır.
- Testler: mixed-case zincir çözümlemesi, bang öneki olan/olmayan alias senaryoları, 3-düğümlü döngü kaydı reddi, uzun zincir uyarısı. Mevcut `test_plugin_manager.rb` senaryoları yeşil kalır.

### Faz B — Fiber köprüsü
- `load_plugin_gem(gem_name, context:)` imzası: gem'i `Runtime::Manager#register_component` ile bileşen olarak kaydeder; factory içinde `require` edilir.
- `require` başarısız olursa bileşen **Failed** durumuna düşer ve kısmi inversler işletilir (AGENTS.md "Atomic Rollback on Error" kuralı; mevcut Runtime altyapısı bunu zaten yapıyor).
- **Dürüst sınırlama, belgelenecek:** Ruby'de `require` geri alınamaz; bileşenin ters kaydı "runtime kaydını kaldırmak"tır (unregister + varsa gem'in sağladığı `on_unload` kancası), modül sabiti bellekte kalır. İsteğe bağlı kural: gem `Rubik::Plugin::Hooks#on_unload` tanımlıyorsa dispose'da çağrılır.
- Tekrar yükleme koruması: aynı gem tekrar yüklenmek istenirse eski bileşen `unregister_component` ile kaldırılıp yenisi kaydedilir (AGENTS.md §3.2 zero-downtime swapping).
- Testler: fiber durum geçişleri (Active/Failed), dispose'da `on_unload` çağrısı, çift yükleme idempotansı.

### Faz C — Shell'e bağlama (Manager'ı ölü koddan çıkarma)
- `DEFAULT_CONFIG`'e `plugins` bölümü: `{"load" => [], "aliases" => {}}` (boş varsayılan; davranış değişimi yok).
- `Composition.build` / Shell açılışı: listedeki gem'leri Plugin::Manager üzerinden (Faz B köprüsüyle) yükler; alias'ları kaydeder. `Shell`'e `@plugin_manager` enjekte edilir.
- `Shell#execute_command` alias çözümlemesi: `parsed.command_name`, `@commands` sözlüğünde aranmadan önce `@plugin_manager.resolve_alias` ile çözümlenir (bang `!` öneki strip edilmiş halde bakılır).
- `!plugins` REPL komutu: kayıtlı gem'ler + bileşen durumları + alias tablosu (tek okuma komutu; mevcut `repl/commands/` düzenine ekle).
- Testler: config listesiyle yükleme (fixture gem ile), boş listede hiçbir şey olmaması, `!plugins` çıktısı, alias üzerinden REPL komutu çalıştırma testi.

## 4. Kapsam Dışı (bilinçli)

- **Gerçek gem unload** (modül sabitinin bellekten atılması) — Ruby semantik engeli; Faz B'deki dürüst sınırlama belgelenir.
- **Plugin'ler için coeffect DAG bildirimi** — Plan 33 altyapısı var; plugin API'sine `requires:` eklemek ileriki adım (bu plan `inject:` parametresini açık bırakır).
- **WASM/container plugin izolasyonu** — Plan 19 kapsamı.
- Alias sisteminin komut kayıt defterine (`Shell#register_command`) taşınması — alias'lar Plugin::Manager sorumluluğunda kalır (yaşam döngüsü ayrı).

## 5. Riskler ve Notlar

- Faz C, açılış süresine `require` maliyeti ekler → yalnız config'de listelenen gem'ler yüklenir, sessiz başarı/başarısızlık `!plugins`'ten görünür.
- Faz A'daki downcase normalizasyonu davranış değişikliği değildir: mixed-case değerli mevcut zincirler zaten kırıktı (2.2); hiçbir çalışan yol gerilemez — mevcut testler bunu doğrular.
- Fixture plugin (`test/fixtures/plugins/rubik-plugin-example`) Faz B/C testlerinde yeniden kullanılır.

## 6. Kabul Kriterleri

- [x] Faz A/B/C test senaryoları yeşil; `test_plugin_manager.rb` mevcut senaryoları birebir geçer.
- [x] Tam `rake test` yeşil, `rubocop` 0 ihlal.
- [x] Bir gem yükleme hatası REPL açılışını **durdurmaz** (Failed bileşen + uyarı).
- [x] AGENTS.md §6 kontrol listesinin "Locality of Disposal" ve "LIFO Unwinding" maddeleri plugin yolu için karşılanıyor (code review checklist).

## 7. Uygulama Sonucu

- **Faz A (Alias Sağlamlaştırma):** `Plugin::Manager#normalize_alias_key` ile hem anahtarlar hem değerler normalize edildi (downcase + `!` temizleme), 8 adımlık zincir limiti ve döngü engelleme (`visited`) eklendi.
- **Faz B (Fiber Köprüsü):** `load_plugin_gem` metodu `Runtime::Manager` ile entegre edildi. Eklentiler fiber bileşeni olarak kaydedilip yönetilmekte, zero-downtime swapping desteklenmekte, `on_unload` kancası LIFO accumulator'a bağlanmakta ve `LoadError` durumları `:failed` duruma geçmektedir.
- **Faz C (Shell & REPL Entegrasyonu):** `DEFAULT_CONFIG` içine `plugins` bloku eklendi, `Composition.build` ve `Shell` üzerinden otomatik yükleme sağlandı, `execute_command` alias çözümlemesi ile donatıldı ve `!plugins` REPL komutu oluşturuldu.
- **Testler:** 850 test, 4461 assertion ile %100 yeşil tamamlandı. RuboCop 0 ihlal. Plan APPROVED.

## 8. Disiplin

Her faz sonrası: tam `rake test` + `rubocop` kapısı, Windows'ta LF normalizasyonu, faz başına anlamlı commit. Sembol düzenlemelerinden önce GitNexus `impact` (erişim yoksa explorer agent ile etki analizi, Plan 63 emsali).
