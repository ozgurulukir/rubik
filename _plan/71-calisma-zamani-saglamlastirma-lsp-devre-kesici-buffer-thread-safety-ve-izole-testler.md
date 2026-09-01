# Plan 71 — Çalışma Zamanı Sağlamlaştırma: LSP Devre Kesici, Buffer Thread-Safety, Sentez Guard Hardening ve İzole Runtime Testleri

> **Domain:** Runtime / LSP / Buffer / Security / Testing  
> **Kaynak:** Dış Kod İnceleme Geri Bildirimi (6 Maddelik Değerlendirme)  
> **Durum:** ✅ **Tamamlandı**  
> **Öncül Planlar:** [20](20-spatiotemporal-composability-eklenti-dongusu.md) · [29](29-lsp-derin-entegrasyonu-tanilama-ve-reaktif-geri-bildirim.md) · [03](03-dosya-tamponu-snapshot-undo.md) · [64](64-overlay-yukleme-butunluk-kapisi-ve-eval-guvenligi.md) · [69](69-kapsamli-dokumantasyon-mimarisi-domainler-araclar-ve-llm-oz-evrim-rehberi.md) · [70](70-write-file-garbage-path-korumasi.md)

---

## 1. İnceleme Maddeleri ve Haklılık Değerlendirmesi

| # | İnceleme Konusu | Haklılık Durumu | Gerekçe ve Yapılacak İşlem |
| :-: | :--- | :---: | :--- |
| **1** | **`Runtime::Context` ve `Runtime::Fiber` için izole birim test eksikliği** | ✅ **HAKLI** | `test_spatiotemporal_runtime.rb` ve invariant testleri entegrasyon odaklıdır. `Context` (`provide`, `require`, `has?`, `extend`, nested sub-contexts, coeffect eksikliği) ve `Fiber` (`activate!`, `deactivate!`, durum geçişleri, satisfy kontrolü) için doğrudan izole edilmiş `test_runtime_context.rb` ve `test_runtime_fiber.rb` testleri yazılmalıdır. |
| **2** | **`OverlayStorage` eval riski ve Guard desen kapsamı** | 🟡 **KISMEN HAKLI / HARDENING** | SHA-256 manifest ve `verify_integrity` kapısı mevcuttur (Plan 64); ancak `Security::Guard#verify_command_safety!` içindeki engelleme desenleri obfuscated meta-programlama (`send`, `public_send`, `binding.eval`, `Kernel.const_get`, `IO.popen`, tehlikeli kernel çağrıları) için daha da sıkılaştırılmalıdır. |
| **3** | **Tree-sitter yerine Prism & Regex Çıkarımı** | ℹ️ **MİMARİ TERCİH** | Rubik, Windows/POSIX üzerinde C derleyicisi (node-gyp/make/tree-sitter bindings) zorunluluğu olmadan saf Ruby ile sıfır-kurulum çalışabilmek için Ruby'de yerel **Prism** ve diğer dillerde regex heuristiği kullanır. Bu felsefe `ARCHITECTURE.md` içinde açıkça belgelenmeli, regex çıkarıcıların çok satırlı/jenerikli yapılar için dayanıklılığı artırılmalıdır. |
| **4** | **LSP sunucu çökme döngüsü (Crash Loop) / Devre Kesici eksikliği** | ✅ **HAKLI** | `lsp.auto_start: true` açıkken bozuk veya sürekli çöken bir dil sunucusu her dosya değişiminde/araç çağrısında yeniden başlatılmaya çalışılarak döngüye ve gecikmeye neden olabilir. **LSP Circuit Breaker** (art arda 3 çökmede 5 dakika devreyi açma ve `!lsp restart` ile manuel sıfırlama) eklenmelidir. |
| **5** | **`Buffer::Manager` thread safety açığı (`@dirty_files` concurrency)** | ✅ **HAKLI** | `AST::Graph`, `EventBus`, `LSP::Manager` Mutex kullanırken; `Buffer::Manager` eşzamanlı erişime karşı korunmasızdır. Arka plan indeksleme ve paralel fiberlerin tampona güvenle erişebilmesi için `Monitor` (re-entrant mutex) ile thread-safe hale getirilmelidir. |
| **6** | **`rubik.gemspec` eksikliği** | ❌ **HAKSIZ / MEVCUT** | `rubik.gemspec` kök dizinde mevcuttur ve geçerlidir. Ancak `gem build` doğrulaması bir test senaryosu ile test paketine dahil edilmelidir. |

---

## 2. Mimari ve Uygulama Fazları

