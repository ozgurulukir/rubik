# 📋 Plan 75: Reaktif Yapılandırma Gözlemcisi, Sistem Geneli Değişken/Knob Kablolaması ve Sıfır Kesintili Canlı Rekonfigürasyon (Reactive Config Observer, System-wide Knob Wiring & Zero-Downtime Live Reconfiguration)

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** Orta · **Faz:** 6 (Gelişmiş Ajan Ergonomisi, Çalışma Zamanı Sağlamlığı & Reaktivite)  
> **İlgili Planlar:** [01](01-proje-iskeleti-ve-konfigurasyon.md), [13](13-sandbox-izolasyon.md), [20](20-spatiotemporal-composability-eklenti-dongusu.md), [25](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md), [28](28-olay-gudumlu-reaktif-baglam-ast-ve-akilli-calisma-alani-agaci.md), [43](43-repl-bang-komut-standardizasyonu-ve-wiring-denetimi.md), [47](47-orchestrator-loopun-reaktif-sistem-fiberina-donusturulmesi.md), [48](48-harici-erisim-izinli-dizinler-ve-sifir-ast-sandbox-guvenlik-kapisi.md), [74](74-endustri-standardi-sse-stream-reasoning-ve-iletisim-hatti.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

`!config set llm.default_max_output_tokens 8192` ayarının oturum esnasında döngüye yansımaması üzerine yapılan derinlemesine kod tabanı denetiminde, Rubik'in yapılandırma (`Rubik::Config`) ve alt sistem iletişim katmanında **iki temel yapısal problem** tespit edilmiştir:

### 1.1. Mimari Boşluk: `Rubik::Config` İçinde Gözlemci / Olay Yayım Eksikliği
- **Mevcut Durum:** `Rubik::Config#set(key, val)` metodu yalnızca iç `@data` hash'ini günceller ve opsiyonel olarak diske yazar. Hiçbir dinleyiciye (listener), geri çağırmaya (callback) veya olay veri yoluna (`EventBus`) bildirimde bulunmaz.
- **Sonuç:** Yapılandırma reaktivitesi, tamamen REPL komutu olan [`lib/rubik/repl/commands/workspace.rb`](file:///home/aristo/Projects/rubik/lib/rubik/repl/commands/workspace.rb#L270-L308) içindeki ad-hoc ve kırılgan bir `if/elsif` dize kontrolü merdivenine hapsedilmiştir.
- **Kritik Zafiyet:**
  - Bir test, otonom ajan aracı (`RepairRuntimeTool`, `SynthesizeTool`) veya REPL dışı bir akış `config.set(...)` çağırdığında alt sistemlerin bundan haberi **kesinlikle olmaz**.
  - `workspace.rb` içindeki merdiven eksik kaldığında (örneğin `llm.`, `models.` veya `tools.` gibi), kullanıcı komutu çalıştırsa bile alt sistemler eski ayarlarıyla çalışmaya devam eder.

### 1.2. Değişken Kablolama Boşlukları (Dead & Shadowed Knobs)
[`lib/rubik/config/defaults.rb`](file:///home/aristo/Projects/rubik/lib/rubik/config/defaults.rb) içinde 12 ana alanda tanımlanan **43 konfigürasyon değişkeni** incelenmiş; bunlardan **7 tanesinin** kod tabanında ya tamamen ölü olduğu ya da hardcoded değerler tarafından gölgelendiği saptanmıştır:

1. **`context.include` & `context.exclude` (Kritik Boşluk):**
   - `Scanner` sınıfı `includes:` ve `excludes:` parametrelerini desteklemektedir; fakat [`Rubik::Context::Index#initialize`](file:///home/aristo/Projects/rubik/lib/rubik/context/index.rb#L11) bu parametreleri kabul etmez.
   - [`composition.rb:49`](file:///home/aristo/Projects/rubik/lib/rubik/repl/composition.rb#L49) `Index.new` çağırırken `context.include` ve `context.exclude` değerlerini **hiç aktarmaz**. Kullanıcı yapılandırmasında belirtilen özel hariç tutma / dahil etme kuralları tamamen yok sayılır.
2. **`tools.timeout_seconds` (Gölgelenmiş Değer):**
   - `DEFAULT_CONFIG["tools"]["timeout_seconds"] = 30` olarak tanımlıdır.
   - Ancak [`lib/rubik/tools/builtins/exec.rb:69`](file:///home/aristo/Projects/rubik/lib/rubik/tools/builtins/exec.rb#L69) satırında `timeout = (args["timeout"] || args[:timeout] || 15).to_i` ile `15` saniye hardcoded olarak sabitlenmiştir! Kullanıcı `!config set tools.timeout_seconds 60` yapsa bile araç 15 saniyede kesilir.
3. **`llm.capture_reasoning` (Kontrol Edilmeyen Düğme):**
   - `DEFAULT_CONFIG["llm"]["capture_reasoning"] = true` olarak tanımlıdır.
   - [`lib/rubik/orchestrator/stream_manager.rb:26`](file:///home/aristo/Projects/rubik/lib/rubik/orchestrator/stream_manager.rb#L26) akış sırasında reasoning chunk'larını bu ayarı hiç kontrol etmeden koşulsuz yayar; ayar `false` yapılsa bile akıl yürütme tokenları akmaya devam eder.
4. **`buffer.model_can_apply` (Uygulanmayan Güvenlik İzni):**
   - `DEFAULT_CONFIG["buffer"]["model_can_apply"] = true` olarak tanımlıdır.
   - Ancak [`ApplyBufferTool#execute`](file:///home/aristo/Projects/rubik/lib/rubik/tools/builtins/lifecycle.rb#L26) bu ayarı kontrol etmez. Kullanıcı `buffer.model_can_apply: false` yaparak modelin disk yazmasını engellemek istese bile araç çalışır.
5. **`sandbox.driver`, `sandbox.image`, `sandbox.wasm.runtime` (Statik Sürücü Kilidi):**
   - [`Rubik::Sandbox::Runner#initialize`](file:///home/aristo/Projects/rubik/lib/rubik/sandbox/runner.rb#L28) nesne oluşturulurken `@driver`'ı bir kez seçer ve dondurur.
   - Oturum sırasında kullanıcı `!config set sandbox.driver bubblewrap` veya `sandbox.image custom:v1` yaptığında runner eski sürücüyü kullanmaya devam eder; canlı sürücü yenileme mekanizması yoktur.
6. **`repair.max_attempts` (İlişkilendirilmemiş Bütçe):**
   - `DEFAULT_CONFIG["repair"]["max_attempts"] = 3` olarak tanımlıdır; ancak `Repair::Loop` bunu varsayılan argümandan alır, config nesnesine bağlı değildir.
7. **`buffer.exit_guard`:**
   - Tanımlıdır ancak `Shell#stop` çıkışta bu ayara bakmadan sabit uyarı basar; etkileşimli koruma politikasıyla senkron değildir.

---

## 🏛️ 2. Mimari Tasarım: Deklaratif Gözlemci & Reaktif Rekonfigürasyon

```
                           ┌─────────────────────────────────────────────────────────┐
                           │          Rubik::Config (Tek Hakikat Kaynağı)             │
                           └────────────────────────────┬────────────────────────────┘
                                                        │
                                                        │ config.set(key, value)
                                                        ▼
                           ┌─────────────────────────────────────────────────────────┐
                           │   Config Change Notification Engine (Observer / PubSub)  │
                           └──────────────┬───────────────────────────┬──────────────┘
                                          │                           │
                   prefix match           │                           │ emit(:config_changed)
                   (LIFO Inverses)        │                           │
                                          ▼                           ▼
                           ┌─────────────────────────────┐   ┌─────────────────────────────┐
                           │ Declarative Subsystem Hooks │   │   Rubik::EventBus (Global)  │
                           └──────────────┬──────────────┘   └─────────────────────────────┘
                                          │
        ┌───────────────────┬─────────────┴───────┬───────────────────┬───────────────────┐
        ▼                   ▼                     ▼                   ▼                   ▼
┌───────────────┐   ┌───────────────┐     ┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│ LLM / Router  │   │ Context/Index │     │ Buffer/Apply  │   │ Sandbox/Exec  │   │  UI / Theme   │
├───────────────┤   ├───────────────┤     ├───────────────┤   ├───────────────┤   ├───────────────┤
│ • Reload reg. │   │ • Inc/Excl sync│    │ • Model apply │   │ • Driver swap │   │ • Theme live  │
│ • Clear stamp │   │ • Re-scan root│     │ • Exit guard  │   │ • Timeout dyn │   │ • Statusline  │
│ • Token budget│   │ • AST re-warm │     │ • Reminder iv │   │ • External dir│   │ • Spinner     │
└───────────────┘   └───────────────┘     └───────────────┘   └───────────────┘   └───────────────┘
```

### Spatiotemporal Uyumluluk (`AGENTS.md`)
- **Locality of Disposal:** `config.on_change` metodu, dinleyiciyi kaldıran bir `Proc` (inverse) döndürür. Alt sistem veya eklenti sonlandığında (`on_dispose`) bu inverse çağrılarak bellek sızıntısı ve zombi dinleyiciler önlenir.
- **Zero-Downtime Reconfiguration:** REPL veya ana süreç yeniden başlatılmaksızın tüm alt sistemler yeni yapılandırmayı anında ve atomik olarak içselleştirir.

---

## ⚙️ 3. Uygulama Adımları

### 3.1. `Rubik::Config` Reaktif Gözlemci Altyapısı
[`lib/rubik/config.rb`](file:///home/aristo/Projects/rubik/lib/rubik/config.rb)
- `attr_accessor :event_bus` desteği.
- `on_change(prefix = nil, &block)` metodu:
  - Belirtilen anahtar ön-ekine (`"llm"`, `"sandbox"`, `"context"` vb.) veya tüm değişikliklere abone olur.
  - Dinleyiciyi geri kaldıran bir inverse `Proc` döner.
- `set(key, value, persist: nil)` metodu:
  - Değeri parse edip `@data`'ya yazdıktan sonra eski ve yeni değerleri karşılaştırır.
  - Değişiklik varsa ilgili tüm gözlemcileri `callback.call(key, new_val, old_val)` ile çalıştırır.
  - `@event_bus` tanımlıysa `@event_bus.emit(:config_changed, key: key, value: new_val, old_val: old_val)` yayınlar.

### 3.2. `Context::Index`, `Scanner` ve `composition.rb` Entegrasyonu
[`lib/rubik/context/index.rb`](file:///home/aristo/Projects/rubik/lib/rubik/context/index.rb), [`composition.rb`](file:///home/aristo/Projects/rubik/lib/rubik/repl/composition.rb)
- `Context::Index#initialize` içine `includes: []`, `excludes: []` parametreleri eklenir ve `Scanner.new`'a iletilir.
- `composition.rb` içinde:
  - `includes = Array(config.fetch("context.include", [])).compact`
  - `excludes = Array(config.fetch("context.exclude", [])).compact`
  - `Context::Index.new(..., includes: includes, excludes: excludes)` şeklinde geçirilir.
- `context.include` veya `context.exclude` değiştiğinde `context_index`'in tarayıcısının güncellenmesi ve yeniden tarama tetiklenmesi sağlanır.

### 3.3. `tools.timeout_seconds` ve `exec.rb` Düzeltmesi
[`lib/rubik/tools/builtins/exec.rb`](file:///home/aristo/Projects/rubik/lib/rubik/tools/builtins/exec.rb)
- `RunCommandTool#execute`:
  - `timeout = (args["timeout"] || args[:timeout] || @runner&.instance_variable_get(:@config)&.fetch("tools.timeout_seconds", 30) || 30).to_i`
  - Hardcoded 15 yerine yapılandırılabilir ve dinamik 30 saniye varsayılanı uygulanır.

### 3.4. `llm.capture_reasoning` Koruyucu Kapısı
[`lib/rubik/orchestrator/stream_manager.rb`](file:///home/aristo/Projects/rubik/lib/rubik/orchestrator/stream_manager.rb)
- Reasoning chunk yayınlama adımlarında (`execute_streaming_request`):
  `if @loop.safe_config("llm.capture_reasoning", true) != false && chunk.respond_to?(:reasoning_delta?) && chunk.reasoning_delta?` denetimi eklenir.

### 3.5. `buffer.model_can_apply` Güvenlik Kapısı
[`lib/rubik/tools/builtins/lifecycle.rb`](file:///home/aristo/Projects/rubik/lib/rubik/tools/builtins/lifecycle.rb)
- `ApplyBufferTool#execute`:
  - `if @shell&.config && @shell.config.fetch("buffer.model_can_apply", true) == false` ise model disk yazımı nazikçe engellenir: `"Model buffer application is disabled by configuration (buffer.model_can_apply: false). The human operator will review and apply changes."`

### 3.6. `Sandbox::Runner` Canlı Rekonfigürasyon (`reconfigure!`)
[`lib/rubik/sandbox/runner.rb`](file:///home/aristo/Projects/rubik/lib/rubik/sandbox/runner.rb)
- `reconfigure!` metodu eklenir:
  - `sandbox.driver`, `sandbox.image`, `sandbox.wasm.runtime` veya `sandbox.shell` değiştiğinde `@driver = Driver.best_available(...)` yeniden değerlendirilir.
  - `config.on_change("sandbox") { reconfigure! }` aboneliği bağlanır.

### 3.7. `REPL::Commands::Workspace` Ad-Hoc Merdiveninin Temizlenmesi
[`lib/rubik/repl/commands/workspace.rb`](file:///home/aristo/Projects/rubik/lib/rubik/repl/commands/workspace.rb)
- `!config set` içindeki karmaşık `if/elsif` dalları yerini doğrudan `config.set`'e bırakır; abonelikler `Shell#initialize` veya alt sistemlerin kendi yaşam döngülerinde deklaratif olarak bağlanır.

---

## 🧪 4. Doğrulama ve Test Stratejisi

1. **`test/unit/test_config_reactivity_and_knob_wiring.rb`:**
   - `Config#on_change` ve `event_bus` yayım testleri.
   - `context.include` ve `context.exclude`'un `Scanner`'a doğru aktarılması ve dosya indeksleme testi.
   - `tools.timeout_seconds` ayarının `exec` aracına yansıması testi.
   - `llm.capture_reasoning: false` iken thought delta yayılmaması testi.
   - `buffer.model_can_apply: false` iken `apply_buffer` aracının engelleme testi.
   - `sandbox.driver` değişiminde `Runner#reconfigure!` testi.
2. **Genel Süit:**
   - Tüm 1,173 testin %100 yeşil kalması.
   - RuboCop 0 uyarı garantisi.
   - `loop.rb` (<= 350 satır) ve `shell.rb` (<= 620 satır) limitlerinin korunması.

---

## 📋 5. Risk ve Etki Değerlendirmesi

- **Risk Seviyesi:** Düşük - Orta (Tüm değişiklikler mevcut varsayılanlarla geriye dönük tam uyumludur).
- **Blast Radius:** Yapılandırma okuyan alt sistemler güçlenir; hiçbir mevcut API veya komut sözleşmesi bozulmaz.
