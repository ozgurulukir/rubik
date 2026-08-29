# 59 — Çekirdek Güvenliği, Sentez Sandbox Yalıtımı, Bare Rescue İyileştirmeleri ve Modüler Test Görevleri

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Onaylandı (Review Tamamlandı)** · **Zorluk:** Kolay–Orta · **Faz:** 6 (Kod Sağlığı & Güvenlik Sertleştirme)  
> **İlgili Planlar:** [03](03-dosya-tamponu-snapshot-undo.md), [10](10-ajan-dongusu-ve-arac-entegrasyonu.md), [12](12-guvenlik-diff-onay.md), [20](20-spatiotemporal-runtime-context-ve-fiber-yasam-dongusu.md), [24](24-kendi-kendini-gelistiren-arac-sentezi.md), [45](45-spatiotemporal-oz-evrilen-calisma-zamani-ve-otonom-adaptor-sentezi.md), [49](49-tam-kapsamli-cross-platform-ve-windows-uyumluluk-mimarisi.md), [54](54-step-executor-ve-arac-alani-moduler-refaktoru.md), [57](57-sistem-saglamligi-birlesik-tanilama-fuzyonu-e2e-ve-thread-safety.md), [58](58-elm-tarzi-sistem-hatalari-utf8-bagisikligi-ve-hata-toleransli-tarama.md)  
> **Kapsam:** `lib/rubik/orchestrator/loop.rb`, `lib/rubik/orchestrator/stream_manager.rb`, `lib/rubik/buffer/manager.rb`, `lib/rubik/tools/builtins/synthesis.rb`, `lib/rubik/tools/registry.rb`, `lib/rubik/adapter/registry.rb`, `lib/rubik/security/guard.rb`, `Rakefile`, `test/unit/test_synthesis_security.rb` (yeni)

---

## 🎯 1. Hedef ve Gerekçe

Codebase incelemesi ve oturum geri bildirimleri sonucunda, sistemin güvenliğini, kod temizliğini ve geliştirici/test ergonomisini artıracak 5 odak alanı belirlenmiştir:

1. **Gereksiz Hata Sınıfı Yakalamalarının (Redundant Rescue) Sadeleştirilmesi:**
   - `Loop#execute_batch_request` ve `StreamManager#execute_streaming_request` içinde `rescue Rubik::LLM::ClientError, StandardError` kalıbı bulunmaktadır. `ClientError < StandardError` olduğu için bu ifade gereksiz tekrardır; `rescue StandardError => e` olarak sadeleştirilmelidir.
2. **`Buffer::Manager#apply!` İçindeki Geniş Bare Rescue'nun İyileştirilmesi:**
   - `apply!` metodunda yer alan `(sanitize_path(...) rescue p)` ifadesi tüm hataları yutmaktadır. Bu ifade yalnızca `Rubik::Buffer::InvalidPathError` ve beklenen yol ayrıştırma hatalarını yakalayacak şekilde özelleştirilmelidir.
3. **Otonom Araç ve Komut Sentezleme Güvenliği (`AGENTS.md` §3 ve Sandbox Yalıtımı):**
   - `SynthesizeToolTool` ve `SynthesizeCommandTool` araçları canlı Ruby kodu değerlendirdiği (`eval`) için en yüksek güvenlik hassasiyetine sahip alandır.
   - Sentezlenen kod çalıştırılmadan önce `Security::Guard` denetiminden geçirilmeli (tehlikeli sistem çağrıları, `Kernel.exec`, zararlı dosya silme kalıpları engellenmeli), `test_args` ön-doğrulaması izole bir alt bağlamda (`ctx.extend()`) ve zaman aşımı (`Timeout.timeout(5)`) koruması altında çalıştırılmalıdır (`AGENTS.md` §3).
4. **`Registry#swap` Monitor Yeniden Giriş (Reentrancy) Güvencesinin Belgelenmesi:**
   - `Tools::Registry` ve `Adapter::Registry` sınıflarında `swap` metodundaki iç içe `@monitor.synchronize` çağrısı, Ruby'nin `Monitor` sınıfının `reentrant` yapısı sayesinde güvenlidir. Bunun nedeni ve kilitlenme (deadlock) oluşturmadığı mimari yorum satırlarıyla açıklanmalı; `Adapter::Registry` de thread-safe hale getirilmelidir.
5. **Rakefile Test Görevlerinin Modülerleştirilmesi:**
   - Tüm test paketi ardışık çalıştırıldığında zaman almaktadır. Hızlı geliştirme döngüleri ve CI için `rake test:unit`, `rake test:integration` ve `rake test:fast` görevleri eklenmelidir.

---

## 🧩 2. Tasarım Kararları (Design Decisions)

