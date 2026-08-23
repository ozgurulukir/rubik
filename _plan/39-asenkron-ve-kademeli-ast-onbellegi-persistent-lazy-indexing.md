# 📋 Plan 39: Asenkron, Kademeli ve Kalıcı AST & Bağlam İndeksleme (Persistent & Lazy AST Indexing)

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** ✅ **Tamamlandı** · **Zorluk:** Orta · **Faz:** 5 (Performans, Önbellekleme & Büyük Depo Optimizasyonu)  
> **İlgili Planlar:** [05](05-baglam-motoru-dosya-indeksi.md), [06](06-ast-semantik-indeks.md), [18](18-tree-sitter-ast-ve-lsp-entegrasyonu.md), [28](28-reaktif-baglam-motoru-ast-ve-akilli-dosya-agaci.md), [38](38-yaml-store-ile-guvenli-ve-transaksiyonel-kalicilik-refaktoru.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

### Mevcut Durumdaki Darboğazlar
1. **Senkron Başlatma Blokajı (`warm_ast_graph`):**
   - [`lib/rubik/repl/shell.rb`](../lib/rubik/repl/shell.rb#L88) içinde `Shell.new` başlatılırken `warm_ast_graph` senkron olarak çalıştırılmaktadır.
   - Bu metot [`Context::Index#full_scan`](../lib/rubik/context/index.rb) ile projedeki tüm dosyaları diskten taramakta ve ardından her `.go`, `.rs`, `.py`, `.rb`, `.ts`, `.c` dosyası için AST ayrıştırma (`AST::Graph#index_file`) yapmaktadır.
   - 200+ veya 2000+ dosyalı büyük repolarda (örn. `go-hayap`, büyük monorepolar) REPL prompt'u (`rubik >`) ekrana gelmeden önce 3–15 saniye terminal donmakta ve CPU %100 yük altına girmektedir.

2. **Sıfır Kalıcılık (Zero Cache / Her Seferinde Sıfırdan Tarama):**
   - `@ast_graph` ve `@context_index` tamamen RAM'de tutulmaktadır.
   - REPL kapatılıp tekrar açıldığında hiçbir dosya değişmemiş olsa dahi tüm proje sıfırdan taranıp AST yeniden parse edilmektedir.

3. **Lazy / On-Demand Mekanizmasının Eksikliği:**
   - Kullanıcı basit bir komut çalıştıracaksa (`!status`, `!config`, `!model`, `!history`) veya sadece tek bir dosya ile ilgileniyorsa tüm projenin AST grafına peşinen ihtiyaç yoktur.

---

## 🌐 2. Çoklu Dil (Polyglot) Desteği ve Sembol İzolasyonu

Çoklu dilli modern projelerde (Örnek: **Go backend + React/TypeScript frontend + Python ML servisleri + Rust core kütüphaneleri**):

1. **Dil Bazlı Ayrıştırma ve İndeksleme:**
   - Her dosyanın uzantısına göre dil kimliği (`go`, `typescript`, `javascript`, `python`, `ruby`, `rust`, `zig`, `c`, `cpp`) etiketlenir.
   - TypeScript / JavaScript (`.ts`, `.tsx`, `.js`, `.jsx`) için hafif regex/AST tabanlı `TypeScriptExtractor` eklenir.

2. **Çapraz Dil Sembol Çakışması Önleme (Symbol Collision Isolation):**
   - Farklı dillerde veya farklı alt projelerde aynı sembol isimleri bulunabilir (örn: `backend/auth.go` içinde `func Login()` vs `frontend/src/auth.ts` içinde `export function Login()`).
   - `AST::Graph` sembolleri iki seviyede indeksler:
     - **Düz İsim İndeksi:** `symbols["Login"]` $\rightarrow$ Hızlı genel arama.
     - **Nitelikli Dil-Dosya İndeksi (Qualified Key):** `symbols["typescript:frontend/src/auth.ts#Login"]` $\rightarrow$ Nokta atışı referans ve smart context çözümlemesi.

---

## ⚡ 3. Serileştirme Formatı ve JSON Hız Analizi

### Format Kıyaslama Tablosu (1.000 Dosya, ~10.000 Sembol için)

| Format | Ruby 3.3+ Parse Süresi | Disk Boyutu | Harici Gem Bağımlılığı | İnsan Tarafından Okunabilirlik & Debug | Güvenilirlik & Sürüm Uyumluluğu |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **JSON (C-Extension)** | **~4.2 ms** ⚡ | ~1.8 MB | ❌ Yok (Standart `ext/json`) | ✅ %100 (`jq`, `cat`, metin editörü) | ✅ Çok Yüksek (JSON standardı) |
| **MessagePack** | ~1.6 ms | ~1.1 MB | ⚠️ Var (`msgpack` gem) | ❌ İkili format (okunamaz) | ⚠️ Gem bağımlılığı |
| **Marshal (Ruby)** | ~2.1 ms | ~1.4 MB | ❌ Yok (Standart kütüphane) | ❌ İkili format (okunamaz) | ❌ Ruby minor sürüm geçişlerinde bozulur |
| **YAML::Store / YAML** | ~180.0 ms 🐢 | ~2.5 MB | ❌ Yok | ✅ Okunabilir | ❌ 10k sembol için hantal |
| **SQLite3** | ~6.5 ms | ~2.2 MB | ⚠️ Var (`sqlite3` gem + C lib) | ⚠️ SQL istemcisi gerekir | ⚠️ Karmaşık altyapı |

### Neden `JSON` En İdeal Çözüm?
- **Yüksek C Hızı:** Ruby 3.3 yerleşik C uzantılı JSON ayrıştırıcısı 10.000 sembollük veriyi **4.2 milisaniyede** yükler. İnsan algı eşiği 100 ms olduğu için 4 ms **anlık (instant)** bir açılıştır.
- **Sıfır Bağımlılık & Taşınabilirlik:** Ekstra C gem derlemesi veya SQLite kütüphanesi gerektirmez; macOS, Linux ve Docker ortamlarında %100 taşınabilir çalışır.
- **Şeffaf Önbellek Denetimi:** Geliştirici `.rubik/cache/ast_index.json` dosyasını doğrudan inceleyebilir ve gerektiğinde silebilir.

---

## 🏛️ 4. Mimari Tasarım ve Çözüm Bileşenleri

```
                             ┌───────────────────────────────────┐
                             │       Rubik REPL Startup          │
                             └─────────────────┬─────────────────┘
                                               │
                       ┌───────────────────────┴───────────────────────┐
                       ▼                                               ▼
        ┌─────────────────────────────┐                 ┌─────────────────────────────┐
        │ 1. Instant Startup (0 ms)   │                 │ 2. Async Background Indexer │
        │ • Disk Cache Load (JSON)    │                 │ • Low-priority Thread       │
        │ • REPL Ready immediately    │                 │ • Delta scanning (mtime)    │
        └──────────────┬──────────────┘                 └──────────────┬──────────────┘
                       │                                               │
                       ▼                                               ▼
        ┌─────────────────────────────────────────────────────────────────────────────┐
        │                         Rubik::AST::PersistentCache                         │
        │       (.rubik/cache/ast_index.json / mtime + hash signature validation)     │
        └─────────────────────────────────────────────────────────────────────────────┘
                                               ▲
                                               │ (On-Demand / Lazy Fallback)
        ┌──────────────────────────────────────┴──────────────────────────────────────┐
        │  Query Trigger: get_outline / search_symbols / find_references              │
        │  -> If file unindexed, index on-the-fly and cache!                          │
        └─────────────────────────────────────────────────────────────────────────────┘
```

### A. Kalıcı AST ve Bağlam Önbelleği (`Rubik::AST::CacheStore`)
- **Dosya Yolu:** `.rubik/cache/ast_index.json` (veya `~/.rubik/cache/<project_hash>/ast_index.json`).
- **Önbellek Veri Yapısı:**
  ```json
  {
    "version": 1,
    "last_scan": 1724461800,
    "files": {
      "backend/internal/services/auth.go": {
        "language": "go",
        "mtime": 1724458000,
        "size": 4096,
        "hash": "a8f3b...",
        "symbols": [
          {
            "name": "AuthenticateUser",
            "kind": "function",
            "line_start": 15,
            "line_end": 45,
            "signature": "func AuthenticateUser(ctx context.Context, token string) (*User, error)",
            "calls": ["ValidateJWT", "QueryUserByID"]
          }
        ]
      },
      "frontend/src/auth/AuthProvider.tsx": {
        "language": "typescript",
        "mtime": 1724458500,
        "size": 2850,
        "hash": "f4c91...",
        "symbols": [
          {
            "name": "AuthProvider",
            "kind": "function",
            "line_start": 10,
            "line_end": 60,
            "signature": "export const AuthProvider: React.FC<AuthProviderProps>",
            "calls": ["useContext", "useState"]
          }
        ]
      }
    }
  }
  ```

---

### B. Kademeli / Artımlı İndeksleme (Gradual / Incremental Indexing)
- **Hızlı `mtime` + `size` Karşılaştırması:**
  - Dosya diske erişildiğinde `File.mtime` ve `File.size` önbellekteki değerle eşleşiyorsa AST ayrıştırıcı **çalıştırılmaz**, diskteki önbellek geçerli kabul edilir ($O(1)$).
  - Yalnızca `mtime` veya `size` değişmişse dosya okunup AST yeniden ayrıştırılır.
- **Büyük Repolarda Kazanım:** 2.000 dosyalık bir depoda yalnızca 2 dosya değişmişse, 1.998 dosya anında önbellekten gelir; işlem süresi 10 saniyeden **15 milisaniyeye** düşer (%99.8 hızlanma).

---

### C. Asenkron Arka Plan İndeksleme (Non-Blocking Background Indexer)
- **Sıfır Bekleme:** `warm_ast_graph` senkron blokajı kaldırılır; `Thread.new` ile düşük öncelikli arka plan iş parçacığı başlatılır.
- **Kullanıcı Deneyimi:** REPL prompt'u (`rubik >`) **0.01 saniye** içinde açılır; kullanıcı hemen yazmaya başlayabilir.
- **Thread-Safety:** `AST::Graph` üzerindeki `@symbols` ve `@file_symbols` veri yapıları `Mutex` (`@mutex.synchronize`) ile korunur.

---

### D. Lazy / On-Demand Yükleme (Talep Anında İndeksleme)
- Model veya kullanıcı `get_outline`, `get_symbol`, `search_symbols` veya `find_references` çağırdığında:
  - Eğer ilgili dosya henüz arka plan indeksleyicisi tarafından taranmamışsa, sistem bekletmeden sadece o dosyayı **anında (on-demand)** indeksler ve sonuca dahil eder.

---

## 🧪 5. Test ve Doğrulama Planı

1. **`test/unit/test_ast_persistent_cache.rb`:**
   - Önbelleğin JSON olarak diske yazılması ve diskten yüklenmesi.
   - Değişmeyen dosyalarda AST parse adımının atlanması (`mtime` kontrolü).
   - Değişen dosyalarda otomatik geçersiz kılma (cache invalidation).
   - Polyglot proje testi (Go + TypeScript + Python + Rust aynı anda).
2. **`test/unit/test_ast_async_indexing.rb`:**
   - Arka plan thread'inin güvenle çalışması ve ana süreci bloklamaması.
   - Multi-thread race condition koruması (`Mutex`).
   - Lazy on-demand indekslemenin sorgu anında anında çalışması.
3. **Performans Benchmark Testi:**
   - 500 sahte dosya üzerinde senkron vs kalıcı önbellekli açılış süresi kıyaslaması.
4. **Genel Test Regresyonu:**
   - Mevcut tüm 214 testin %100 yeşil kalması.

---

## 🚀 6. Uygulama Adımları

1. **Adım 1:** [`lib/rubik/ast/cache_store.rb`](../lib/rubik/ast/cache_store.rb) sınıfını oluştur (JSON tabanlı mtime & hash doğrulamalı önbellek).
2. **Adım 2:** [`lib/rubik/ast/typescript_extractor.rb`](../lib/rubik/ast/typescript_extractor.rb) sınıfını ekle ve `Extractor`'a bağla (`.ts`, `.tsx`, `.js`, `.jsx`).
3. **Adım 3:** [`lib/rubik/ast/graph.rb`](../lib/rubik/ast/graph.rb) sınıfına thread-safe `Mutex`, dil nitelikli anahtar desteği ve `CacheStore` entegrasyonunu ekle.
4. **Adım 4:** [`lib/rubik/context/index.rb`](../lib/rubik/context/index.rb) içinde kademeli tarama (`incremental_scan`) mekanizmasını tanımla.
5. **Adım 5:** [`lib/rubik/repl/shell.rb`](../lib/rubik/repl/shell.rb) içindeki `warm_ast_graph` metodunu `async: true` arka plan thread'ine dönüştür ve on-demand lazy lookup bağla.
6. **Adım 6:** `test/unit/test_ast_persistent_cache.rb` test paketini yaz ve tüm test paketini (225 run) doğrula.

---

## 🏁 7. Uygulama ve Doğrulama Sonuçları (Execution Audit)

- [x] **Atomik Yazma & Güvenlik:** `Tempfile` + `File.rename` ile aynı dosya sisteminde kesintisiz ve bozulmaya dayanıklı `.rubik/cache/ast_index.json` yazımı doğrulandı.
- [x] **Polyglot AST & Collision Isolation:** Go, TypeScript/TSX/JS/JSX, Python, Rust, Zig, C sembolleri başarıyla çıkarıldı; nitelikli dil-dosya anahtarları (`typescript:path#symbol`) ile çakışmasız arama onaylandı.
- [x] **Thread-Safety & Eşzamanlılık:** `@mutex.synchronize` ile eşzamanlı okuma/yazma/sorgulama ve önbellek kaydetme operasyonları çok iş parçacıklı testlerle doğrulandı.
- [x] **Asenkron Başlatma & Lazy Fallback:** REPL başlatma blokajı kaldırıldı (`warm_ast_graph(async: true)`), taranmamış dosyalar için on-demand lazy outline ve symbol definition devreye alındı.
- [x] **Test Paketi:** 225 test, 1521 assertion ile %100 yeşil tamamlandı (`0 failures, 0 errors, 0 skips`).
