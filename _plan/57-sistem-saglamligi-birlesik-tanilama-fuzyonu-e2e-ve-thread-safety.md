# 57 — Sistem Sağlamlığı, Birleşik Tanılama Füzyonu (Diagnostic Fusion), E2E Entegrasyon Testleri ve Thread-Safe AST

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Onaylandı (Review Tamamlandı)** · **Zorluk:** Orta–İleri Düzey · **Faz:** 6 (Sistem Sağlamlığı & Güvenilirlik)  
> **İlgili Planlar:** [03](03-dosya-tamponu-snapshot-undo.md), [06](06-ast-semantik-indeks.md), [08](08-statik-analiz-ve-derleyici-tanilama.md), [15](15-benchmark-kabul-testleri.md), [18](18-tree-sitter-ast-ve-lsp-entegrasyonu.md), [20](20-spatiotemporal-runtime-context-ve-fiber-yasam-dongusu.md), [25](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md), [29](29-lsp-derin-entegrasyonu-tanilama-ve-reaktif-geri-bildirim.md), [49](49-tam-kapsamli-cross-platform-ve-windows-uyumluluk-mimarisi.md), [54](54-step-executor-ve-arac-alani-moduler-refaktoru.md), [56](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md)  
> **Kapsam:** `lib/rubik/lsp/client.rb`, `lib/rubik/lsp/manager.rb`, `lib/rubik/ast/symbol.rb`, `lib/rubik/ast/graph.rb`, `lib/rubik/diagnostics/collector.rb` (yeni), `lib/rubik/config.rb`, `lib/rubik/buffer/manager.rb`, `lib/rubik/session/recorder.rb`, `lib/rubik/runtime/overlay_storage.rb`, `lib/rubik/prompt/context_builder.rb`, `lib/rubik/plugin/manager.rb`, `test/integration/test_e2e_agent_workflow.rb` (yeni), `test/integration/test_e2e_diagnostic_fusion.rb` (yeni), `PLUGINS.md` (yeni)

---

## 🎯 1. Hedef ve Gerekçe

Sistem değerlendirme raporu ve harici mimari denetim bulguları ışığında, Rubik kod tabanında sistem kararlılığını, hata ayıklanabilirliğini ve test derinliğini frontier seviyesine çıkaracak 7 temel alan tespit edilmiştir:

1. **LSP İstemci Dayanıklılığı ve Otomatik İyileşme (LSP Client Robustness):**
   - Mevcut `LSP::Client` JSON-RPC stdio istemcisi, sunucu çöktüğünde veya askıda kaldığında (hang) ajanı bloke etme riski taşımaktadır.
   - İstemciye; istek bazında açık zaman aşımı (per-request timeout), bağlantı sağlık kontrolü (`alive?`), sunucu çökmesinde otomatik yeniden başlatma (auto-restart / crash recovery) ve askıda kalan `@cv` isteklerinin anında temizlenmesi eklenmelidir.
2. **AST Tembel Yüklemesinde İş Parçacığı Güvenliği (Thread-Safe Lazy Body in AST):**
   - `AST::Symbol#body` metodu `@body_loader` closure'ını ilk erişimde çalıştırmaktadır. Çoklu iş parçacıklı (multi-threaded) ortamlarda veya asenkron indeksleme sırasında yarış durumu (race condition) oluşabilir. Bu erişim `@body_mutex` ile atomik/çift-kontrollü kilit (double-check locked) hale getirilmelidir.
3. **Birleşik Tanılama Füzyonu (Unified Diagnostic Collector / Fusion):**
   - Halihazırda LSP tanılamaları (`LSP::Manager`), derleyici/linter hataları (`Diagnostics::Parser`) ve test çıktıları (`Adapter::Base`) birbirinden bağımsız kanallardan akmaktadır.
   - `Diagnostics::Collector` modülü ile tüm statik, derleme zamanı ve çalışma zamanı tanılamaları tek bir yapılandırılmış veri modelinde birleştirilmeli; ciddiyet (`severity`), dosya ve satır bazında filtrelenerek hem sistem istemine (`<diagnostics>`) hem de REPL `!diagnostics` komutuna zengin ve tekil bir görünüm sunulmalıdır.
