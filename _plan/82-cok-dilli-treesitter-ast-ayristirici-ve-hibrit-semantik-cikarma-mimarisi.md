# 📋 Plan 82: Çok Dilli Tree-Sitter AST Ayrıştırıcı ve Hibrit Semantik Çıkarma Mimarisi (Python, Go, Rust, TypeScript, C, Zig ve Prism Koruması)

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** Zor · **Faz:** 6  
> **İlgili Planlar:** [06](06-ast-semantik-indeks.md), [18](18-tree-sitter-ast-ve-lsp-entegrasyonu.md), [28](28-olay-gudumlu-reaktif-baglam-ast-ve-akilli-calisma-alani-agaci.md), [39](39-asenkron-ve-kademeli-ast-onbellegi-persistent-lazy-indexing.md), [46](46-ast-ve-baglam-motorunun-reaktif-coeffect-servisine-donusturulmesi.md), [81](81-bash-ve-powershell-treesitter-guvenli-calistirma-ve-ast-katmani.md)

---

## 🎯 1. Araştırma Özeti ve İhtiyaç Analizi

### Soru: "Custom AST parser'ları Tree-Sitter varyantı ile değiştirelim mi?"
**Cevap: Evet, kesinlikle geçilmelidir.** Ancak geriye dönük tam uyumluluk, sıfır gerileme ve maksimum dayanıklılık için **Hibrit / Kademeli Geri Çekilme (Graceful Fallback)** mimarisiyle uygulanmalıdır.

### A. Mevcut Durum ve Regex/Heuristik Çıkarıcıların Zaafiyetleri
Rubik'in `lib/rubik/ast/` katmanında 7 farklı dil için semantik çıkarıcı bulunmaktadır:
1. **Ruby (`RubyExtractor`):** Ruby 3.3+ ile yerleşik gelen resmi **Prism** C ayrıştırıcısını kullanmaktadır. Tam AST düzeyinde çalışır, son derece hızlıdır ve geriye regex fallback (`FallbackCleaner`) desteği vardır. Bu mimari mükemmeldir ve korunmalıdır.
2. **Polyglot Diller (`PythonExtractor`, `GoExtractor`, `RustExtractor`, `TypeScriptExtractor`, `CExtractor`, `ZigExtractor`):** Tamamen satır satır regex taraması, girinti hesabı ve süslü parantez sayımı (`find_closing_brace`, `find_block_end`) ile çalışmaktadır.

Bu heuristik yaklaşımın sahada yarattığı kritik problemler:
- **String ve Yorum İçi Parantezler:** Kod içindeki stringlerde (`"{"`, `"}"`) veya blok yorumlarda (`/* ... */`) geçen parantezler blok sınırlarını (`line_start`, `line_end`) yanlış hesaplar.
- **Sahte Fonksiyon Çağrıları (False Positive Calls):** `body.scan(/\b([A-Za-z0-9_]+)\s*\(/)` deseni; yorum satırlarındaki veya stringlerdeki kelimeleri, `if (...)`, `while (...)`, `switch (...)` gibi dil anahtar kelimelerini yanlışlıkla sembolün bağımlılık grafına (`calls`) ekler.
- **Modern ve Çok Satırlı Sözdizimi Körlüğü:**
  - TypeScript/JSX: Arrow function'lar (`const Component = () => ...`), generic tipler (`<T, K>`), TSX tag'leri heuristik parantez sayımını bozar.
  - Python: Çok satırlı decorator'lar, async generator'lar, lambda ifadeleri.
  - Go: Pointer/değer metod alıcıları (`func (u *User) Greet()`), çoklu interface gömülmeleri.
  - Rust: `impl<T> Trait for Struct`, makro çağrıları (`println!`), modül içi enum tanımları.
  - C/C++: `#define` makroları, şablonlar (templates), struct typedef varyasyonları.

