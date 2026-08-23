# 18 — Tree-sitter Çok Dilli Semantik AST ve LSP Entegrasyonu

**Zorluk:** Zor · **Öneri kaynağı:** §7.2 · **Faz:** 3–4 (Bağlam & Diller)  
**İlgili Planlar:** [06 — AST Semantik İndeks](06-ast-semantik-indeks.md) · [07 — Dil Adaptörleri](07-dil-adaptor-cercevesi.md) · [Index](index.md)

## Amaç

Ruby dışındaki hedef diller (Zig, C, Go, Rust, Python) için **Tree-sitter** C/FFI bağlantılarını kurarak regex tabanlı taramayı gerçek sözdizim ağacı (AST) ayrıştırmasına yükseltmek; tüm projede çapraz dilli fonksiyon, tip, struct ve bağımlılık grafı oluşturmak.

## Görevler (kolaydan zora)

1. `tree-sitter` Ruby FFI Sarmalayıcısı: Tree-sitter paylaşımlı kütüphanelerine erişen dinamik yükleme katmanı.
2. Diller için S-Expression (`.scm`) sorgu şablonları:
   - **Go**: `(function_declaration)`, `(method_declaration)`, `(type_spec)`
   - **Rust**: `(function_item)`, `(struct_item)`, `(impl_item)`
   - **Zig**: `(fn_proto)`, `(container_decl)`
   - **C**: `(function_definition)`, `(struct_specifier)`
   - **Python**: `(function_definition)`, `(class_definition)`
3. `Rubik::AST::TreeSitterExtractor`: Her dil için kaynak kodu Tree-sitter ile ayrıştırıp standart `Rubik::AST::Symbol` nesnelerine dönüştürme.
4. Çapraz dilli `Rubik::AST::Graph`: C header include'ları, Go paket bağımlılıkları, Rust crate referansları ve Zig `@import` ilişkilerinin tek graf yapısında birleştirilmesi.
5. LSP Köprüsü (Language Server Protocol): Projede `gopls`, `rust-analyzer`, `zls`, `clangd` mevcutsa stdio üzerinden `textDocument/definition` ve `textDocument/references` sorgularını çekerek sembol ilişkilerini zenginleştirme.
6. Artımlı AST Yeniden İndeksleme: Sadece diskte veya tamponda güncellenen dosyanın AST düğümlerini yeniden parse edip grafı < 100ms içinde güncelleme.

## Kabul Kriterleri

- [ ] Zig, Go, Rust ve C dillerindeki karmaşık struct, makro ve fonksiyon tanımları tam satır aralıklarıyla sembol tablosuna çıkarılır.
- [ ] Bir fonksiyona tıklandığında veya sorgulandığında projedeki tüm çağrıcıları (`callers_of`) doğru listelenir.
- [ ] Tree-sitter kütüphanesi sistemde yoksa güvenli şekilde hafif regex fallback'e düşer.

## Bağımlılıklar

- [Plan 06 (AST Sembol Tablosu)](06-ast-semantik-indeks.md)
- [Plan 05 (Bağlam Motoru: Dosya İndeksi)](05-baglam-motoru-dosya-indeksi.md)
- [Plan 07 (Dil Adaptör Çerçevesi)](07-dil-adaptor-cercevesi.md)

## Test Stratejisi

- Birim: Her dil için (Zig, C, Go, Rust, Python) altın fixture kaynak dosyaları ve beklenen sembol JSON çıktıları.
- Performans: 10.000 satırlık çok dilli projede tam indeksleme < 5 sn, artımlı güncelleme < 50 ms.
