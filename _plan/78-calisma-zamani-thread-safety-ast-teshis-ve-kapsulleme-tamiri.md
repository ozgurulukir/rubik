# 📋 Plan 78: Çalışma Zamanı Thread-Safety, Arka Plan AST Teşhis Kalkanı, LSP Kapsülleme Tamiri ve Sandbox Ağ Sertleştirmesi

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** Kolay–Orta · **Faz:** 6  
> **İlgili Planlar:** [20](20-spatiotemporal-composability-eklenti-dongusu.md), [71](71-calisma-zamani-saglamlastirma-lsp-devre-kesici-buffer-thread-safety-ve-izole-testler.md), [73](73-arac-katmani-sertlestirme-kapsulleme-ve-hata-ayristirma.md), [76](76-lsp-buffer-jit-senkronizasyonu-oturum-arac-kaydi-ve-modern-web-adaptoru.md), [77](77-tampon-cekisme-tespiti-gercek-unified-diff-ve-genel-audit-tamiri.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

Kod tabanı audit raporu (Scope & Health Check: 162 lib dosyası, ~20.7k satır, 1233 test, RuboCop 0 offense) kod tabanının yüksek kalitesini doğrulamakla birlikte, çoklu iş parçacıklı (multi-threaded) çalışma zamanı, hata görünürlüğü ve kapsülleme alanlarında haklı ve kritik 5 iyileştirme noktası saptamıştır:

### 1.1. `Runtime::Manager` İş Parçacığı Güvenliği Eksikliği (P1 — Concurrency Risk)
- **Problem:** `lib/rubik/runtime/manager.rb` içindeki `@fibers` hash'i hiçbir kilitleme mekanizması (`Monitor` / `Mutex`) olmadan işletilmektedir.
- **Risk:** REPL ortamında arka plan indeksleme iş parçacığı (`@indexer_thread`) ve servis sağlayıcıları eşzamanlı çalışırken, farklı thread'lerden gelen `register_fiber`, `unregister_component`, `provide` veya `reconcile_all` çağrıları `@fibers` tablosunu bozabilir veya `Fiber#activate!` adımlarıyla `reconcile_fiber` durum geçişleri arasında yarışma durumuna (race condition) neden olabilir.
- **Çözüm:** `Buffer::Manager` ve `LSP::Manager`'da başarıyla uygulanan `Monitor` senkronizasyon deseni `Runtime::Manager`'a uygulanmalı, tüm durum geçişleri ve kayıt operasyonları re-entrant `@monitor.synchronize` ile korunmalıdır.

### 1.2. `perform_warm_ast_graph` İçinde Hataların Sessizce Yutulması (P2 — Observability)
- **Problem:** `lib/rubik/repl/shell.rb:191-192` içinde arka planda yürütülen AST ön-ısıtma ve indeksleme işlemi çöktüğünde `rescue StandardError; nil; end` ile hata tamamen sessizce yutulmaktadır.
- **Risk:** AST ayrıştırıcısı veya önbellek deposu çöktüğünde sistem loglarına veya `event_bus` üzerine hiçbir bildirim düşmemekte, AST grafiği sessizce bayat kalmakta ve teşhis imkansızlaşmaktadır.
- **Çözüm:** `rescue StandardError => e` dalına `@logger&.warn("AST graph warm failed: #{e.message}")` ve `@event_bus&.emit(:ast_warm_failed, error: e.message)` eklenmeli; `shell.rb <= 620 satır` hijyen limiti korunmalıdır.

### 1.3. `LSP::Manager#sync_buffer_file` Kapsülleme İhlali (P2 — Encapsulation)
- **Problem:** `lib/rubik/lsp/manager.rb:248` satırında `client.instance_variable_get(:@open_documents)&.key?(...)` kullanılarak istemcinin özel iç değişkenine doğrudan erişilmektedir.
- **Risk:** Plan 73'te kararlaştırılan kapsülleme ilkelerine aykırıdır; `LSP::Client` iç yapısı refaktör edildiğinde sessizce kırılacaktır.
- **Çözüm:** `LSP::Client` sınıfına thread-safe `document_open?(file_path)` sorgu metodu eklenmeli ve `instance_variable_get` tamamen kaldırılmalıdır.

### 1.4. Sandbox Süreç Sürücüsü Ağ Değişkenleri & Ruby 3.3 Uyarıları (P3 — Network Guard)
- **Problem:** `lib/rubik/sandbox/driver/process.rb` içinde ağ erişimini engellemek için yalnızca büyük harfli `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` sahte adreslere yönlendirilmektedir.
- **Risk:** Ruby 3.3 `net/http` büyük harfli `HTTP_PROXY` için deprecation uyarısı vermektedir; ayrıca modern diller ve CLI araçları (curl, python, node, go) küçük harfli `http_proxy`, `https_proxy`, `all_proxy`, `no_proxy` değişkenlerine bakmaktadır.
- **Çözüm:** Hem küçük hem büyük harfli varyantlar tanımlanmalı, `no_proxy`/`NO_PROXY` sıfırlanmalı ve danışmanlık uyarısı güçlendirilmelidir.

### 1.5. Dokümantasyon, Badge ve Mimari Terminoloji Netleştirmesi (P3 — Doc Drift)
- **Problem:** `README.md` test badge'i 1070 testte kalmıştır; `Rubik::Runtime::Fiber` sınıfı Ruby'nin yerleşik `::Fiber` sınıfı ile isim benzerliği taşımaktadır; `Config::Store#save!` birleştirme davranışı dokümante edilmemiştir.
- **Çözüm:** Rozet 1233 teste güncellenmeli, `fiber.rb` ve `store.rb` içine mimari açıklamalar eklenmelidir.

---

## 🏛️ 2. Mimari Tasarım ve Çözüm Bileşenleri

```
                  ┌──────────────────────────────────────────────┐
                  │              PLAN 78 MİMARİSİ                │
                  └──────────────────────┬───────────────────────┘
                                         │
         ┌───────────────────────────────┼───────────────────────────────┐
         ▼                               ▼                               ▼
┌──────────────────┐           ┌──────────────────┐            ┌──────────────────┐
│ Runtime::Manager │           │  LSP Encapsulate │            │   Shell Observ.  │
│  Thread-Safety   │           │ Client#doc_open? │            │  ast_warm_failed │
├──────────────────┤           ├──────────────────┤            ├──────────────────┤
│ Monitor kilidi   │           │ instance_var_get │            │ Sessiz rescue'yu │
│ Re-entrant senkr.│           │ ihlali kalkar    │            │ log + event yap  │
│ Eşzamanlı test   │           │ Thread-safe sorgu│            │ shell <= 620 satır│
└──────────────────┘           └──────────────────┘            └──────────────────┘
```

### 2.1. Bileşen 1: `Runtime::Manager` Thread-Safety
- `lib/rubik/runtime/manager.rb`:
  ```ruby
  require "monitor"

  def initialize(context = nil)
    @context = context || Context.new
    @fibers = {}
    @monitor = Monitor.new
  end
  ```
- Tüm `@fibers` okuma/yazma ve durum geçiş metotları (`register_fiber`, `unregister_component`, `provide`, `swap_component`, `reconcile_all`, `reconcile_fiber`, `active_fibers`, `dispose!`) `@monitor.synchronize` korumasına alınır.

### 2.2. Bileşen 2: `LSP::Client#document_open?` ve Kapsülleme
- `lib/rubik/lsp/client.rb`:
  ```ruby
  def document_open?(file_path)
    abs_path = File.expand_path(file_path, @root_dir)
    @mutex.synchronize { @open_documents.key?(abs_path) }
  end
  ```
- `lib/rubik/lsp/manager.rb`:
  ```ruby
  if client.document_open?(file_path)
    client.did_change(file_path, content)
  else
    client.did_open(file_path, content)
  end
  ```

### 2.3. Bileşen 3: `perform_warm_ast_graph` Gözlemlenebilirlik
- `lib/rubik/repl/shell.rb`:
  ```ruby
  rescue StandardError => e
    @logger&.warn("AST graph warm failed: #{e.message}")
    @event_bus&.emit(:ast_warm_failed, error: e.message)
    nil
  end
  ```
- `shell.rb` satır sayısı `618 <= 620` olarak limit altında kalır.

### 2.4. Bileşen 4: Sandbox Ağ Değişkenleri
- `lib/rubik/sandbox/driver/process.rb`:
  ```ruby
  unless allow_network
    dead_proxy = "http://127.0.0.1:9999"
    env["http_proxy"] = dead_proxy
    env["https_proxy"] = dead_proxy
    env["all_proxy"] = dead_proxy
    env["no_proxy"] = ""
    env["HTTP_PROXY"] = dead_proxy
    env["HTTPS_PROXY"] = dead_proxy
    env["ALL_PROXY"] = dead_proxy
    env["NO_PROXY"] = ""
  end
  ```

### 2.5. Bileşen 5: Dokümantasyon ve Terminoloji
- `README.md`: `tests-1239%20runs%20%7C%20100%25%20passed-brightgreen.svg` (1233 taban + 6 yeni concurrency testi).
- `lib/rubik/runtime/fiber.rb`: AGENTS.md Spatiotemporal Composability atfı ve yerleşik `::Fiber` ile ayrım notu.
- `lib/rubik/config/store.rb`: `save!` içindeki `deep_merge` mantığına dair açıklama yorumu.

---

## 📋 3. Uygulama Adımları

1. **`lib/rubik/runtime/manager.rb`:** `Monitor` ekle, tüm metotları thread-safe hale getir.
2. **`lib/rubik/lsp/client.rb` & `lib/rubik/lsp/manager.rb`:** `Client#document_open?` ekle, `instance_variable_get`'i kaldır.
3. **`lib/rubik/repl/shell.rb`:** `perform_warm_ast_graph` içine `@logger&.warn` ve `@event_bus&.emit(:ast_warm_failed)` ekle.
4. **`lib/rubik/sandbox/driver/process.rb`:** Küçük ve büyük harf proxy değişkenlerini ekle.
5. **`lib/rubik/runtime/fiber.rb` & `lib/rubik/config/store.rb` & `README.md`:** Açıklamaları ve rozetleri güncelle.
6. **Testler:** `test/unit/test_runtime_manager_concurrency.rb` ve ilgili birim testlerini ekle.
7. **Doğrulama:** `rake test` (1233+ test %100 yeşil), `rubocop` (0 offense), modül satır limitleri kontrolü.
