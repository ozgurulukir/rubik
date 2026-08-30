# Plan 64 — Overlay Yükleme Bütünlük Kapısı ve eval Güvenliği

> **Domain:** Güvenlik (Security / Overlay Storage)
> **Kaynak:** Dış değerlendirme (Ağustos 2026) — "Concern 2: OverlayStorage's `eval` Usage" + "Key Recommendation 2: Casual `eval` Sandbox Verification"
> **Durum:** ✅ Tamamlandı
> **Öncül Planlar:** [21](21-llm-komut-sentezi-ve-calistirma.md) · [24](24-kendi-kendine-evrilen-arac-sentezi-ve-calisma-zamani-denetimi.md) · [59](59-cekirdek-guvenligi-sentez-sandbox-bare-rescue-ve-moduler-testler.md) · [60](60-kritik-yol-guvenligi-sandbox-timeout-ve-kod-sagligi.md) · [63](63-dis-degerlendirme-tavsiye-triyaji-ve-davranis-koruyucu-iyilestirmeler.md)

---

## 1. Amaç

`OverlayStorage`'ın **yükleme yolu** (`load_all` / `load_tools`), diskten okuduğu overlay kodunu hiçbir doğrulama olmadan süreç içinde `eval` ediyor. Bu plan, sentez anındaki güvenlik kontrolünün **kalıcılığını** sağlar: diske yazılan kodun sentezldiği haliyle değişmediğini kanıtlayan bir bütünlük manifesti getirir, doğrulanamayan kodu yüklemeyi reddeder.

## 2. Kanıt ve Triyaj (kod tabanından)

Dış değerlendirmenin "Ensure that `eval` is gated behind sandbox verification in all code paths" tespiti **haklı**; mevcut kapı yalnızca sentez anında, yükleme anında yok:

