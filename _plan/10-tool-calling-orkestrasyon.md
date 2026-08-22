# 10 — Tool-Calling ve Plan→Act→Verify Orkestrasyonu

**Zorluk:** Zor · **Öneri kaynağı:** §7.5, §8 · **Faz:** 2–3

## Amaç

Rubik'in beyni: LLM'in JSON Schema ile tanıtılmış araçları (dosya oku/yaz-tampona,
komut çalıştır, test koştur) kullanarak plan üretmesi; orkestratörün bu çağrıları
güvenlik katmanına geçirip sırayla uygulaması ve her adımı doğrulaması.

## Görevler (kolaydan zora)

1. Araç tanım modeli: `{name, description, params(JSON Schema), risk(:read|:write|
   :execute)}`; tanımlar Ruby DSL ile yazılır, JSON Schema'ya serileştirilir.
2. İlk araç seti (yalnızca güvenli olanlar): `read_file`, `list_files`,
   `search_symbols` (Plan 06 graf sorgusu), `run_tests`.
3. `Rubik::Orchestrator::Loop`: kullanıcı görevi + bağlam (Plan 06 akıllı seçim) +
   araç şemaları → LLM'e; yanıt tool-call ise uygula, sonucu geri besle; bitiş
   koşulu: model `finish` aracını çağırdığında.
4. Döngü sınırı: maksimum adım sayısı (varsayılan 15) ve toplam token bütçesi;
   aşılırsa özetle durur, sessizce dönmez.
5. Yazma aracı: `write_file(path, content)` — diske değil **tampona** yazar
   (Plan 03); risk `:write` işaretlenir.
6. Yürütme aracı: `run_command(cmd, timeout)` — Plan 13 sandbox'a kadar yalnızca
   izinli komut beyaz listesiyle (derleyici/test ikilikleri) çalışır.
7. `!plan <görev>`: orkestratörü salt-plan modunda koşturur; adımları basar,
   onay ister; onaylanan plan aynı oturumda uygulanır.
8. Yanıt doğrulama: modelin ürettiği kod içeriği ilgili adaptörün `check_syntax`'undan
   geçirilir; hatalıysa teşhisle birlikte düzeltme turuna (Plan 11) devredilir.
9. Prompt sentezi optimizasyonu: sistem talimatı + rol tanımları sabitlenir;
   bağlam bölümü Plan 06'dan gelir; geçmiş denemeler özetlenerek eklenir.

## Kabul Kriterleri

- [ ] Uçtan uca demo: "src/ altına FizzBuzz modülü yaz ve testlerini koştur" görevi,
      Ollama yerel modeliyle, tampon üzerinden çözülür; disk yalnızca `!apply` ile
      değişir.
- [ ] Model var olmayan araç çağırırsa orkestratör hatayı modele geri besler
      (tek tur), ikinci kez de olursa düzgün şekilde durur.
- [ ] Adım/token bütçesi aşıldığında oturum canlı kalır ve özet raporlanır.

## Bağımlılıklar

- Plan 09 (LLM), Plan 06 (bağlam), Plan 07 (araçların arkasındaki adaptörler),
  Plan 03 (tampon).

## Test Stratejisi

- Birim: sahte LLM (önceden kaydedilmiş tool-call dizileri) ile döngü makinesi —
  bitiş, bütçe aşımı, hatalı araç çağrısı yolları.
- Entegrasyon: fixture projede sahte modelle uçtan uca görev; gerçek modelle
  manuel kabul senaryoları belgelenir.
