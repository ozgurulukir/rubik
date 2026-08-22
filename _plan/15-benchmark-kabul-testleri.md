# 15 — Benchmark ve Kabul Testleri

**Zorluk:** Orta · **Öneri kaynağı:** §10, §4.3 · **Faz:** 5

## Amaç

Önerinin §10'daki başarı metriklerini ölçülebilir test paketine dönüştürmek:
otomatik benchmark'lar, uçtan uca kabul senaryoları ve raporlama.

## Görevler (kolaydan zora)

1. Benchmark iskeleti: `rake bench` — her metrik için `{name, target, measured,
   pass?}` satırı üreten ortak altyapı; sonuç Markdown tablosu olarak yazılır.
2. Bağlam tarama benchmark'ı: sentetik 10k satır proje → tam tarama < 10 sn;
   tek dosya değişimi → artımlı güncelleme < 2 sn (Plan 05/06 hedefleri).
3. Token verimliliği ölçümü: aynı görev için ham dosya gönderimi vs akıllı bağlam
   seçimi karşılaştırması; hedef: bağlam ≤ ham boyutun %30'u (Plan 06 hedefi).
4. Onarım oranı süiti: her dil için kasıtlı bozulmuş fixture seti (Plan 11'in
   testlerinden büyütülmüş) — hedef: %80 görev, ≤3 denemede çözülür; ortalama
   onarım süresi < 60 sn.
5. Uçtan uca kabul senaryoları (öneri §4.3): "sıfırdan Zig/Go modülü, ≤5 komut";
   script modda koşturulabilir olmalı (LLM determinizmi için sıcaklık=0 + sabit
   model sürümü; yine de flaky ise gecelik job'a taşınır).
6. Diff onay oranı ölçümü: kabul senaryolarında `!apply` öncesi reddedilme sayımı
   (hedef: %25 altı) — manuel kullanım istatistikleriyle desteklenir.
7. Güvenlik regresyon süiti: Plan 12/13'ün red-team testlerinin tek komutla
   koşulması; her sürüm öncesi zorunlu geçiş kapısı.
8. CI entegrasyonu: GitHub Actions — birim/entegrasyon her push'ta; benchmark +
   kabul süiti gecelik; sonuç artifact olarak saklanır.

## Kabul Kriterleri

- [ ] `rake bench` tek komutla §10 tablosundaki tüm ölçülebilir metrikleri raporlar.
- [ ] Güvenlik süiti yeşil olmadan sürüm adımı tamamlanamaz.
- [ ] Benchmark sonuçları zaman içinde karşılaştırılabilir (artifact arşivi).

## Bağımlılıklar

- Tüm planlar (özellikle 05, 06, 08, 10, 11, 12).

## Test Stratejisi

- Kendi kendini ölçen süit: benchmark kodunun kendisi de birim testlidir
  (ölçüm altyapısının doğruluğu).
- Flakiness politikası: LLM'e bağlı testler ayrı etiketle (`@llm`) koşar;
  ağ/model oynaklığı ana süiti kirletmez.
