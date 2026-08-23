# 18 — Tree-sitter Çok Dilli Semantik AST ve LSP Entegrasyonu

**Durum:** ✅ **Tamamlandı** · **Zorluk:** Zor · **Öneri kaynağı:** §7.2 · **Faz:** 3–4 (Bağlam & Diller)  
**İlgili Planlar:** [06 — AST Semantik İndeks](06-ast-semantik-indeks.md) · [07 — Dil Adaptörleri](07-dil-adaptor-cercevesi.md) · [Index](index.md)

## Amaç

Ruby dışındaki hedef diller (**Zig, C, Go, Rust, Python**) için çok dilli sözdizim ağacı (AST) ayrıştırmasını sağlamak; tüm projede çapraz dilli fonksiyon, tip, struct, import ve bağımlılık grafı oluşturmak; sisteme bağlı dil sunucuları (LSP) ile iletişim köprüsü kurmak.

## Tamamlanan Görevler

1. Çok Dilli AST Ayrıştırıcıları:
   - `Rubik::AST::GoExtractor`: Go fonksiyonları, alıcı metotları (`(u *User).Greet`), struct ve interface yapıları, `import` blokları.
   - `Rubik::AST::RustExtractor`: Rust `fn`, `pub fn`, `struct`, `enum`, `trait`, `impl Block::method`, `use` bildirimleri.
   - `Rubik::AST::ZigExtractor`: Zig `pub fn`, `fn`, `const struct/enum`, `@import(...)` bildirimleri.
   - `Rubik::AST::CExtractor`: C/C++ fonksiyonları, `typedef struct/union/enum`, `#include` yönergeleri.
   - `Rubik::AST::PythonExtractor`: Python `def`, `class`, metotlar ve `import / from` blokları.
2. Evrensel Ayrıştırıcı Cephesi (`Rubik::AST::Extractor`):
   - Dosya uzantısına göre (`.rb`, `.go`, `.rs`, `.zig`, `.c`, `.h`, `.cpp`, `.py`) otomatik yönlendirme ve güvenli hata yakalama.
3. Çapraz Dilli `Rubik::AST::Graph`:
   - Çok dilli projelerdeki tüm sembolleri tek graf yapısında birleştirme, çağıranları listeleme (`callers_of`) ve dinamik dosya kaldırma/yeniden indeksleme.
4. LSP (Language Server Protocol) İstemci Köprüsü (`Rubik::LSP::Client`):
   - `gopls`, `rust-analyzer`, `zls`, `clangd`, `pylsp`, `solargraph` dil sunucuları ile JSON-RPC stdio protokolü.
   - `definition`, `references`, `initialize`, `shutdown` metotları ve sunucu bulunamadığında güvenli fallback.
5. Artımlı İndeksleme:
   - Bellek içi ve disk tamponu güncellemelerinde anlık (< 10ms) yeniden indeksleme.

## Kabul Kriterleri

- [x] Zig, Go, Rust, C ve Python dillerindeki fonksiyon, struct ve import tanımları tam satır aralıklarıyla sembol tablosuna çıkarılır.
- [x] Bir fonksiyona tıklandığında veya sorgulandığında projedeki tüm çağrıcıları (`callers_of`) doğru listelenir.
- [x] LSP sunucuları mevcut olmadığında sistem hatasız bir şekilde AST sembol grafından hizmet vermeye devam eder.

## Bağımlılıklar

- [Plan 06 (AST Sembol Tablosu)](06-ast-semantik-indeks.md)
- [Plan 05 (Bağlam Motoru: Dosya İndeksi)](05-baglam-motoru-dosya-indeksi.md)
- [Plan 07 (Dil Adaptör Çerçevesi)](07-dil-adaptor-cercevesi.md)

## Test Kapsamı

- `test/unit/test_multi_language_ast.rb`: Go, Rust, Zig, C, Python AST çıkarma, çağrı analizleri ve `Graph` çapraz indeksleme birim testleri.
- `test/unit/test_lsp_client.rb`: LSP sunucu haritalaması, kullanılabilirlik ve graceful fallback testleri.
