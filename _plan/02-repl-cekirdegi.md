# 02 — REPL Çekirdeği ve Komut Ayrıştırıcı

**Zorluk:** Kolay–Orta · **Öneri kaynağı:** §7.1, §8 · **Faz:** 1

## Amaç

Reline tabanlı etkileşimli kabuğu kurmak: prompt gösterimi, üç girdi kategorisinin
ayrıştırılması (serbest metin / `!komut` / çok satırlı kod tamponu), komut tablosu ve
hook sistemi. Bu planda henüz LLM veya bağlam motoru yoktur; komutlar stub'tır.

## Görevler (kolaydan zora)

1. `Rubik::REPL::Shell`: Reline ile sonsuz okuma döngüsü, `!quit`/`!exit` ile çıkış,
   Ctrl-C'de mevcut satırı iptal edip döngüde kalma.
2. Prompt formatı: `rubik (<proje-adı>) [<git-dallı>] >` — git yoksa `(no-project)`.
3. Girdi sınıflandırıcı: `!` ile başlayan satır → komut; aksi halde serbest metin prompt.
4. Komut tablosu: ad → handler eşlemesi; `!help [komut]` otomatik üretilir
   (her komut kısa açıklama bildirir). Öncelikli stub'lar: `!status`, `!help`, `!quit`.
5. Argüman ayrıştırma: tırnaklı argümanlar, boşluklu yollar (`!context add "./my dir"`).
6. Çok satırlı mod: heredoc benzeri tetikleyici (`<<EOF`) ile kod tamponu toplama;
   tampon bitince kullanıcıya "bu kodla ne yapılsın?" sorusu yerine tamponu serbest
   metin prompt'una ekleme.
7. `Rubik::REPL::Hooks`: olay adına kayıtlı Ruby proc'lar; `file_changed`,
   `test_failed`, `before_command`, `after_command` olayları.
8. Kaydedilmemiş değişiklik varken çıkışta uyarı (Plan 03'ün buffer API'sine sorar;
   yoksa sessizce çıkar).

## Kabul Kriterleri

- [ ] REPL başlar, `!help` tüm komutları listeler, `!quit` temiz çıkar (exit code 0).
- [ ] `!bilinmeyen` için "Bilinmeyen komut. !help'e bakın." mesajı.
- [ ] Tırnaklı argümanlar tek parametre olarak handler'a ulaşır.
- [ ] Hook'lar kayıt sırasına göre çalışır; hook hatası REPL'i çökertmez.

## Bağımlılıklar

- Plan 01 (config, proje kökü tespiti).

## Test Stratejisi

- Birim: girdi sınıflandırıcı ve argüman ayrıştırıcı saf fonksiyonlar olarak test edilir.
- Entegrasyon: Reline mock'lanarak önceden beslenmiş girdi akışıyla oturum koşturulur
  (piped input). Etkileşimsiz CI uyumluluğu için `--script <dosya>` bayrağı eklenir.
