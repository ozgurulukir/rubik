# 05 — Bağlam Motoru: Dosya İndeksi ve Git Durumu

**Zorluk:** Orta · **Öneri kaynağı:** §7.2 · **Faz:** 2

## Amaç

Proje kökünü taramak, dosya indeksi ve git durumu toplamak, dil algılama yapmak ve
artımlı güncelleme (dosya izleme) sağlamak. AST semantiği Plan 06'dadır; burada
hızlı, dosya düzeyinde bağlam hedeflenir.

## Görevler (kolaydan zora)

1. `Rubik::Context::Scanner`: proje kökünde `.gitignore` saygılı dosya taraması
   (gem: `listen` yoksa stdlib `Dir.glob` + manuel ignore deseni).
2. Dil algılama: uzantı haritası + build dosyası imzaları (`build.zig`, `go.mod`,
   `Cargo.toml`, `Gemfile`, `pyproject.toml`, `Makefile`). Birden fazla dil → liste.
3. `Rubik::Context::Index`: `{path => {size, mtime, hash, language}}` indeksi;
   `!context status` özeti (dosya sayısı, dil, son tarama süresi).
4. Git durumu: aktif dal, dirty/green durumu, son commit — `git` ikiliğini arayüz
   arkasında çağıran `Rubik::Context::GitInfo`.
5. `!context add <yol>` / `!context drop <yol>`: tarama kapsamını yöneten include/exclude
   listeleri (glob destekli).
6. Artımlı güncelleme: `listen` gem ile dosya izleme; değişen dosyalarda yalnızca o
   dosyanın indeks girdisi güncellenir (hash değişmediyse dokunma).
7. Performans hedefi: 10k satırlık projede tam tarama < 10 sn (Plan 15'te ölçülür);
   büyük depolarda paralel tarama (thread havuzu, IO-bound olduğu için yeterli).

## Kabul Kriterleri

- [ ] `.gitignore`'daki dosyalar (ör. `node_modules/`) indekse girmez.
- [ ] Dosya değişikliği 2 sn içinde artımlı indekse yansır.
- [ ] Karma dil projesinde (ör. Go + Zig) her iki dil raporlanır.

## Bağımlılıklar

- Plan 01 (config), Plan 02 (`!context` komutları REPL'e bağlanır).

## Test Stratejisi

- Birim: dil algılama imza tablosu, ignore deseni eşleşmesi.
- Entegrasyon: fixture proje ağacında tarama; dosya ekle/sil/değiştir ile artımlı
  güncelleme; git repo'suz dizinde zarif düşüş.
