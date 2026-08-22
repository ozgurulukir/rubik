# 11 — Kendi Kendini Onarma Döngüsü

**Zorluk:** Zor · **Öneri kaynağı:** §7.4 · **Faz:** 4

## Amaç

Claim-Verify-Act'in tamamlanması: derleme/test başarısızlığında, bütçe dahilinde
(basayılan 3 deneme) teşhis + bağlam ile LLM'den yama üretme, tampon üzerinde
uygulama, yeniden doğrulama ve regresyon kontrolü.

## Görevler (kolaydan zora)

1. `Rubik::SelfRepair::Loop`: girdi = Diagnostic listesi (Plan 08); adım =
   prompt sentezi → yama üretimi → tampona uygula → yeniden doğrula; tekrar.
   Çıkış: başarı / bütçe tükenmesi.
2. Deneme bütçesi: `rubik.yml`'den (`repair.max_attempts`, varsayılan 3); her
   deneme öncesi otomatik snapshot (Plan 03) — deneme başarısızsa o denemenin
   tampon değişikliği geri alınır (kısmi bozulma birikmez).
3. Kategoriye göre strateji tablosu: `:syntax` → küçük model + minimal bağlam;
   `:type`/`:undefined_ref` → sembol grafı zenginleştirmesi; `:test_failure` →
   test gövdesi + ilgili üretim kodu birlikte; her kategori için ayrı prompt şablonu.
4. Bağlamsal onarım: hata satırı ±10 satır + ilgili sembol tanımı (Plan 06) +
   önceki denemelerin özeti ("deneme 1'de X denendi, şu hata verdi").
5. Yama formatı: modelden unified diff veya tam dosya içeriği istenir; diff ise
   temiz uygulanır (bağlam kayması halinde tam dosya moduna düşüş).
6. Regresyon kontrolü: hedeflenen test geçtikten sonra etkilenen modülün tüm test
   paketi koşturulur; yeni kırılma varsa onarım geri alınır ve raporlanır.
7. Onarım geçmişi: aynı hatanın 2. denemesinde önceki yamanın neden başarısız
   olduğu modele açıkça anlatılır (tekrarlı başarısız döngü kırıcı).
8. REPL entegrasyonu: `[Rubik::Repair] Deneme 1/3 ...` canlı çıktısı; bütçe
   tükenince teşhisleri ham olarak kullanıcıya sunar — sessizce vazgeçmez.

## Kabul Kriterleri

- [ ] Fixture projede kasıtlı olarak bozulmuş 10 farklı hata türünün en az %80'i
      ilk 2 denemede otomatik çözülür (öneri §4.3 hedefi).
- [ ] Başarısız deneme arkasında temiz tampon bırakır; snapshot zinciri tutarlı.
- [ ] Regresyon kontrolü, "hedef testi geçirip başka testi kıran" yamayı reddeder.

## Bağımlılıklar

- Plan 10 (orkestrasyon), Plan 08 (teşhis), Plan 06 (bağlam), Plan 03 (snapshot).

## Test Stratejisi

- Birim: sahte LLM ile senaryo tabloları (her denemede düzelten model, hiç
  düzeltmeyen model, regresyon yaratan model).
- Entegrasyon: gerçek derleyicilerle fixture hata seti (her dil için 5+ vaka);
  ölçüm: çözüm oranı ve ortalama süre (< 60 sn hedefi).