### D-1: Hata Yakalama Hiyerarşisi Temizliği
[`lib/rubik/orchestrator/loop.rb`](file:///C:/Github/rubik/lib/rubik/orchestrator/loop.rb) ve [`lib/rubik/orchestrator/stream_manager.rb`](file:///C:/Github/rubik/lib/rubik/orchestrator/stream_manager.rb):
- `rescue Rubik::LLM::ClientError, StandardError => e` ifadesi `rescue StandardError => e` olarak sadeleştirilir.
- `Interrupt` (Ctrl+C) yakalanmaz; konsol geri yükleme ve anında iptal davranışı korunur.

### D-2: `Buffer::Manager#apply!` Açık Hata Yakalama
[`lib/rubik/buffer/manager.rb`](file:///C:/Github/rubik/lib/rubik/buffer/manager.rb):
- `(sanitize_path(p, for_write: true) rescue Rubik::Buffer::InvalidPathError => _e; p)` şeklinde yalnızca beklenen yol normalizasyon hatalarını yakalar.

### D-3: `SynthesizeToolTool` ve `SynthesizeCommandTool` Güvenlik ve Alt-Bağlam Yalıtımı (`AGENTS.md` §3)
[`lib/rubik/tools/builtins/synthesis.rb`](file:///C:/Github/rubik/lib/rubik/tools/builtins/synthesis.rb):
1. **Güvenlik Doğrulaması:** Sentezlenecek kod `eval` edilmeden önce `Rubik::Security::Guard` tarafından taranır; yıkıcı dosya silme (`rm -rf /`, `del /s`), fork bomb, yetkisiz shell exec çağrıları engellenir (`BlockedWriteError` / `Security blocked`).
2. **İzole Alt Bağlam (`ctx.extend()`):** Ön-doğrulama testi çalıştırılırken ana çalışma zamanını kirletmemek için `sub_ctx = @runtime_manager.context.extend("synth_test_#{name}")` oluşturulur.
3. **Zaman Aşımı Koruması (`Timeout.timeout(5)`):** `test_args` yürütmesi 5 saniye ile sınırlandırılır; sonsuz döngü içeren sentezlenmiş kodlar ajanı bloke edemez.
4. **Ters Etki (LIFO Inversion):** Başarılı kayıt sonrası `context.on_dispose { registry.unregister(name) }` kuralı uygulanır.

### D-4: `Registry` Monitor Reentrancy ve Thread-Safety Dokümantasyonu
[`lib/rubik/tools/registry.rb`](file:///C:/Github/rubik/lib/rubik/tools/registry.rb) ve [`lib/rubik/adapter/registry.rb`](file:///C:/Github/rubik/lib/rubik/adapter/registry.rb):
- Ruby `Monitor` kütüphanesinin `reentrant` (yeniden girilebilir) kilit mimarisi sayesinde, bir iş parçacığının `swap` içinde `unregister` ve `register`'ı çağırmasının kilitlenmeye yol açmadığı dokümante edilir.
- `Adapter::Registry` sınıfı da `Monitor` ile sarmalanarak dinamik adaptör kaydı için iş parçacığı güvenli hale getirilir.

### D-5: Modüler Rakefile Test Görevleri
[`Rakefile`](file:///C:/Github/rubik/Rakefile):
- `rake test`: Tüm testleri koşturur (varsayılan).
- `rake test:unit`: `test/unit/**/test_*.rb` dosyalarını koşturur.
- `rake test:integration`: `test/integration/**/test_*.rb` dosyalarını koşturur.
- `rake test:fast`: Kritik yol birim testlerini (config, buffer, tools, security, commands) koşturur.

---

## 📋 3. Uygulama Adımları

- [ ] **Adım 1:** `lib/rubik/orchestrator/loop.rb` ve `lib/rubik/orchestrator/stream_manager.rb` içindeki redundant rescue ifadelerinin `rescue StandardError => e` olarak sadeleştirilmesi.
- [ ] **Adım 2:** `lib/rubik/buffer/manager.rb` içindeki bare rescue'nun `Rubik::Buffer::InvalidPathError` ile değiştirilmesi.
- [ ] **Adım 3:** `lib/rubik/tools/builtins/synthesis.rb` içine `@guard.verify_command_safety!`, `Timeout.timeout(5)` koruması ve izole `ctx.extend()` test bağlamının eklenmesi.
- [ ] **Adım 4:** `lib/rubik/tools/registry.rb` ve `lib/rubik/adapter/registry.rb` içine `Monitor` reentrancy dokümantasyonunun eklenmesi; `Adapter::Registry`'nin `Monitor` ile thread-safe yapılması.
- [ ] **Adım 5:** `Rakefile` içine `test:unit`, `test:integration` ve `test:fast` görevlerinin eklenmesi.
- [ ] **Adım 6:** `test/unit/test_synthesis_security.rb` test dosyasının oluşturulması (tehlikeli kod engelleme, 5s timeout doğrulaması, alt bağlam temizliği).
- [ ] **Adım 7:** Test süitinin (`bundle exec rake test:unit` ve `bundle exec rake test`) %100 yeşil koşulması.

---

## 🎯 4. Kabul Kriterleri

1. `Loop` ve `StreamManager` içindeki exception hiyerarşisi temiz ve uyarı vermeden çalışmalıdır.
2. `SynthesizeToolTool` ve `SynthesizeCommandTool` tehlikeli sistem komutlarını ön-doğrulamada engellemeli ve sonsuz döngü içeren araçlarda 5 saniye zaman aşımı ile güvenle hata döndürmelidir.
3. `Rakefile` üzerinden `rake test:unit`, `rake test:integration` ve `rake test:fast` ayrı ayrı çalıştırılabilmelidir.
4. Tüm testler (`bundle exec rake test`) 0 failure, 0 error ile %100 yeşil geçmelidir.
