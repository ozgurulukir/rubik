# 📋 Plan 83: Dış Denetim İyileştirmeleri — Yönetilen Thread'ler, Test Adaptör Zekası, `ComponentFiber` ve Dinamik Rakefile

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** Orta · **Faz:** 6  
> **İlgili Planlar:** [07](07-dil-adaptor-cercevesi.md), [15](15-benchmark-kabul-testleri.md), [20](20-spatiotemporal-composability-eklenti-dongusu.md), [29](29-lsp-derin-entegrasyonu-tanilama-ve-reaktif-geri-bildirim.md), [76](76-lsp-buffer-jit-senkronizasyonu-oturum-arac-kaydi-ve-modern-web-adaptoru.md), [78](78-calisma-zamani-thread-safety-ast-teshis-ve-kapsulleme-tamiri.md), [82](82-cok-dilli-treesitter-ast-ayristirici-ve-hibrit-semantik-cikarma-mimarisi.md)

---

## 🎯 1. Motivasyon ve Dış Denetim Bulguları

Rubik mimarisinin bağımsız dış denetiminde (external audit) elde edilen yüksek değerli ve yapıcı geri bildirimler doğrultusunda, kod tabanının `AGENTS.md` prensiplerine %100 sadakati ve operasyonel ergonomisi güçlendirilecektir:

1. **Yönetilmeyen İş Parçacıkları (`Thread.new` - AGENTS.md §5 İhlali):**
   `AGENTS.md` §5 "Forbidden Anti-Patterns: Starting unmanaged background tasks outside ctx" kuralına rağmen `lsp/client.rb:290` (`@reader_thr`), `repl/shell.rb:73` (`@indexer_thread`) ve `ui/spinner.rb` doğrudan çıplak `Thread.new` ile başlatılmaktadır. Özellikle LSP client yeniden başlatıldığında (`!lsp restart`) reader thread'in deterministik `kill + join` ile temizlenmesi Context LIFO kalkanına bağlanmalıdır.
2. **Test Adaptörü Yanlış Algılama:**
   `discovery.rb:105` satırında `TEST_RUNNER_MARKERS["ruby"]` içinde `Gemfile` için ilk aday `bundle exec rspec` olarak hardcode edilmiştir. Projede `spec/` dizini yoksa ama `test/` veya `Rakefile` varsa sistem gereksiz yere rspec çalıştırmamalı; `bundle exec rake test` adayını ilk sıraya almalı ve `.rubik/config.yaml` içinden proje test komutu ipucu (`project.test_command` / `adapter.ruby.test_command`) kabul edebilmelidir.
3. **`Rakefile` `test:fast` Statik Dosya Listesi Kokusu:**
   `Rakefile:31-45` içinde `test:fast` sabit 13 dosyalık bir liste tutmaktadır. Yeni eklenen birim testleri bu listeye otomatik girmemekte ve sessizce bayatlamaktadır. Dinamik globbing ve yavaş testleri hariç tutma (`exclude`) mimarisine geçilmelidir.
4. **İsimlendirme Çatışması (`Rubik::Runtime::Fiber` vs `::Fiber`):**
   Ruby'nin yerleşik korutin sınıfı `::Fiber` ile isim çatışmasını önlemek için birincil sınıf adı `ComponentFiber` yapılmalı, geriye dönük tam uyumluluk ve AGENTS.md terminolojisi için `Fiber = ComponentFiber` alias'ı sunulmalıdır.
5. **`Context#dispose` Servis Sıralama Dayanıklılığı:**
   Inverse çalıştırma esnasında bir ara hata fırlasa dahi servislerin deterministik sırayla kaldırıldığı testlerle garanti altına alınmalıdır.

---

## 🏛️ 2. Mimari Tasarım ve Değişiklikler

```
                               ┌──────────────────────────────────────────────┐
                               │       PLAN 83 MİMARİ MÜDAHALE HARİTASI       │
                               └──────────────────────┬───────────────────────┘
                                                      │
             ┌────────────────────────┬───────────────┴────────┬────────────────────────┐
             ▼                        ▼                        ▼                        ▼
  ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐
  │  Rakefile test:fast │  │ discovery.rb Zekası │  │ Managed Threads (Ω) │  │   ComponentFiber    │
  ├─────────────────────┤  ├─────────────────────┤  ├─────────────────────┤  ├─────────────────────┤
  │ Dinamik glob:       │  │ spec/ yoksa ->      │  │ LSP reader thread   │  │ ::Fiber shadowing   │
  │ FileList["test/unit │  │ rake test seç.      │  │ kill + join(0.5).   │  │ riskini kaldır.     │
  │ /**/test_*.rb"]     │  │ config ipucu:       │  │ Shell indexer thread│  │ Fiber =             │
  │ .exclude(slow_tests)│  │ adapter.ruby.test_cmd│  │ close ile temizlenir│  │ ComponentFiber alias │
  └─────────────────────┘  └─────────────────────┘  └─────────────────────┘  └─────────────────────┘
```

---

## 📋 3. Uygulama Adımları

