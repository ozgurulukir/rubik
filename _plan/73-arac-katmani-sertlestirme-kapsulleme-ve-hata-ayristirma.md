# 📋 Plan 73: Araç Katmanı Sertleştirme, Kapsülleme İyileştirmeleri ve Deterministik Hata Ayrıştırma (Tool Layer Hardening)

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** Kolay–Orta · **Faz:** 6 (Gelişmiş Ajan Ergonomisi & Kod Sağlığı)  
> **İlgili Planlar:** [10](10-tool-calling-orkestrasyon.md), [17](17-yerel-arac-cagrilari-ve-router.md), [20](20-spatiotemporal-runtime-context-ve-fiber-yasam-dongusu.md), [24](24-kendi-kendine-evrilen-arac-sentezi-ve-calisma-zamani-denetimi.md), [32](32-agentic-tool-cagrilari-yapilandirilmis-io-ve-akilli-baglam-kirpma.md), [44](44-llm-egitim-uyumlu-arac-isimlendirmesi-grep-ve-tool-aliasing.md), [52](52-yerlesik-arac-hizlandirma-native-offload-ve-lazy-hash.md), [54](54-kod-sagligi-ve-modulerlik-dis-degerlendirme-bulgulari.md), [56](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md), [58](58-elm-tarzi-sistem-hatalari-utf8-bagisikligi-ve-hata-toleransli-tarama.md)

---

## 🎯 1. Problem ve Dış Değerlendirme Bulgularının Analizi

Rubik Araç Katmanı (`lib/rubik/tools/` ve `Orchestrator::StepExecutor`), kod tabanının en olgun ve sağlam katmanlarından biri olarak değerlendirilmiş ("Verdict: Excellent (A)"); ancak 5 adet mimari sertleştirme ve temizleme alanı tespit edilmiştir:

### 1.1. `is_err` 13 Dallı Dize Sezgisi Kırılganlığı (`step_executor.rb:91-104`)
- **Mevcut Durum:** `StepExecutor#execute_tool`, araç çıktısının başarı/hata durumunu 13 farklı dize başlangıcı (`raw_output.start_with?("-- ")`, `"Error:"`, `"Failed"`, vb.) ile sezgisel olarak belirlemektedir.
- **Risk:** Gelecekte bir araç başarılı bir çıktıda örneğin `"Failed attempts summary: ..."` gibi bir ifade dönerse, bu çıktı yanlışlıkla `:error` olarak sınıflandırılabilir.
- **Hedef:** Araçların doğrudan `Tools::Result` veya bir hata nesnesi (`Tools::Failure`) dönebilmesine izin vermek; `StepExecutor`'da öncelikle bu nesnenin statüsünü okumak, yalnızca düz `String` döndüğünde dize sezgisine (`ERROR_PREFIXES`) fallback yapmak.