### B. Tree-Sitter Doğrulama ve Avantajları
Plan 81 ile sisteme eklenen [`tree_sitter_language_pack`](https://github.com/xberg-io/tree-sitter-language-pack) (v1.16+) gem'i incelenmiş ve test edilmiştir:
- **Sıfır Ekstra Bağımlılık:** Gem zaten Rubik'in `Gemfile`'ında mevcuttur; ek bir native gem kurulumuna gerek yoktur.
- **370+ Dil Desteği ve Pre-compiled Gramerler:** `python`, `go`, `rust`, `typescript`, `c`, `cpp`, `zig` gramerlerinin tamamı test edilmiş ve `TreeSitterLanguagePack.get_parser(lang)` ile Linux/macOS/Windows üzerinde sıfır derleme maliyetiyle anında çalıştığı kanıtlanmıştır.
- **Hata Toleransı (Error Resilience):** Model kod yazarken dosya eksik veya yarım olsa bile Tree-Sitter çökmeksizin sağlam AST düğümlerini (`has_error: true`) çıkarabilmektedir.
- **Hız ve Düşük Bellek:** C/Rust çekirdeği sayesinde yüzlerce satırlık dosyaları mikrosaniyeler içinde ayrıştırır.

---

## 🏛️ 2. Mimari Tasarım ve Hibrit Delegasyon

```
                               ┌────────────────────────────────┐
                               │   Rubik::AST::Extractor.extract │
                               └───────────────┬────────────────┘
                                               │
                      ┌────────────────────────┴────────────────────────┐
                      │                                                 │
             (Dosya Uzantısı .rb)                              (Polyglot Uzantılar)
                      │                                  .py, .go, .rs, .ts, .c, .zig
                      ▼                                                 │
       ┌──────────────────────────────┐                                 ▼
       │     RubyExtractor (Prism)    │                  ┌──────────────────────────────┐
       └──────────────┬───────────────┘                  │     TreeSitterExtractor      │
                      │                                  └──────────────┬───────────────┘
            Prism Başarısız ise                                         │
                      │                                     TreeSitter Başarısız ise
                      ▼                                                 │
       ┌──────────────────────────────┐                                 ▼
       │  Ruby FallbackCleaner Scanner│                  ┌──────────────────────────────┐
       └──────────────────────────────┘                  │   Legacy Regex Extractor     │
                                                         │ (GoExtractor, PyExtractor...)│
                                                         └──────────────────────────────┘
```

### Tasarım Değişmezleri (Invariants):
1. **Ruby İçin Prism Önceliği:** Ruby dosyalarında `Prism` kullanılmaya devam edilir. Tree-Sitter, Prism bulunmayan veya çöken ortamlarda alternatif olarak devreye girebilir.
2. **Kanonik Symbol Sözleşmesi:** Tree-Sitter tarafından çıkarılan her `Rubik::AST::Symbol` objesi mevcut şema (`name`, `kind`, `file`, `line_start`, `line_end`, `signature`, `calls`, `docstring`, `body_loader`) ile %100 uyumlu olmalıdır.
3. **Graceful Fallback:** Tree-Sitter kütüphanesinin yüklenemediği veya sözdizim ağacı çıkarımında beklenmeyen bir istisna fırlatılan durumlarda, eski regex çıkarıcıları sessizce devreye girerek sıfır kesinti sunar.
4. **Modül Sınırı Hijyeni:** Her dilin Tree-Sitter düğüm yürütücüsü (walker) bağımsız, odaklanmış ve modüler sınıflar olarak tasarlanır (her dosya < 200 satır).

---

## 🧱 3. Bileşenler ve Görev Dağılımı

### A. Ortak Tree-Sitter Tabanı (`lib/rubik/ast/treesitter/base_walker.rb`)
- Tüm dil yürütücülerinin miras alacağı temel yardımcı sınıf:
  - `text_for(node)`: Düğümün byte aralığına göre kaynak koddan tam metni alma (`code.byteslice(node.start_byte...node.end_byte)`).
  - `line_start(node)` / `line_end(node)`: 0-indexed row'ları 1-indexed Rubik satırlarına dönüştürme (`node.start_position.row + 1`).
  - `docstring_before(node)`: Düğümün hemen öncesindeki açıklama satırlarını toplama.
  - `body_loader_for(file_path, l_start, l_end)`: Bellek tasarruflu lazy body closure'ı.

### B. Dil Yürütücüleri (`lib/rubik/ast/treesitter/*.rb`)
1. **`PythonWalker` (`python_walker.rb`):**
   - `class_definition`: `name`, `bases`, `body`.
   - `function_definition`: `name`, `parameters`, `calls` (iç içe `call` düğümlerinden), `parent_class.method_name` formatı.
   - `import_statement`, `import_from_statement`: İçe aktarılan kütüphaneler.
2. **`GoWalker` (`go_walker.rb`):**
   - `type_spec`: `struct_type` $\rightarrow$ `:struct`, `interface_type` $\rightarrow$ `:interface`.
   - `method_declaration`: `(u *User).Greet` alıcı ve metod imzası.
   - `function_declaration`: Fonksiyonlar ve `calls` (`call_expression`).
   - `import_declaration`: Tekli ve parantezli `import (...)` bildirimleri.
3. **`RustWalker` (`rust_walker.rb`):**
   - `struct_item` $\rightarrow$ `:struct`, `enum_item` $\rightarrow$ `:enum`.
   - `impl_item`: İlgili tipin altındaki fonksiyonları `Type::method` olarak adlandırma.
   - `function_item`: Üst düzey ve impl fonksiyonları.
   - `use_declaration`: İçe aktarmalar.
   - `calls`: `call_expression` ve `macro_invocation` (`println!`, `vec!` vb.).
4. **`TypeScriptWalker` (`typescript_walker.rb`):**
   - Desteklenen uzantılar: `.ts`, `.tsx`, `.js`, `.jsx`.
   - `class_declaration`, `interface_declaration`, `enum_declaration`.
   - `method_definition` (`Class#method`), `function_declaration`.
   - `lexical_declaration`: Arrow function değişkenleri (`const AuthProvider = () => ...`).
   - `import_statement`: İçe aktarımlar.
5. **`CWalker` (`c_walker.rb`):**
   - Desteklenen uzantılar: `.c`, `.h`, `.cpp`, `.hpp`.
   - `struct_specifier`, `type_definition`, `function_definition`.
   - `preproc_include`: `#include <stdio.h>` direktifleri.
6. **`ZigWalker` (`zig_walker.rb`):**
   - `variable_declaration` (`const Buffer = struct { ... }`).
   - `function_declaration` (`pub fn initBuffer(...)`).
   - `@import` çağrıları.

### C. TreeSitterExtractor Cephesi (`lib/rubik/ast/treesitter_extractor.rb`)
- Dil tespiti: Dosya uzantısına göre TreeSitter dil adını çözer (`.py` $\rightarrow$ `"python"`, `.rs` $\rightarrow$ `"rust"`, `.ts`/`.tsx` $\rightarrow$ `"typescript"`, vb.).
- Thread-safe parser havuzu (`Thread.current[:rubik_ts_parsers]`).
- Parser çalıştırıp ilgili Walker'a AST'yi teslim eder.
- Çıktı: `Array<Rubik::AST::Symbol>`.

### D. Extractor Delegasyon Refaktörü (`lib/rubik/ast/extractor.rb`)
- `Extractor.extract(file_path, content = nil)`:
  - `.rb` ise `RubyExtractor` çağrılır.
  - Diğer uzantılarda `TreeSitterExtractor.extract` denenir.
  - Tree-Sitter kütüphanesi eksikse veya ayrıştırma hatası alınırsa, ilgili `GoExtractor`, `PythonExtractor`, vb. çağrılarak güvenli geri çekilme sağlanır.

---

## 📅 4. Uygulama Adımları (Phase Plan)

### Aşama 1: Tree-Sitter Altyapısı ve BaseWalker
- `lib/rubik/ast/treesitter/base_walker.rb` oluştur.
- `lib/rubik/ast/treesitter_extractor.rb` iskeletini kur.

### Aşama 2: Polyglot Walker Sınıflarının Kodlanması
- Python Walker (`python_walker.rb`)
- Go Walker (`go_walker.rb`)
- Rust Walker (`rust_walker.rb`)
- TypeScript / JavaScript / TSX / JSX Walker (`typescript_walker.rb`)
- C / C++ Walker (`c_walker.rb`)
- Zig Walker (`zig_walker.rb`)

### Aşama 3: Extractor Entegrasyonu ve Graceful Fallback
- `lib/rubik/ast/extractor.rb` dosyasını Tree-Sitter öncelikli, regex yedekli hibrit yapıya bağla.
- Eski extractor sınıflarını (`go_extractor.rb` vb.) dokunulmaz fallback olarak koru.

### Aşama 4: Birim ve Entegrasyon Testleri
- `test/unit/test_multi_language_ast.rb`: Mevcut testlerin Tree-Sitter ile %100 yeşil olduğunu doğrula.
- `test/unit/test_ast_persistent_cache.rb`: TS/TSX ve sembol önbellekleme testlerinin çalıştığını doğrula.
- `test/unit/test_treesitter_ast_extractors.rb`: Yeni kapsamlı test paketi:
  - String/yorum içi süslü parantezler.
  - Çok satırlı fonksiyon parametreleri ve karmaşık generics.
  - Arrow function'lar ve TSX JSX component ayrıştırması.
  - Gerçek çağrı grafı (`calls`) kesinliği (string/yorum/anahtar kelime kirliliğinin olmaması).
  - Fallback mekanizmasının simülasyonu (TreeSitter kapalıyken eski extractorların devreye girmesi).

### Aşama 5: Kalite, Hijyen ve Dokümantasyon
- Modül hijyeni testleri (`test_module_hygiene.rb`).
- RuboCop 0 offense doğrulaması.
- `ARCHITECTURE.md` ve `README.md` dosyalarının güncellenmesi.
- `_plan/00-index.md` indeksinin 82/82 olarak güncellenmesi.

---

## 🎯 5. Kabul Kriterleri (Acceptance Criteria)

1. **Sözdizim Kesinliği:** String veya yorum içinde `{}` içeren Go, Rust, TS veya Python kodları blok sonunu doğru tespit etmeli, sembol sınırları şaşmamalıdır.
2. **Temiz Bağımlılık Grafı (`calls`):** `calls` dizisi yalnızca gerçek fonksiyon çağrılarını içermeli; `if`, `for`, string içeriği veya yorumları çağırma olarak kaydetmemelidir.
3. **Geriye Dönük %100 Uyumluluk:** Mevcut tüm testlerin tamamı hiçbir kırılma olmadan yeşil kalmalıdır.
4. **Sıfır Yeni Bağımlılık:** `Gemfile`'a yeni harici gem eklenmemeli, mevcut `tree_sitter_language_pack` kullanılmalıdır.
5. **Fail-Safe Fallback:** Tree-Sitter grameri bulunamazsa veya istisna olursa sistem çökmemeli, eski regex çıkarıcıya geri dönmelidir.

---

## 🏆 6. Tamamlanma ve Doğrulama Raporu

- **Uygulanan Modüller:**
  - `lib/rubik/ast/treesitter/base_walker.rb`: Ortak AST gezicisi, `text_for`, `clean_signature`, `extract_calls`, `build_symbol`, `extract_lines` (BodyLoader uyumu).
  - `lib/rubik/ast/treesitter/python_walker.rb`: Sınıf, fonksiyon/metot, import ve docstring AST çıkarımı.
  - `lib/rubik/ast/treesitter/go_walker.rb`: Struct, interface, pointer alıcılı metotlar (`(u *User).Greet`), fonksiyonlar ve importlar.
  - `lib/rubik/ast/treesitter/rust_walker.rb`: Struct, enum, `impl` metotları (`Type::method`), fonksiyonlar, makro çağrıları (`println!`).
  - `lib/rubik/ast/treesitter/typescript_walker.rb`: Interface, enum, class, method (`Class#method`), arrow function/const fonksiyonlar, importlar, TSX JSX desteği.
  - `lib/rubik/ast/treesitter/c_walker.rb`: Include, typedef struct, struct ve fonksiyon bildirimleri.
  - `lib/rubik/ast/treesitter/zig_walker.rb`: Struct/enum const bildirimleri, fn prototipleri ve importlar.
  - `lib/rubik/ast/treesitter_extractor.rb`: `TreeSitterLanguagePack` entegrasyonu, uzantı haritalaması, thread-safe parser havuzu.
  - `lib/rubik/ast/extractor.rb`: Hibrit delegasyon kalkanı; `.rb` için Prism (`RubyExtractor`), diğer uzantılar için `TreeSitterExtractor`, hata veya kütüphane yokluğunda kademeli `FALLBACK_EXTRACTORS`.
- **Test ve Kalite Metrikleri:**
  - `test/unit/test_treesitter_ast_extractors.rb`: 6 yeni kapsamlı senaryo (string içi parantez, Rust makro/calls, TSX arrow function, Python async/docstring, fallback simülasyonu) — %100 yeşil.
  - `test/unit/test_module_hygiene.rb`: 8 runs, 44 assertions, 0 offenses — tüm yeni dosyalar < 185 satır (kural sınırı 350).
  - Tam Test Süiti: `1,324 runs, 8,024 assertions, 0 failures, 0 errors, 2 skips` (100% passed).
  - RuboCop: `353 files inspected, no offenses detected`.