### 🎯 Faz A: İzole Runtime Birim Testleri (`Context` & `Fiber`)
1. **`test/unit/test_runtime_context.rb`:**
   - `provide` ve `require` temel işlemleri (string ve sembol anahtarlar).
   - `has?` ve `satisfied?` kontrolleri.
   - `extend` ile hiyerarşik bağlam türetme ve yukarı doğru çözümleme (parent lookup).
   - Alt bağlamda override edilen servisin ebeveyne etki etmemesi.
   - Eksik coeffect durumunda `CoeffectMissingError` fırlatılması ve teşhis mesajı.
   - `on_dispose` / `register_disposable` LIFO ($\Omega$) ters işlem sıralaması ve hata izolasyonu.
2. **`test/unit/test_runtime_fiber.rb`:**
   - Durum makinesi geçişleri: `:pending` $\to$ `:active` $\to$ `:pending` $\to$ `:disposed`.
   - Coeffect'ler sağlandığında `activate!` ve factory çalıştırma.
   - Coeffect kaybedildiğinde `deactivate!` ve LIFO $\Omega$ unwinding.
   - Hata durumunda `:failed` durumu ve kısmi geri alma.

---

### 🛡️ Faz B: `Buffer::Manager` Re-entrant Thread-Safety
1. `lib/rubik/buffer/manager.rb`:
   - `require "monitor"` ekle.
   - `initialize` içinde `@monitor = Monitor.new` oluştur.
   - `read`, `write`, `clear`, `snapshot`, `apply!`, `dirty?`, `diff`, `all_files`, `add_root`, `remove_root` metotlarını `@monitor.synchronize` bloğu ile koru.
2. `test/unit/test_buffer_manager_concurrency.rb`:
   - Birden fazla iş parçacığının aynı anda tampona yazıp okuduğu eşzamanlılık stres testi ekle.

---

### ⚡ Faz C: LSP Crash Loop Devre Kesici (Circuit Breaker)
1. `lib/rubik/lsp/manager.rb`:
   - Çökme sayacı ve son çökme zamanı takibi (`@crash_stats[lang] = { count: N, last_crash_at: Time, state: :closed | :open }`).
   - `MAX_CRASHES = 3`, `COOLDOWN_PERIOD = 300` (5 dakika).
   - Eğer bir dil sunucusu eşik değeri aşarsa durumu `:open` yap, `auto_start` ve `ensure_healthy!` çağrılarını pas geç ve ajana/kullanıcıya devre kesici uyarısı ilet.
   - `reset_circuit!(lang)` metodu ile manuel sıfırlama (`!lsp restart`).
2. `test/unit/test_lsp_circuit_breaker.rb`:
   - Sürekli çöken sahte LSP istemcisiyle devre kesicinin tetiklendiğini ve döngünün engellendiğini doğrula.

---

### 🔒 Faz D: `Security::Guard` Sentezleme Deseni Güçlendirmesi
1. `lib/rubik/security/guard.rb`:
   - `DANGEROUS_SYNTHESIS_PATTERNS` kümesini genişlet:
     - Obfuscated eval (`send(:eval, ...)`, `public_send(:eval, ...)`, `binding.eval`)
     - Tehlikeli süreç çalıştırma (`IO.popen`, `Open3.capture*` vb. izole edilmemiş çağrılar)
     - Hassas namespace mutasyonu (`Object.const_set`, `Kernel.const_set`)
2. `test/unit/test_security_guard_synthesis.rb`:
   - Sentez koruma desenleri için kapsamlı kırmızı-takım saldırı senaryoları.

---

### 📚 Faz E: Mimari Dokümantasyon & Gemspec Doğrulaması
1. `ARCHITECTURE.md`:
   - Saf Ruby Sıfır-Native Bağımlılık felsefesi (Prism vs Tree-sitter C-bindings) bölümünü ekle.
2. `test/unit/test_gemspec_integrity.rb`:
   - `rubik.gemspec` dosyasının `Gem::Specification.load` ile hatasız yüklendiğini, tüm `spec.files` dosyalarının diskte var olduğunu ve `Rubik::VERSION` ile eşleştiğini doğrula.

---

## 3. Başarı Kriterleri

- [x] `test/unit/test_runtime_context.rb` (tüm provide/require/extend/LIFO senaryoları) 100% yeşil
- [x] `test/unit/test_runtime_fiber.rb` (tüm fiber yaşam döngüsü senaryoları) 100% yeşil
- [x] `Buffer::Manager` re-entrant `@monitor` ile eşzamanlı erişime tam güvenli hale getirildi
- [x] `LSP::Manager` Crash Circuit Breaker eklendi ve test edildi
- [x] `Security::Guard` tehlikeli meta-programlama kalıplarına karşı güçlendirildi
- [x] `rubik.gemspec` bütünlük testi eklendi
- [x] `ARCHITECTURE.md` güncellendi
- [x] `bundle exec rubocop` 0 offenses & `bundle exec rake test` 0 failures