### 1.2. İki Noktada Kapsülleme İhlali (`instance_variable_get` / `instance_variable_set`)
- **Mevcut Durum:**
  1. [`InspectRuntimeTool`](file:///home/aristo/Projects/rubik/lib/rubik/tools/builtins/runtime.rb#L33-L34): `root_ctx.instance_variable_get(:@services)` ve `root_ctx.instance_variable_get(:@disposables)` çağrılarıyla `Context` iç alanlarına kaçak erişim yapmaktadır.
  2. [`ExecReplCommandTool`](file:///home/aristo/Projects/rubik/lib/rubik/tools/builtins/exec.rb#L170-L177): REPL komut çıktısını yakalamak için `@shell.instance_variable_get(:@output)` ve `@shell.instance_variable_set(:@output, captured_out)` kullanmaktadır.
- **Hedef:** 
  - `Rubik::Runtime::Context` sınıfına `services` (veya `@services.dup`) ve `disposable_count` public API'lerini eklemek.
  - `Rubik::REPL::Shell` sınıfına thread-safe `capture_output { ... }` veya `with_output(io) { ... }` blok API'si ekleyerek kaçak değişken manipülasyonunu tamamen kaldırmak.

### 1.3. `WriteFileTool` ve `GrepSearchTool` İçindeki Mükerrer / Karmaşık Rescue Blokları
- **Mevcut Durum:** `rescue Rubik::Buffer::InvalidPathError, StandardError => e` bloğunda `e.class.name.include?("InvalidPathError")` şeklinde gereksiz bir sınıf adı kontrolü yapılmakta; ayrıca bazı dosya araçlarında hem iç hem dış blokta `rescue Errno::EACCES` tekrarlanmaktadır.
- **Hedef:** Açık ve ayrık `rescue Rubik::Buffer::InvalidPathError` ve `rescue Errno::EACCES => e` bloklarına geçilerek kod temizliği ve okunabilirlik sağlanması, `files.rb` satır sayısının güvenle 300 sınırının altında tutulması.

### 1.4. `FinishTool` Risk Seviyesi Doğruluğu
- **Mevcut Durum:** `FinishTool` döngü sonlandırma sinyali olmasına rağmen `@risk = :read` olarak tanımlanmıştır.
- **Hedef:** Semantik olarak dürüst ve doğru olan `risk: :execute` seviyesine çekilmesi.

### 1.5. `Timeout.timeout(5)` Thread-Kill Semantiği ve Güvenlik Dokümantasyonu
- **Mevcut Durum:** `SynthesizeToolTool` pre-flight doğrulamasında kullanılan `Timeout.timeout(5)` klasik thread-kill kullanır; yerel C bloklarında thread askıda kalabilir.
- **Hedef:** Mimari koda açıklayıcı güvenlik yorumu ve sınır bilgisi eklenmesi.

---

## 🏛️ 2. Mimari Tasarım ve Çözüm Bileşenleri

```
                               ┌──────────────────────────────────────────────┐
                               │         Rubik Tool Layer Hardening           │
                               └──────────────────────┬───────────────────────┘
                                                      │
                       ┌──────────────────────────────┼──────────────────────────────┐
                       ▼                              ▼                              ▼
        ┌─────────────────────────────┐┌─────────────────────────────┐┌─────────────────────────────┐
        │ 1. Deterministic Status     ││ 2. Clean Encapsulation      ││ 3. Type-Safe Exception Flow │
        ├─────────────────────────────┤├─────────────────────────────┤├─────────────────────────────┤
        │ • Tools::Result / Failure   ││ • Context#services          ││ • Distinct rescue clauses   │
        │ • Explicit status priority  ││ • Context#disposable_count  ││ • Eliminate duplicate EACCES│
        │ • ERROR_PREFIXES constant   ││ • Shell#capture_output      ││ • FinishTool risk: :execute │
        │ • Backward-compatible string││ • Zero instance_variable_get││ • Timeout safety comment    │
        └─────────────────────────────┘└─────────────────────────────┘└─────────────────────────────┘
```

---

## ⚙️ 3. Planlanan İyileştirmeler ve Kod Değişiklikleri

### 3.1. `Rubik::Runtime::Context` Kapsülleme Güçlendirmesi
[`lib/rubik/runtime/context.rb`](file:///home/aristo/Projects/rubik/lib/rubik/runtime/context.rb)
- `services`: `@services.dup` döndüren salt-okunur hash erişimcisi.
- `service_names`: `@services.keys` listesi.
- `disposable_count`: Zaten mevcut olan metot netleştirilir.

### 3.2. `Rubik::REPL::Shell` Çıktı Yakalama API'si
[`lib/rubik/repl/shell.rb`](file:///home/aristo/Projects/rubik/lib/rubik/repl/shell.rb)
- `with_output(new_output)`:
  ```ruby
  def with_output(new_output)
    orig = @output
    @output = new_output
    yield
  ensure
    @output = orig
  end
  ```
- `capture_output(&block)`:
  ```ruby
  def capture_output(&block)
    io = StringIO.new
    with_output(io, &block)
    io.string
  end
  ```

### 3.3. Araçlardaki Kapsülleme İhlallerinin Giderilmesi
- [`lib/rubik/tools/builtins/runtime.rb`](file:///home/aristo/Projects/rubik/lib/rubik/tools/builtins/runtime.rb):
  `InspectRuntimeTool` içindeki `instance_variable_get` çağrıları yerine:
  ```ruby
  services = root_ctx.services
  lines << "\n[Services / Coeffects Active (#{services.size})]:"
  services.each { |k, v| lines << "  • #{k.to_s.ljust(12)} -> #{v.class}" }
  lines << "  (LIFO Accumulator Depth: #{root_ctx.disposable_count} inverse disposables)"
  ```
- [`lib/rubik/tools/builtins/exec.rb`](file:///home/aristo/Projects/rubik/lib/rubik/tools/builtins/exec.rb):
  `ExecReplCommandTool` içindeki `instance_variable_set` hilesi yerine:
  ```ruby
  output_str = @shell.capture_output { @shell.handle_input(cmd) }
  output_str.empty? ? "Command executed (no output)" : output_str
  ```

### 3.4. `Orchestrator::StepExecutor` Deterministik Hata Ayrıştırma
[`lib/rubik/orchestrator/step_executor.rb`](file:///home/aristo/Projects/rubik/lib/rubik/orchestrator/step_executor.rb)
- `ERROR_PREFIXES = [ ... ].freeze` sabiti tanımlanır.
- `raw_output` kontrolü:
  ```ruby
  is_err = if raw_output.is_a?(Rubik::Tools::Result)
             raw_output.error?
           elsif raw_output.respond_to?(:failed?) && raw_output.failed?
             true
           elsif raw_output.is_a?(String)
             ERROR_PREFIXES.any? { |pfx| raw_output.start_with?(pfx) }
           else
             false
           end
  ```
- Eğer `raw_output` bir `Tools::Result` ise, çıktısı ve statüsü doğrudan kullanılır.

### 3.5. Dosya Araçları Rescue Sadeleştirmesi & `FinishTool`
- [`lib/rubik/tools/builtins/files.rb`](file:///home/aristo/Projects/rubik/lib/rubik/tools/builtins/files.rb):
  `ReadFileTool`, `WriteFileTool`, `ReplaceFileContentTool` içindeki mükerrer `rescue Errno::EACCES` ve karmaşık `InvalidPathError` kontrolleri ayrık rescue dallarına dönüştürülür. Dosya satır sayısı azaltılır (< 280 satır).
- [`lib/rubik/tools/builtins/grep.rb`](file:///home/aristo/Projects/rubik/lib/rubik/tools/builtins/grep.rb):
  Aynı ayrık rescue deseni uygulanır.
- [`lib/rubik/tools/builtins/lifecycle.rb`](file:///home/aristo/Projects/rubik/lib/rubik/tools/builtins/lifecycle.rb):
  `FinishTool` `@risk = :execute` olarak güncellenir.
- [`lib/rubik/tools/builtins/synthesis.rb`](file:///home/aristo/Projects/rubik/lib/rubik/tools/builtins/synthesis.rb):
  Pre-flight timeout semantiği üzerine açıklayıcı mimari yorum eklenir.

---

## 🧪 4. Test ve Kalite Güvencesi

Yeni/Güncellenecek Testler:
1. `test/unit/test_tool_layer_hardening.rb`:
   - `Context#services` ve `Context#disposable_count` public API doğrulaması.
   - `Shell#capture_output` ve `Shell#with_output` güvenli geri yükleme (`ensure`) testi.
   - `StepExecutor`'ın hem `Tools::Result` hem `String` hem de `ERROR_PREFIXES` eşleşmelerini doğru statüye dönüştürdüğünün testi.
   - `FinishTool` risk seviyesinin `:execute` olduğunun teyidi.
2. `test/unit/test_module_hygiene.rb`:
   - Tüm 8 araç etki alanı dosyasının < 300 satır sınırında kaldığının doğrulanması.
3. Tam Test Süiti (`rake test`):
   - Tüm testlerin (770+ test) sıfır kırılma ile %100 yeşil kalması.

---

## 📋 5. Uygulama Adımları Özeti

1. **Adım 1:** `Context` ve `Shell` sınıflarına eksik public metotları ekle (`services`, `capture_output`).
2. **Adım 2:** `InspectRuntimeTool` ve `ExecReplCommandTool`'daki `instance_variable_*` çağrılarını temizle.
3. **Adım 3:** `StepExecutor` içindeki `is_err` mantığını `ERROR_PREFIXES` ve `Tools::Result` desteğiyle güçlendir.
4. **Adım 4:** `files.rb`, `grep.rb` rescue bloklarını sadeleştir, `FinishTool` risk seviyesini düzelt ve `synthesis.rb` yorumunu ekle.
5. **Adım 5:** Test süitini çalıştır ve doğrula.