4. **Sessiz Hata Yutmaların (`rescue nil`) Temizlenmesi ve Açık Loglama:**
   - `Config`, `OverlayStorage` ve `Session::Recorder` gibi kritik bileşenlerde yer alan sessiz `rescue nil` kalıpları, tanı koyulamaz kör noktalar oluşturmaktadır. Bunlar kontrollü uyarı kayıtları (`warn` / logger) ve açık hata yönetimi ile değiştirilmelidir.
5. **Yapılandırma İçin Katı Şema Doğrulaması (Strict Config Schema with Typo Detection):**
   - `Config#validate_schema`, bilinmeyen anahtarlarda pasif uyarı verirken, katı modda (`strict: true`) bilinmeyen anahtarları `FuzzyMatcher` ile *"Unknown config key 'llm.stram'. Did you mean 'llm.stream'?"* şeklinde yönlendirici hata ile reddetmelidir.
6. **Büyük Bellek Tamponu Anlık Görüntü Optimizasyonu (Bounded Snapshotting):**
   - `Buffer::Manager#snapshot_state`, çok büyük dosyalarda tüm dosya içeriğini kopyalamak yerine bellek kullanımını sınırlandıracak ve donma yaratmayacak şekilde korunmalıdır.
7. **Çok Adımlı Uçtan Uca (E2E) Entegrasyon Testleri & Eklenti Geliştirme Rehberi:**
   - Ajan konuşmasını (prompt -> LLM stream -> tool calling -> `replace_file_content` -> diagnostics feedback -> test -> buffer apply) simüle eden çok adımlı E2E entegrasyon testleri ve `PLUGINS.md` eklenti geliştirme rehberi eklenmelidir.

---

## 🏛️ 2. Mimari ve Bileşen Tasarımları

```
                               ┌───────────────────────────────────────────────┐
                               │             Rubik Application Core            │
                               └───────────────────────┬───────────────────────┘
                                                       │
         ┌───────────────────────────────┬─────────────┴─────────────────┬───────────────────────────────┐
         ▼                               ▼                               ▼                               ▼
 ┌───────────────┐               ┌───────────────┐               ┌───────────────┐               ┌───────────────┐
 │  LSP Client   │               │ Diagnostics   │               │  AST::Symbol  │               │ Strict Config │
 │  Robustness   │               │   Collector   │               │ Thread Safety │               │   & Logging   │
 ├───────────────┤               ├───────────────┤               ├───────────────┤               ├───────────────┤
 │ • Auto-restart│               │ • LSP Diags   │               │ • Mutex sync  │               │ • Typo detect │
 │ • alive? check│               │ • Compilers   │               │ • Double-check│               │ • No bare nil │
 │ • Timeout gc  │               │ • Test Runner │               │ • Zero race   │               │ • Safe I/O    │
 └───────────────┘               └───────────────┘               └───────────────┘               └───────────────┘
```

---

## 🧩 3. Tasarım Kararları (Design Decisions)

