# 01 — Proje İskeleti ve Konfigürasyon

**Zorluk:** Kolay · **Öneri kaynağı:** §7.6 · **Faz:** 1

## Amaç

Ruby gem iskeletini kurmak: dizin yapısı, `rubik` çalıştırılabilir girişi,
konfigürasyon yükleme (`~/.rubik/config.yml` + `rubik.yml`), olay veri yolu ve
temel test altyapısı. Diğer tüm planlar bu temel üzerine inşa edilir.

## Görevler (kolaydan zora)

1. Gem iskeleti: `rubik.gemspec`, `lib/rubik.rb`, ad alanı modülü; Ruby 3.3+
   gereksinimi gemspec'te beyan edilir.
2. Test altyapısı: Minitest + Rakefile (`rake test`); `test/` dizin düzeni
   (`unit/`, `integration/`, `fixtures/`).
3. `bin/rubik` çalıştırılabilir dosyası: şu anlık `Rubik::VERSION` basıp çıkan
   minimal giriş noktası.
4. `Rubik::Config`: küresel (`~/.rubik/config.yml`) ve proje (`rubik.yml`)
   katmanlarını birleştiren okuyucu; eksik dosya = varsayılanlar (hata değil).
5. Varsayılan şema: `{model: {provider: ollama, name: ...}, repair:
   {max_attempts: 3}, network: {allow: false}, context: {...}}`; bilinmeyen
   anahtarda uyarı.
6. `Rubik::EventBus`: `subscribe(event) { |payload| }` / `emit(event, payload)`
   — katmanlar arası iletişimin tek kanalı; abone hatası diğer aboneleri
   etkilemez ve loglanır.
7. Çalışma dizini hazırlığı: ilk açılışta `~/.rubik/{snapshots,sessions}` altında
   oluşturma (idempotent).
8. Lint/format: RuboCop konfigürasyonu; CI'da lint kapısı.

## Kabul Kriterleri

- [ ] `bin/rubik` hatasız çalışır, sürüm basar.
- [ ] Config dosyası hiç yokken sistem varsayılanlarla açılır; bozuk YAML'da
      anlaşılır hata mesajı ("Cannot load config because ... To fix, ...").
- [ ] EventBus'a kayıtlı bir abonenin içindeki istisna emit eden tarafı çökertmez.

## Bağımlılıklar

- Yok (ilk plan).

## Test Stratejisi

- Birim: config birleştirme (küresel < proje önceliği), bozuk YAML, eksik anahtarlar.
- Ortam izolasyonu: testlerde `HOME` geçici dizine yönlendirilir; gerçek
  `~/.rubik`'e dokunulmaz.
