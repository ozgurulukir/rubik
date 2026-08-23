# 28 — Olay Güdümlü Reaktif Bağlam, Gelişmiş AST Araç Seti ve Akıllı Dosya Ağacı Mimarisi

**Durum:** ✅ **Tamamlandı** · **Zorluk:** Orta–Zor · **Öneri kaynağı:** Kullanıcı Geri Bildirimi · **Faz:** 5 (Reaktif Çalışma Zamanı & Bağlam Zekası)  
**İlgili Planlar:** [05 — Bağlam Motoru](05-baglam-motoru-dosya-indeksi.md) · [06 — AST Semantik İndeks](06-ast-semantik-indeks.md) · [18 — Tree-sitter AST & LSP](18-tree-sitter-ast-ve-lsp-entegrasyonu.md) · [23 — XML Yapılandırılmış Bağlam](23-xml-yapilandirilmis-baglam-ve-agents-protokol-entegrasyonu.md) · [27 — Tampon Auto-Apply](27-tampon-kirli-durum-hatirlatici-ve-akilli-ping-sistemi.md) · [Index](index.md)

---

## 🔍 Tespit Edilen Problem & Mimari İhtiyaçlar

1. **Yalın Dosya Sayısının Yetersizliği:**
   - Modele sadece `<indexed_files count="42">` vermek dosya adlarını içermediği için model her seferinde ekstra `list_files` turu harcamaktaydı.
   - Küçük projelerde ($\le 30$ dosya) dosya listesinin doğrudan XML'e verilmesi ("Fast-Path"), büyük projelerde ise kök dizinler ve giriş noktalarının (`entry_points`) verilmesi sağlandı.

2. **Sıfır Polling — Olay Güdümlü Reaktif Güncelleme (AGENTS.md Uyumlu):**
   - Dosya indeksini ve AST grafiğini sürekli periyodik (polling) taramak gereksiz CPU ve disk I/O yükü yaratır.
   - Bağlam ve AST senkronizasyonu tamamen **olay güdümlü (event-driven)** yapıldı:
     - Başlangıçta (Cold start) 1 kez indeksleme / ısınma (`warm_ast_graph`).
     - `!apply` / `buffer_manager.apply!` tetiklendiğinde değiştirilen/oluşturulan dosyalar için anında `Context::Index#update_file` ve `AST::Graph#index_file`.

3. **Gelişmiş Native AST Araç Seti:**
   - Sadece `search_symbols` ile yetinilmeyip, modelin büyük dosyaları okumadan yapıyı anlaması ve refactor güvenliği sağlaması için 3 kritik araç eklendi:
     - `get_outline(file_path)`: Dosya semantik iskeleti (class/fn/method imzaları ve satır aralıkları).
     - `find_references(symbol_name)`: Sembolün çağrıldığı yerleri ve bağımlılıklarını listeleme.
     - `get_symbol(symbol_name)`: Hedef metodun AST gövdesini ve parametrelerini izole çekme.
4. **REPL Komut Eşleşmesi:**
   - Kullanıcıların terminalden doğrudan sorgulama yapabilmesi için `!symbols`, `!outline`, `!refs` ve `!ast` komutları eklendi.

---

## 🎯 Çözüm Mimarisi

```text
┌────────────────────────────────────────────────────────────────────────┐
│             OLAY GÜDÜMLÜ (EVENT-DRIVEN) BAĞLAM & AST SİSTEMİ           │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  1. Akıllı Hibrit Çalışma Alanı Ağacı (ContextBuilder XML)             │
│     • Küçük Projeler (≤ 30 dosya):                                     │
│       <workspace_files count="1">                                      │
│         <file lang="html">index.html</file>                            │
│       </workspace_files>                                               │
│     • Büyük Projeler (> 30 dosya):                                     │
│       <workspace_structure>                                            │
│         <top_level_directories>bin/, lib/, test/</top_level_directories>│
│         <entry_points>Gemfile, bin/rubik, Rakefile</entry_points>      │
│       </workspace_structure>                                           │
│                                                                        │
│  2. Reaktif Olay Güdümlü Senkronizasyon (Zero-Polling)                 │
│     • !apply / buffer_manager.apply! ──► sync_context_and_ast(files)   │
│         ├── Context::Index#update_file(path)                           │
│         └── AST::Graph#index_file(path)                                │
│                                                                        │
│  3. Gelişmiş Native AST Araç Seti (Model Toolbelt - 16 Araç)           │
│     • search_symbols(query, smart_context)                             │
│     • get_outline(file_path)                                           │
│     • find_references(symbol_name)                                     │
│     • get_symbol(symbol_name)                                          │
│                                                                        │
│  4. REPL AST & Sembol Komutları                                        │
│     • !symbols <query>  ──► Sembol, sınıf ve fonksiyon araması         │
│     • !outline <file>   ──► Dosya AST semantik iskeleti                │
│     • !refs <symbol>    ──► Sembolü çağıran referanslar                │
│     • !ast <file>       ──► Dosya AST sembol ağacı dökümü              │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 📋 Tamamlanan Görevler

1. **`AST::Graph#outline_for` & `symbol_definition` (`lib/rubik/ast/graph.rb`):**
   - Dosya sembol iskeleti ve izole sembol dökümü metotları eklendi.
2. **Yeni Native AST Araçlarının Eklenmesi (`lib/rubik/tools/builtins.rb`):**
   - `GetOutlineTool`: `get_outline(file_path)`
   - `FindReferencesTool`: `find_references(symbol_name)`
   - `GetSymbolTool`: `get_symbol(symbol_name)`
3. **`Tools::Registry.build_default` Güncellemesi (`lib/rubik/tools/registry.rb`):**
   - 3 yeni araç kaydedilerek toplam native araç sayısı **16**'ya çıkarıldı.
4. **`ContextBuilder.build_workspace_xml` Güncellemesi (`lib/rubik/prompt/context_builder.rb`):**
   - $\le 30$ dosya için kompakt `<workspace_files>` çıktısı.
   - $> 30$ dosya için `<workspace_structure>` üst dizinler ve giriş noktaları.
5. **Reaktif Olay Güdümlü Senkronizasyon (`lib/rubik/repl/shell.rb`):**
   - `sync_context_and_ast(files)` metodu ile `apply` sonrası taze indeksleme.
   - `warm_ast_graph` ile başlangıçta AST grafiğini doldurma.
6. **REPL `!symbols`, `!outline`, `!refs`, `!ast` Komutları (`lib/rubik/repl/shell.rb`):**
   - Konsoldan doğrudan AST sorgulama sağlandı.
7. **Birim Testleri (`test/unit/test_reactive_context_and_ast.rb`):**
   - 7 test, 54 assertion ile tüm senaryolar doğrulandı (toplam test paketi 130 run, 690 assertion).

---

## 🧪 Kabul Kriterleri

- [x] $\le 30$ dosya olan projelerde (örn: `snakeRubik`) dosya adı doğrudan XML bağlamına yazılır, model ekstra tur harcamaz.
- [x] Hiçbir arka plan polling / sleep döngüsü çalışmaz; güncelleme sadece `apply` veya dosya değişim olayında tetiklenir.
- [x] `get_outline`, `find_references`, `get_symbol` native araçları doğru JSON/metin çıktısı üretir.
- [x] `!symbols`, `!outline`, `!refs` REPL komutları terminalde beklenen AST sonuçlarını basar.
- [x] Tüm testler yeşil geçer (130 runs, 690 assertions).
