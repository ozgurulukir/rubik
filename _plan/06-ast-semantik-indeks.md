# 06 — AST Sembol Tablosu ve Bağımlılık Grafı

**Zorluk:** Zor · **Öneri kaynağı:** §7.2 · **Faz:** 2

## Amaç

Dosya indeksinin üstüne semantik katman: Prism (Ruby) ve Tree-sitter (diğer diller)
ile fonksiyon/tip/import çıkarımı, sembol tablosu, çağrı/bağımlılık grafı ve
**akıllı bağlam seçimi** (LLM'e gönderilecek minimal kod parçaları).

## Görevler (kolaydan zora)

1. `Rubik::Context::Symbol`: `{name, kind(:function|:struct|:class|:import), file,
   line_range, signature}` kaydı.
2. **Ruby/Prism ekstraktörü** (en olgun yol — önce bu): sınıf/modül/metot tanımları,
   imzalar, require'lar.
3. Tree-sitter entegrasyonu: `ffi` ile C bağlantısı; Zig, Go, C için sorgu dosyaları
   (`.scm`) — her dilde önce yalnızca fonksiyon + struct + import.
4. `Rubik::Context::Graph`: semboller düğüm, çağrılar/importlar kenar olan graf;
   "bu sembolü kim çağırıyor?" / "bu modüle kim bağımlı?" sorguları.
5. Artımlı yeniden indeksleme: Plan 05'in dosya izleyicisinden değişiklik olayı →
   yalnızca o dosyanın sembolleri çıkar, graf kenarları onarılır.
6. **Akıllı bağlam seçimi:** görev "fonksiyon X'i değiştir" ise → X'in gövdesi +
   çağırdığı fonksiyonların imzaları + ilgili tip tanımları; ham dosya değil.
   Hedef: token tüketiminde %60–80 azalma (Plan 15'te ölçülür).
7. LSP köprüsü (opsiyonel derinleştirme): en az 2 dil için tanım/referans sorguları
   ile graf doğruluğunun artırılması.

## Kabul Kriterleri

- [ ] Ruby fixture projede tüm metotlar doğru satır aralıklarıyla bulunur.
- [ ] Bir dosya düzenlendiğinde yalnızca o dosyanın sembolleri güncellenir
      (< 2 sn); diğer sembollere dokunulmaz.
- [ ] Akıllı seçim, tam dosya gönderimine göre ölçülebilir biçimde daha az token
      üretir ve hedef sembolün gövdesini eksiksiz içerir.

## Bağımlılıklar

- Plan 05 (dosya indeksi, izleyici).

## Test Stratejisi

- Birim: her dil için küçük fixture dosya + beklenen sembol listesi (altın dosyalar).
- Entegrasyon: iki dosyalı proje; A'daki fonksiyon B'de çağrılıyor → graf sorgusu;
  B düzenlenince yalnızca B'nin güncellendiği iddiası.
- Performans: 10k satır fixture'da tam indeksleme < 10 sn.
