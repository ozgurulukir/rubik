# 📋 Plan 46: AST ve Bağlam Motorunun Reaktif Coeffect Servisine Dönüştürülmesi

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** Kolay–Orta · **Faz:** 5 (Spatiotemporal Coeffect Mimarisi)  
> **İlgili Planlar:** [05](05-baglam-motoru-dosya-indeksi.md), [06](06-ast-semantik-indeks.md), [18](18-tree-sitter-ast-ve-lsp-entegrasyonu.md), [20](20-spatiotemporal-runtime-context-ve-fiber-yasam-dongusu.md), [28](28-reaktif-baglam-motoru-ast-ve-akilli-dosya-agaci.md), [33](33-spatiotemporal-koefektler-ve-ters-islemler.md), [39](39-asenkron-ve-kademeli-ast-onbellegi-persistent-lazy-indexing.md), [45](45-spatiotemporal-oz-evrilen-calisma-zamani-ve-otonom-adaptor-sentezi.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

### Mevcut Durum & Motivasyon:
1. `Rubik::AST::Graph`, `Rubik::AST::CacheStore` ve `Rubik::Context::Index` nesneleri daha önce bağımsız nesneler olarak başlatılıp `Shell` veya `Registry` içine statik parametre olarak geçiliyordu.
2. `AGENTS.md` Bölüm 1.B ve 1.C uyarınca:
   - Ortamdaki her yetenek ve veri yapısı **açıkça bildirilmiş bir Coeffect Sözleşmesi** ($\Sigma \vdash C : \tau$) olmalıdır.
   - AST ve Bağlam indeksi birer `Context` Coeffect servisi (`"ast_graph"`, `"ast"`, `"context_index"`, `"index"`) olarak tescil edildiğinde, çalışma alanına yeni bir kök dizin eklendiğinde (`!workspace add`) veya temizlendiğinde LIFO ters işlemlerle otomatik senkronize olmalıdır.

---

## 🏛️ 2. Mimari Tasarım ve Coeffect Yaşam Döngüsü

```
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │                    Rubik Spatiotemporal Runtime Context (ctx)               │
 └──────────────────────────────────────┬──────────────────────────────────────┘
                                        │
                 ┌──────────────────────┴──────────────────────┐
                 ▼                                             ▼
  ┌─────────────────────────────┐               ┌─────────────────────────────┐
  │   Coeffect: "ast_graph"     │               │  Coeffect: "context_index"  │
  │ • Thread-safe Symbol Graph  │               │ • Incremental File Scanner  │
  │ • Async Cache Inverses      │               │ • Multi-Root Tracker        │
  │ • LIFO Dispose Handler      │               │ • Delta Change Notifier     │
  └─────────────────────────────┘               └─────────────────────────────┘
```

---

## ⚙️ 3. Uygulanan İyileştirmeler

### 3.1. AST Graph Coeffect Servisi (`Rubik::Runtime::ASTService`)
- `Rubik::Runtime::ASTService.register(context_or_manager, ast_graph, cache_store: nil)` modülü oluşturuldu.
- `Context#provide("ast_graph", ast_graph)` ve `Context#provide("ast", ast_graph)` ile servis tescil edilir.
- **Locality of Disposal (Ters İşlem Birlikteliği):**
  - Servis bağlama anında `ctx.on_dispose` ters işlemi kaydedilir.
  - Context dispose edildiğinde `ast_graph.save_to_cache(cache_store)` işletilir ve `ast_graph.clear` ile bellek sıfırlanır.

### 3.2. Context Index Coeffect Servisi (`Rubik::Runtime::IndexService`)
- `Rubik::Runtime::IndexService.register(context_or_manager, index)` ile `context_index` ve `index` servisleri reaktif bağlama eklenir.
- `IndexService.sync_roots(context_or_manager, index, additional_roots:, ast_graph: nil, cache_store: nil)` metodu ile çoklu kök dizin ekleme/çıkarma durumunda hem dosya indeksi hem de AST sembol tablosu tam senkronize edilir.

### 3.3. REPL & Araçlar ile Reaktif Coeffect Çözümlemesi
- `ListFilesTool` ve `GrepSearchTool`:
  - `context_index` getter'ı reaktif olarak `@runtime_context.get("context_index") || @runtime_context.get("index")` üzerinden çözümleme yapar.
- `SearchSymbolsTool`, `GetOutlineTool`, `FindReferencesTool`, `GetSymbolTool`:
  - `ast_graph` getter'ı reaktif olarak `@runtime_context.get("ast_graph") || @runtime_context.get("ast")` üzerinden çözümleme yapar.
- `Rubik::Tools::Registry.build_default`:
  - Tüm araçlara dinamik `runtime_context: ctx` referansı aktarılarak çalışma zamanında servis değişimlerine anında adapte olması sağlanır.

### 3.4. REPL Shell Yaşam Döngüsü
- `Rubik::REPL::Shell#initialize`:
  - `ASTService.register(@runtime_manager, @ast_graph, cache_store: @cache_store)` ve `IndexService.register(@runtime_manager, @context_index)` çağrıları ile çalışma zamanı bağlamına tescil edilir.
- `Rubik::REPL::Shell#stop`:
  - `@runtime_manager.dispose!` çağrısı ile tüm accumulator ters işlemleri LIFO sırasında çalıştırılarak önbellek diske yazılır ve bellek sızıntısız sonlanır.
- `Rubik::REPL::Commands::Workspace`:
  - Kök dizin ekleme (`add`) ve silme (`remove`) işlemlerinde `IndexService.sync_roots` çağrılarak reaktif güncellemeler tetiklenir.

---

## 🧪 4. Test ve Kalite Güvencesi

1. **`test/unit/test_ast_context_coeffect.rb`**:
   - `test_ast_service_registration_and_coeffects`: `"ast_graph"` ve `"ast"` coeffect'lerinin context üzerinden tescil ve erişimi.
   - `test_index_service_registration_and_coeffects`: `"context_index"` ve `"index"` coeffect'lerinin tescil ve erişimi.
   - `test_ast_service_locality_of_disposal`: `ctx.dispose` anında AST'nin diske kaydedilmesi ve bellek içi sembol tablosunun temizlenmesi.
   - `test_tools_reactive_coeffect_resolution`: Araçların coeffect dinamik olarak sağlandığında `not available` durumundan anında aktifleşmeye geçmesi.
   - `test_index_service_sync_roots`: Yeni kök dizin eklendiğinde dosya ve AST sembollerinin senkronize edilmesi.
2. **Mevcut Test Süiti Doğrulaması:**
   - `rake test` çalıştırıldı: **310 test, 2205 assertion, 0 failure, 0 error, 0 skip (%100 YEŞİL)**.