### D-1: `LSP::Client` & `LSP::Manager` İyileştirilmiş Dayanıklılık
[`lib/rubik/lsp/client.rb`](file:///C:/Github/rubik/lib/rubik/lsp/client.rb):
- `LSP::Client#alive?`: `@running && @wait_thr&.alive? && @stdin && !@stdin.closed? && @stdout && !@stdout.closed?` kontrolüyle canlılık tespiti yapar.
- `LSP::Client#wait_for_response`: İstek zaman aşımına uğradığında `@responses.delete(req_id)` ile hafıza temizliği yapar; askıda kalan thread/condition variable bırakmaz.
- `LSP::Client#reconnect!`: Mevcut bağlantıyı güvenle kapatıp yeniden başlatır.

[`lib/rubik/lsp/manager.rb`](file:///C:/Github/rubik/lib/rubik/lsp/manager.rb):
- `ensure_healthy!(lang_or_client)`: İstemci çökmüş veya kapanmışsa otomatik olarak yeniden başlatır (`start_client`), böylece tek bir LSP çökmesi tüm ajan oturumunu kilitlemez.

### D-2: `AST::Symbol` İş Parçacığı Güvenliği (Double-Check Locking)
[`lib/rubik/ast/symbol.rb`](file:///C:/Github/rubik/lib/rubik/ast/symbol.rb):
- `AST::Symbol#initialize` içinde `@body_mutex = Mutex.new` tanımlanır.
- `body` metodu:
  ```ruby
  def body
    return @body if @body

    @body_mutex.synchronize do
      return @body if @body

      if @body_loader
        loader = @body_loader
        @body_loader = nil
        @body = self.class.scrub_if_invalid(loader.call)
      end
      @body ||= self.class.read_source_range(@file, @line_start, @line_end) if @file && !@line_start.nil?
      @body
    end
  end
  ```
- Eşzamanlı okuma ve warm-up indeksleme işlemlerinde yarış durumları (race conditions) ve gereksiz mükerrer disk okumaları sıfıra indirilir.

### D-3: `Rubik::Diagnostics::Collector` (Birleşik Tanılama Füzyonu)
[`lib/rubik/diagnostics/collector.rb`](file:///C:/Github/rubik/lib/rubik/diagnostics/collector.rb):
- **Kaynaklar:**
  1. `LSP::Manager#all_diagnostics` (Canlı derleyici / dil sunucusu çıktıları)
  2. `Diagnostics::Parser.parse` (Statik linter / compiler CLI çıktıları)
  3. `Adapter::Base` (Test çalıştırma hata raporları)
- **Normalizasyon:** Tüm tanılamaları standart `Diagnostics::Entry` (`file`, `line`, `col`, `severity`, `category`, `message`, `source`) nesnelerine dönüştürür.
- **Tekilleştirme & Sıralama:** Aynı dosya ve satırdaki tekrarlayan tanılamaları tekilleştirir, hataları uyarılardan önce (`:error` > `:warning` > `:info`) sıralar.
- **Çıktı & Entegrasyon:**
  - `format_for_context`: Sistem istemine `<diagnostics>` XML bloğu olarak iletilir.
  - `format_for_terminal`: REPL `!diagnostics` ve `!lint` komutları için renkli/estetik özet üretir.

### D-4: `rescue nil` Kalıplarının Temizlenmesi ve Açık Hata Yönetimi
- [`lib/rubik/config.rb`](file:///C:/Github/rubik/lib/rubik/config.rb), [`lib/rubik/runtime/overlay_storage.rb`](file:///C:/Github/rubik/lib/rubik/runtime/overlay_storage.rb), [`lib/rubik/session/recorder.rb`](file:///C:/Github/rubik/lib/rubik/session/recorder.rb):
  - Dosya sistemi ve dizin oluşturma işlemlerinde `rescue SystemCallError => e` yakalanarak `warn "[WARN] ..."` formatında görünür kılınır (özellikle `ENV["RUBIK_DEBUG"]` modunda).

### D-5: `Config` Katı Şema ve Typo Denetimi
- [`lib/rubik/config.rb`](file:///C:/Github/rubik/lib/rubik/config.rb) `validate_schema`:
  - `strict: true` modunda bilinmeyen konfigürasyon anahtarlarını `Rubik::Tools::FuzzyMatcher` ile karşılaştırır:
    `"Unknown config key 'llm.stram'. Did you mean 'llm.stream'?"` şeklinde yönlendirici `ArgumentError` fırlatır.

### D-6: Uçtan Uca (E2E) Entegrasyon Testleri
- [`test/integration/test_e2e_agent_workflow.rb`](file:///C:/Github/rubik/test/integration/test_e2e_agent_workflow.rb):
  - Mock LLM ile çok adımlı ajan iş akışını baştan sona simüle eder: prompt ➔ `list_files` ➔ `read_file` ➔ `replace_file_content` ➔ `run_tests` ➔ `finish`.
- [`test/integration/test_e2e_diagnostic_fusion.rb`](file:///C:/Github/rubik/test/integration/test_e2e_diagnostic_fusion.rb):
  - Derleyici syntax hatası ve LSP tanılamalarının `Diagnostics::Collector` ile toplanıp ajana geri bildirim sağladığını ve düzeltildiğini doğrulayan entegrasyon testi.

### D-7: `PLUGINS.md` Eklenti Mimarisi ve Geliştirici Kılavuzu
- [`PLUGINS.md`](file:///C:/Github/rubik/PLUGINS.md):
  - Rubik'in [`AGENTS.md`](file:///C:/Github/rubik/AGENTS.md) spatiotemporal eklenti mimarisini, Fiber yaşam döngüsünü, ters etki (revertible effect inverse) sözleşmesini, özel araç (`BaseTool`) ve REPL komut eklentisi yazımını anlatan detaylı geliştirici kılavuzu.

---

## 📋 4. Uygulama Adımları

- [ ] **Adım 1:** `lib/rubik/ast/symbol.rb` içine `@body_mutex` çift-kontrollü kilit (double-check lock) entegrasyonunun eklenmesi.
- [ ] **Adım 2:** `lib/rubik/lsp/client.rb` ve `lib/rubik/lsp/manager.rb` içine `alive?`, zaman aşımı temizliği ve otomatik kurtarma (auto-restart) mekanizmasının eklenmesi.
- [ ] **Adım 3:** `lib/rubik/diagnostics/collector.rb` modülünün oluşturulması ve `lib/rubik/prompt/context_builder.rb` ile REPL entegrasyonu.
- [ ] **Adım 4:** `lib/rubik/config.rb`, `lib/rubik/runtime/overlay_storage.rb` ve `lib/rubik/session/recorder.rb` içindeki `rescue nil` bloklarının güvenli ve loglanabilir hale getirilmesi; `Config#validate_schema` için strict typo kontrolü eklenmesi.
- [ ] **Adım 5:** `PLUGINS.md` eklenti geliştirici dokümantasyonunun oluşturulması.
- [ ] **Adım 6:** `test/unit/test_lsp_robustness.rb`, `test/unit/test_diagnostic_collector.rb`, `test/unit/test_ast_thread_safety.rb`, `test/integration/test_e2e_agent_workflow.rb` ve `test/integration/test_e2e_diagnostic_fusion.rb` testlerinin yazılması.
- [ ] **Adım 7:** Test süitinin (`bundle exec rake test`) %100 yeşil koşulması.

---

## 🛡️ 5. Risk ve Uç Durum Analizi

| Risk / Uç Durum | Olası Etki | Önleyici Tedbir |
| :--- | :--- | :--- |
| **LSP Sunucusunun Yanıt Vermemesi (Hung Process)** | Ajan isteği sonsuza kadar bekleyebilir. | `wait_for_response` metodunda kesin zaman aşımı (`timeout: 5`) uygulanır ve bekleyen ID `@responses.delete(req_id)` ile temizlenir. |
| **Büyük Dosyalarda AST/Collector Performansı** | Binlerce tanılama bellek tüketebilir. | `Collector` aynı dosya için en fazla 50 tanılamayı tutar, önem derecesine göre sıralar (`:error` > `:warning`). |
| **Eşzamanlı Bellek Okumalarında Kilitlenme (Deadlock)** | `Symbol#body` içindeki mutex kilitlenmeye yol açabilir. | Mutex yalnızca `@body_loader` çağrısını ve `@body` atamasını kapsar, harici kilitlerle iç içe geçmez. |

---

## 🎯 6. Kabul Kriterleri

1. `LSP::Client` sunucu çöktüğünde veya yanıt vermediğinde askıda kalmamalı, zaman aşımıyla güvenli hata döndürmeli ve `LSP::Manager` gerektiğinde yeniden başlatabilmelidir.
2. `AST::Symbol#body` eşzamanlı iş parçacıklarında yarış durumu olmadan thread-safe çalışmalıdır.
3. `Diagnostics::Collector` LSP, derleyici ve test tanılamalarını tek bir veri modelinde birleştirip sunmalıdır.
4. `Config` katı modda yazım hatalarını `FuzzyMatcher` ile tespit edip bildirmelidir.
5. Yeni E2E entegrasyon testleri (`test/integration/test_e2e_*.rb`) dahil tüm testler (`bundle exec rake test`) 0 failure, 0 error ile %100 yeşil geçmelidir.
6. `PLUGINS.md` eklenti geliştirici kılavuzu eksiksiz hazırlanmalıdır.