| Yol | Konum | Koruma |
| :--- | :--- | :--- |
| Sentez (kaydet) | `lib/rubik/tools/builtins/synthesis.rb:51` ve `:140` — `@guard.verify_command_safety!(code)` | Yalnızca **desen kontrolü** (dangerous command pattern'leri). Gerçek sandbox çalıştırması yalnızca `test_args` verildiyse ve Süreç-içi `Timeout` ile (`synthesis.rb:167-178`; `SandboxRunner` değil). |
| Yükleme (açılış) | `lib/rubik/runtime/overlay_storage.rb:105,107` (`eval_command`) ve `:191` (`eval_tool`) | **Hiçbiri.** Kod doğrudan `eval` edilir. |
| Tetik noktaları | `lib/rubik/repl/shell.rb:109` (`load_all`, REPL açılışı) ve `lib/rubik/tools/registry.rb:113` (`load_tools`) | — |

Saldırı yüzeyi: `.rubik/commands/*.rb`, `.rubik/tools/*.rb`, `~/.rubik/{commands,tools}/*.rb` yoluna herhangi bir yolla (başka bir araç, açılan yabancı bir depo, sonradan değiştirilmiş global overlay) yazılan dosya, Rubik sürecinin bir sonraki açılışında tam yetkiyle çalışır.

İkincil dürüstlük sorunu: `overlay_storage.rb:105/107/191`'deki `rubocop:disable Security/Eval` gerekçeleri *"kaynak sentez-sandbox doğrulamasından geçer"* diyor. Bu iddia yükleme yolu için **yanlış** — yorumlar gerçek korumayı tanımlamalı.

## 3. Kapsam — Fazlar

### Faz A — Bütünlük manifesti ve yükleme kapısı
- Her overlay dizini için `.manifest.json` (dosya adı → SHA-256 hash + kapsam + ISO8601 zaman damgası).
- `save_command` / `save_tool` kayıt sırasında hash'i manifest'e yazar.
- `load_all` / `load_tools` **`eval` öncesi** hash'i doğrular:
  - Hash uyuşuyor → yükler.
  - Hash uyuşmuyor veya dosya manifestte yok → **atla** + tek satır `[SECURITY]` uyarısı (yalnız `RUBIK_DEBUG`'a bağlı değil — güvenlik olayı her zaman görünür) + varsa audit/event kaydı.
- **Manifest bootstrap (geçiş yolu):** manifest yoksa VE dosya Rubik sentez başlığı taşıyorsa (`# Rubik Custom Command:` / `# Rubik Custom Tool:`, `overlay_storage.rb:47-53,129-137`'deki kalıp), dosya kabul edilip hash manifest'e geri yazılır — mevcut kullanıcıların overlay'leri sessizce ölmez. Manifest varsa ama dosya manifestte değilse: bootstrap uygulanmaz, atlanır.

### Faz B — Escape hatch ve dürüst yorumlar
- `RUBIK_TRUST_OVERLAYS=1` ortam değişkeni manifest doğrulamasını atlar (el yazımı overlay geliştirme akışı; risk README'de belgelenir).
- `overlay_storage.rb`'deki üç `rubocop:disable` gerekçesi gerçek korumayı tanımlar: *"sentez anında guard desen kontrolünden geçti VE disk hash'i manifestle doğrulandı"*.
- `!commands` / araç listeleme çıktılarına, yüklenmeyen (doğrulanamayan) overlay'ler için tek satır durum notu (mevcut liste metnine ek; yeni UI yüzeyi açılmaz).

### Faz C — Testler
1. Yeşil yol: sentez → kaydet → yeni örnekle yükle (hash mutabakı).
2. Diskte sonradan değiştirilen dosya **yüklenmez** + uyarı yayınlanır.
3. Manifestte olmayan, sentez başlığı taşımayan el yazımı dosya yüklenmez.
4. Manifest bootstrap: başlıklı eski dosya ilk yüklemede kabul edilir ve manifest'e yazılır.
5. `RUBIK_TRUST_OVERLAYS=1` ile doğrulanmayan dosya da yüklenir.
6. Edge case'ler: Bozuk/Geçersiz manifest JSON dosyası durumunda çökme olmaz (atlama/red); Windows CRLF formatlı okumalar LF hash ile uyuşur; boş dosya yüklemede çökmez.
7. Mevcut turuncu-kırmızı güvenlik testleri (`test_synthesis_security.rb`, `test_self_evolving_tool_synthesis.rb`, `test_repl_command_execution_and_synthesis.rb`) birebir yeşil kalır.

## 4. Kapsam Dışı (bilinçli)

- **Sentez anındaki in-process `eval`'in kaldırılması** — ajanın kendini genişletmesi çekirdek özellik (AGENTS.md §3); guard desen kontrolü mevcut kapı.
- **`SandboxRunner`'a gerçek yürütme taşıma** — Plan 19/59 altyapısı var; ayrı ve daha büyük bir konu.
- **İmzalı manifest (HMAC/PGP)** — hash manifesti tehdit modelini (sonradan değiştirme/yanlışlıkla bulaşma) karşılıyor; imzalama ileriki plan.

## 5. Riskler ve Notlar

- **Mevcut kullanıcı etkisi:** el yazımı overlay'leri ilk açılışta devre dışı kalabilir → Faz A bootstrap + Faz B hatch + görünür uyarı bunu hafifletir.
- **Manifest Dosyası Bütünlüğü:** `JSON::ParserError` (bozuk/yarım manifest) durumunda load süreci çökmemeli; manifest geçersiz (boş) kabul edilip normal doğrulama reddi yollarına düşmelidir.
- **Eşzamanlı Yazımlar (Concurrent Writes):** Manifest güncellemeleri (`save_command` ve `save_tool`), veri kaybını veya bozulmayı önlemek için özel dosya kilidi (`File#flock(File::LOCK_EX)`) ile yapılmalıdır.
- **Windows CRLF ve Hash:** Hash hesaplaması, `\r` karakterlerinden arındırılmış (sadece `\n` içeren) **normalize edilmiş** içerik üzerinden yapılmalıdır. Aksi halde Git autocrlf veya editör müdahaleleri yanlış pozitif uyuşmazlıklara (hash mismatch) neden olur.
- **Boş Dosyalar:** Boş `.rb` dosyaları bootstrap senaryosunda regex aramalarında hata fırlatmamalı, başlık bulunmadığı için güvenle reddedilmelidir.
- Manifest dosyası da değiştirilebilir (hash hash'i doğrulamaz); tehdit modeli "yanlışlıkla/kolayca bulaşma" — dosya sistemi saldırganın elindeyse zaten oyun bitti. Bu sınırla plan dokümanında açıkça belirtilir.

## 6. Kabul Kriterleri

- [ ] Faz C'deki 6 test senaryosu uygulanmış ve yeşil.
- [ ] Tam `rake test` yeşil, `rubocop` 0 ihlal.
- [ ] Doğrulanamayan overlay atlandığında kullanıcı uyarısı normal çalıştırmada görünür.
- [ ] `rubocop:disable` gerekçeleri gerçek korumayı tanımlıyor.

## 7. Uygulama Sonucu

- OverlayStorage içinde SHA-256 hash manifesti (`.manifest.json`) yönetimi ve doğrulama mekanizması (Faz A) tamamlandı.
- Yükleme esnasında hash uyuşmazlığı tespiti, `RUBIK_TRUST_OVERLAYS=1` escape hatch ve güvenlik uyarıları eklendi (Faz B).
- `save_manifest` içindeki dosya kilidi (`flock`) File::RDWR ve f.truncate(0) kullanılarak concurrent truncate hatalarını önleyecek şekilde düzeltildi.
- Edge case testleri (tamper, bootstrap, hash mismatch) eklendi ve 841 tests, 4433 assertions, 0 failures, 0 errors ile doğrulandı (Faz C).
- Tüm rubocop Security/Eval istisnaları gerçekçi güvenlik yorumlarıyla güncellendi.
- Hedefler tam anlamıyla karşılandı ve plan APPROVED.

## 8. Disiplin

Her faz sonrası: tam `rake test` + `rubocop` kapısı, Windows'ta LF normalizasyonu (`perl -i -pe 's/\r\n/\n/'`), faz başına anlamlı commit. GitNexus MCP erişimi varsa düzenlemeden önce `impact({target: ...})`; erişim yoksa (öncül Plan 63'teki gibi) explorer agent ile etki analizi + test kapısı belgelenir.
