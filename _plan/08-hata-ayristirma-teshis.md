# 08 — Derleyici Çıktısı Ayrıştırma ve Teşhis

**Zorluk:** Orta–Zor · **Öneri kaynağı:** §7.4, §7.3 · **Faz:** 3

## Amaç

Derleyici/linter/test çıktılarını yapılandırılmış teşhis nesnelerine dönüştürmek:
`{file, line, col, severity, code, message, category}`. Onarım döngüsünün (Plan 11)
girdisi budur.

## Görevler (kolaydan zora)

1. `Rubik::Diagnostic` veri modeli + kategori enum'u: `:syntax`, `:type`,
   `:undefined_ref`, `:memory_safety`, `:test_failure`, `:lint`, `:unknown`.
2. Genel ayrıştırıcı çerçevesi: satır-bazlı regex kural seti; her adaptör kendi
   kurallarını bildirir (`parse_errors` bunu kullanır).
3. **Ruby** kuralları: ``file.rb:12: syntax error, unexpected ...`` ve test
   çıktısı (minitest/rspec başarısızlık blokları).
4. **Go** kuralları: `file.go:10:5: undefined: x` (vet+build birleşik desen).
5. **Rust** kuralları: çok satırlı `error[E0382]: ...` + `--> src/main.rs:10:5`
   blokları; not/yardım satırları ek bağlam olarak toplanır.
6. **Zig/C** kuralları: `file.zig:24:9: error: use of undeclared identifier 'x'`;
   C'de clang'ın `note:` zincirleri.
7. Çok satırlı hata bloklarının gruplandırılması (aynı hataya ait ardışık satırlar
   tek Diagnostic'e katlanır).
8. Teşhis → prompt parçası formatlayıcı: hata + etkilenen satırın ±10 satır çevresi
   - ilgili sembol tanımı (Plan 06 grafından) tek metin bloğuna.
9. Test başarısızlığı ayrıştırma: hangi testler geçti/kaldı sayımı (`12/12` deseni)
   — regresyon karşılaştırması için.

## Kabul Kriterleri

- [ ] Her dil için gerçek derleyici çıktısı örneklerinden oluşan altın dosya seti
      %95+ alan/dosya/satır doğruluğuyla ayrıştırılır.
- [ ] Tanınmayan çıktı `:unknown` kategorisiyle kaybolmaz, ham metinle taşınır.
- [ ] Ayrıştırıcı asla istisna fırlatmaz; bozuk girdide en iyi çabayla döner.

## Bağımlılıklar

- Plan 07 (adaptörler çıktıyı sağlar), Plan 06 (bağlamsal sembol zenginleştirme).

## Test Stratejisi

- Altın dosya testleri: her araç için gerçek stderr örnekleri repo'da
  `test/fixtures/diagnostics/<dil>/` altında; beklenen Diagnostic listeleriyle
  karşılaştırma.
- Dayanıklılık: rastgele bozuk metin, boş çıktı, aşırı uzun çıktı (>1 MB) fuzzer'ı.
