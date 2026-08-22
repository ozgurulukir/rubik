# 13 — Sandbox ve Süreç İzolasyonu

**Zorluk:** Zor · **Öneri kaynağı:** §9.1 · **Faz:** 4

## Amaç

Derleme/çalıştırma adımlarının izole alt süreçte, kaynak limitleriyle, varsayılan
ağ kapalı ve dosya sistemi erişimi proje köküyle sınırlı olarak koşturulması.
Docker/Wasm katmanları opsiyonel derinleştirmedir; temel, Linux süreç izolasyonudur.

## Görevler (kolaydan zora)

1. `Rubik::Sandbox::Runner`: Plan 07'deki `Process` çalıştırıcısının yerine geçen
   güvenli sürüm — aynı arayüz (`run(cmd, opts)`), ek garantiler.
2. Kaynak limitleri: `Process.setrlimit` ile CPU süresi, RAM, dosya boyutu,
   süreç sayısı (fork bombası koruması); aşım → süreç sonlandırma + rapor.
3. Zaman aşımı: yumuşak (SIGTERM) → sert (SIGKILL) iki aşamalı; alt süreç ağacı
   (process group) topluca sonlandırılır.
4. Ağ politikası: varsayılan kapalı. Uygulama sırası: (a) ortam değişkeni
   temizliği + proxy kara deliği (basit), (b) `unshare -n` network namespace
   (Linux), kullanıcı `!config set network.allow true` demeden açılmaz.
5. Dosya sistemi sınırı: çalışma dizini proje kökü; mutlak yol ve `..` kaçışları
   komut argümanlarında taranır (Plan 12 tarayıcısıyla paylaşılır). Tam chroot/bubblewrap
   opsiyonel katman olarak belgelenir.
6. Docker sağlayıcısı: mevcut Docker/Podman varsa komutlar konteynerde koşturulur
   (bind mount salt-okunur proje + yazılabilir tmpfs çıktı); yoksa yerel Runner'a düşüş.
7. Wasm sağlayıcısı (opsiyonel): wasmtime ile saf hesaplama görevleri için;
   kapsam dışına çıkarsa belgelenip ertelenir.
8. Sandbox durum raporu: `!status` aktif izolasyon seviyesini gösterir
   (`none | rlimit | namespace | docker`).

## Kabul Kriterleri

- [ ] Sonsuz döngü komutu zaman aşımıyla öldürülür; REPL yanıt vermeye devam eder.
- [ ] Fork bombası denemesi süreç limitiyle durdurulur; sistem zarar görmez.
- [ ] Ağ kapalıyken sandbox içinden dış bağlantı kurulamaz (test: basit HTTP
      denemesi başarısız olmalı).
- [ ] Docker'sız ortamda tüm özellikler bozulmadan çalışır (zarif düşüş).

## Bağımlılıklar

- Plan 07 (süreç çalıştırıcı arayüzü), Plan 12 (risk sınıflandırma).

## Test Stratejisi

- Birim: rlimit/timeouts (uyuyan/sapitan sahte komutlarla).
- Entegrasyon: kasıtlı kötü niyetli komut seti (fork bomba simülasyonu, ağ denemesi,
  dizin kaçışı) — hepsi kontrollü şekilde engellenmeli.
- Not: bu testler CI'da container içinde koşmalı; bare-metal CI'da namespace testleri
  atlanır.