### Adım 1: `Rakefile` `test:fast` Görevinin Dinamikleştirilmesi
- `Rakefile` içindeki statik dosya listesini kaldır.
- `FileList["test/unit/**/test_*.rb"]` üzerinden dinamik tarama yap; yalnızca bilinen ağır/ağır entegrasyon testlerini hariç tut (`.exclude(...)`).

### Adım 2: `discovery.rb` Test Koşucusu Algılama Zekası ve Konfigürasyon Desteği
- `lib/rubik/runtime/discovery.rb`:
  - Ruby için dinamik test koşucu çözücü:
    - Çalışma alanında `spec/` dizini varsa -> `["bundle exec rspec", "bundle exec rake test", "rake test"]`.
    - Çalışma alanında `spec/` yok, `test/` veya `Rakefile` varsa -> `["bundle exec rake test", "rake test", "bundle exec rspec"]`.
  - Konfigürasyon önceliği: `config&.fetch("adapter.ruby.test_command", nil)` veya `project.test_command` varsa doğrudan ilk sıraya al.
- `lib/rubik/config/defaults.rb`:
  - `adapter` altına opsiyonel `test_command` alanı ekle (satır sınırı < 150 korunarak).

### Adım 3: Yönetilen İş Parçacıkları (Managed Threads)
- `lib/rubik/lsp/client.rb`:
  - `@reader_thr` için `stop` metodunda `@reader_thr&.kill` sonrasında deterministik `@reader_thr&.join(0.5)` zaman aşımı koruması.
  - İstemci nesnesi `on_dispose` bağlamına uygun temizleme metotları ile donatılmalı.
- `lib/rubik/repl/shell.rb`:
  - `@indexer_thread` iş parçacığı shell'in `close` / `dispose` döngüsüne eklenerek temizlenmeli (KRİTİK: `shell.rb <= 620 satır` kuralı).
- `lib/rubik/ui/spinner.rb`:
  - Thread durdurma ve `ensure` koruması pekiştirilmeli.

### Adım 4: İsimlendirme Güvenliği (`ComponentFiber`)
- `lib/rubik/runtime/fiber.rb`:
  - `class ComponentFiber` tanımla.
  - `Fiber = ComponentFiber` alias'ını ekle.
- Dokümantasyon ve referanslarda `::Fiber` korutinlerinden ayrımını netleştir.

### Adım 5: Doğrulama ve Testler
- `test/unit/test_discovery_test_runner.rb`: `spec/` yokluğunda `rake test` seçildiğini ve config ipucunun çalıştığını doğrulayan testler.
- `test/unit/test_runtime_fiber.rb`: `ComponentFiber` alias ve temel durum makinesi testleri.
- `test/unit/test_runtime_context.rb`: Inverse hatalarında servis temizleme determinizmi.
- Tam test süiti (`rake test`, `rake test:fast`) ve RuboCop (0 offense).

---

## 🎯 4. Kabul Kriterleri (Acceptance Criteria)

1. **Dinamik Rakefile:** `rake test:fast` komutu yeni birim testlerini otomatik çalıştırır; statik dosya listesi kalmaz.
2. **Kusursuz Test Algılama:** Minitest kullanan projelerde (Rubik dahil) `spec/` yoksa harness asla `rspec` çalıştırmaz, `bundle exec rake test`'i seçer.
3. **Zombi Thread Koruması:** LSP client durdurulduğunda veya yeniden başlatıldığında reader thread kesinlikle `join` ile sonlandırılır.
4. **Ad Çakışması Engeli:** `Rubik::Runtime::ComponentFiber` hem doğrudan hem `Fiber` alias'ı ile %100 geriye dönük uyumlu çalışır; `::Fiber` gölgelemesi biter.
5. **Sıfır Gerileme:** Tüm testler (%100 yeşil) ve RuboCop (0 offense) korunur.

---

## ✅ Uygulama Sonucu ve Deviation Log

> **Durum:** Uygulandı
> **Doğrulama:** 5 kabul kriterinin kod karşılıkları hedef dosyalarda doğrulandı

### Kabul Kriterleri → Kod

| # | Kriter | Kod karşılığı |
|:--|:--|:--|
| 1 | Dinamik Rakefile (`test:fast`) | `Rakefile:28` `Rake::TestTask.new(:fast)`, `FileList` dinamik |
| 2 | Minitest/rspec algılama | `lib/rubik/runtime/discovery.rb` test harness algılaması |
| 3 | Zombi thread koruması (LSP) | `lib/rubik/lsp/client.rb:146` `@reader_thr&.join(0.5)` + `:155` `@wait_thr.join` |
| 4 | `ComponentFiber` + `::Fiber` geri uyum | `lib/rubik/runtime/fiber.rb:106` `Fiber = ComponentFiber` |
| 5 | Sıfır gerileme | Tam suite yeşil, RuboCop 0 offense |

### Kayıtlı Deviation

- **Sapma yok.** 83'ün tüm kabul kriterleri kodda birebir karşılık buldu; `runtime/` modülü (`manager.rb`, `fiber.rb`, `loop_service.rb`, `discovery.rb`) plan kapsamıyla örtüşüyor.
- **Not:** `Fiber = ComponentFiber` alias'ı `fiber.rb` sonunda (satır 106) yer alır — gölgelemenin `::Fiber` ile karışmaması için modül içi alias kullanılır.
