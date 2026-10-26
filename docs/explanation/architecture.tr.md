# 🏛️ Rubik Sistem Mimarisi (System Architecture)

> Bu belge, [Architecture](architecture.md) dosyasının Türkçe çevirisidir ve güncelliğini yitirmiş olabilir; çelişki halinde İngilizce sürüm esastır.

> **Protokol:** [`AGENTS.md`](../../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes
> **İlgili Kılavuzlar:** [`TOOLS.md`](../../TOOLS.md) · [Self-evolution guide](self-evolution.md) · [Plugin guide](../how-to/plugins.md) · [REPL command reference](../reference/commands.md) · [Configuration guide](../how-to/configuration.md)

---

## 📖 1. Sistem Genel Bakışı ve Tasarım Felsefesi

Rubik, saf Ruby (3.4+) ile yazılmış, **Spatiotemporal Composability & Self-Evolving Runtime** mimarisi üzerine kurulu modüler bir otonom kodlama harness'ıdır.

### Temel Mimari İlkeler:
1. **Spatiotemporal Composability (Revertible Effects & Reactive Coeffects):** Sistemdeki her işlem bir uzay-zaman bağlamında izole edilir; her yan etki LIFO ($\Omega$) ters işlem kaydıyla atomik olarak geri alınabilir.
2. **In-Memory Virtual Buffer First:** Model kod yazdığında dosyalar doğrudan diske yazılmaz; sanal tamponda hazırlanır. Sıfır riskli manipülasyon, snapshot geçmişi ve anında geri alma (`!undo`) sunar.
3. **Pure-Ruby Cross-Platform Core:** POSIX (Linux, macOS) ve Windows 11 ortamlarında harici native bağımlılık olmadan sorunsuz çalışır.

---

## 🧩 2. 31 Çekirdek Domain Sözlüğü ve Sorumluluk Matrisi

Rubik'in `lib/rubik/` dizini altındaki 27 bağımsız alt sistemi ve kendi dizini olmayan dört üst-seviye modül (`event_bus`, `coeffects`, `log`, `uris`):

| # | Domain | Modül / Sınıf | Sorumluluk & Görev |
| :--- | :--- | :--- | :--- |
| 1 | **`adapter`** | `Rubik::Adapter` | Çok dilli test, lint ve format çalıştırma adaptörleri (Ruby, Python, Go, Rust, TS vb.). |
| 2 | **`ast`** | `Rubik::AST` | Prism (Ruby) ve Tree-Sitter (12 kaynak uzantısı üzerine 9 gramer) hibrit motoru, semantik sembol ve çağrı grafı (`Graph`), kalıcı JSON disk önbelleği. |
| 3 | **`benchmark`**| `Rubik::Benchmark` | Ajan performans ve kabul kıyaslama test çatısı. |
| 4 | **`buffer`** | `Rubik::Buffer` | Bellek içi sanal tampon (`Manager`), snapshot geçmişi, LIFO undo ve diff motoru. |
| 5 | **`cli`** | `Rubik::CLI` | CLI çalışma-alanı güven kapısı (`WorkspaceTrust`): bir çalışma alanı ilk yüklendiğinde etkileşimli güven istemi gösterir, kabul edilen listeyi `~/.rubik/trusted_workspaces.yml` dosyasına yazar. |
| 6 | **`coeffects`** | `Rubik::Coeffects` | Kanonik çalışma-zamanı bağlam koefekt anahtarları (servis anahtar adlarının tek doğruluk kaynağı — `DMESG`, `INIT` vb.) ve varlık-denetimli `Coeffects.get` erişicisi. |
| 7 | **`concurrency`** | `Rubik::Concurrency` | Sessiz eşzamanlılık: saf-stdlib Ruby Fiber Scheduler olay döngüsü (`EventLoop` + `Scheduler`) ve `silently`/`map` sınır API'si — mevcut bloklayan I/O çağrı noktalarını (Net::HTTP, sleep, Open3 boru okuma/yazma, Mutex/CV/Thread#join) DEĞİŞTİRMEDEN tek iş parçacığında işbirlikçi şekilde eşzamanlı çalıştırır (binlerce eşzamanlı I/O; GVL nedeniyle CPU paralelliği değil). Kill-switch: `RUBIK_FIBER_SCHEDULER=off`. |
| 8 | **`config`** | `Rubik::Config` | Katmanlı YAML yapılandırma (defaults, deep ops, store, schema validation). |
| 9 | **`context`** | `Rubik::Context` | Kod haritası (`Index`), çalışma-alanı taraması (`Scanner`) ve git üst-verisi (`GitInfo`). |
| 10 | **`diagnostics`**| `Rubik::Diagnostics` | Elm-tarzı hata formatlayıcı, `ExecutionFailure` sınıflandırması ve geri bildirim. |
| 11 | **`event_bus`**| `Rubik::EventBus` | `Rubik::Kernel::Dispatcher` üzerinde geriye dönük uyumlu olay cephesi (`Pub/Sub`). |
| 12 | **`kernel`** | `Rubik::Kernel` | Çekirdek telemetri halkası (`Dmesg`), deterministik olay dağıtıcısı (`Dispatcher`), kök süpervizör (`Init` - PID 1), birleşik yürütme birimleri (`Unit`, `ProcessUnit`, `SubagentUnit`), `Record`, kworker kuyruğu, mikro-çekirdek çalışma omurgası. |
| 13 | **`llm`** | `Rubik::LLM` | Sağlayıcı soyutlamaları (Anthropic, OpenAI, OpenAI-uyumlu, Ollama), model yönlendirici (`Router`), sağlayıcı `Registry` ve paylaşılan `Client` (streaming, chunk birleştirme, mesaj temizleme, bağlantı havuzu). |
| 14 | **`log`** | `Rubik::Log` | Merkezi seviyeli loglama çekirdeği — çalışma zamanı teşhisleri için tek kaynak; ad-hoc `Kernel#warn` çağrı noktalarının yerine geçer. |
| 15 | **`lsp`** | `Rubik::LSP` | Dil sunucusu yöneticisi, RFC 8089 URI desteği, bellek içi canlı tanı. |
| 16 | **`mcp`** | `Rubik::MCP` | Model Context Protocol istemcisi: stdio transport, çoklu sunucu yöneticisi (`Manager`, örtüşen boot fan-out ile paralel başlatma), keşfedilen araçların `BaseTool` proxy katılımı (`ProxyTool`), LIFO ile sıfır-artık süreç sökülüşü. |
| 17 | **`orchestrator`**| `Rubik::Orchestrator`| Ajan döngüsü (`Loop`; subagent bildirim kuyruğu `SubagentNoticeInbox` işbirlikçisinde — doğrulama, race-safe drenaj ve run/continue yaşam döngüsü), `ShellDeps` (daraltıcı façade), `StepExecutor`, `BudgetManager`, `StreamManager`, `ProviderResolver`, `ActivityLog`, `ToolCallId` (tool-call kimlik damgasının tek evi), `Subagent::Supervisor` (Linux init'in PID-1 süpervizör ROLÜNÜ modelleyen süreç tablosu; adlandırma sözleşmesi — makine düzlemi `agent-0`: parent_id/sender ve kalıcı spec'ler, persona düzlemi `maestro`: model'e görünen metinler; 2026-10-03'te `init-0`dan yeniden adlandırıldı — eski ad Unix `init 0` = halt ve PID-1 `init` eğitim öncelleriyle çakışıyordu; `init-0` artık yalnız kabul edilen bir girdi alias'ı; üç katmanlı ayrım: `Kernel::Init` çalışma zamanının gerçek PID 1'i, `Subagent::Supervisor` subagent süreç tablosu makineleri, `maestro` onları süren persona), `Subagent::Instance`, `Subagent::StepRunner`, `Subagent::TypeRegistry`, `Subagent::Notices` (bildirim sözlüğünün tek evi: kullanıcı/model kanal ayrımı), `Subagent::Budget` (adım bütçesi durum makinesi + grant normalizasyonu ve grant-notu sözlüğü — subagent-döngü hedef kitle sınırı; `BudgetManager`'ın sahipli varyantı, stateless-over-owner doktriniyle ayrı kalırlar). Kalan her işbirlikçinin de tek evi vardır: `TurnExecutor` (paylaşılan tur omurgası — yanıt ayrıştırma, araç/finish-adım yürütümü, `Channel`/`NudgePolicy` politika adaptörleri — hem `Loop` hem `Subagent::StepRunner`'a hizmet eder), `ToolHistory` (kanonik araç-sonuç geçmiş satırı), `ToolCircuitBreaker` (araç başına opt-in ardışık-başarısızlık izolasyonu), `ProviderRecovery` (sağlayıcı-çağrısı kurtarma politikasının tek evi), `ContinuationManager` (`max_output_tokens` ile kesilen yanıtlarda otomatik devam), `FinishMessageSelector` (kullanıcıya gösterilen son mesajın seçimi), `LspFeedback` (canlı LSP tampon-tanı geri beslemesi), `MaestroGate` (`maestro`-persona ajanlar için yazma/çalıştırma araçlarını engelleyen persona-düzlemi kapısı), `GoalState`/`GoalWait` (goal-döngüsü yaşam döngüsü; örtük bekleme ve erken-tamamlanma koruması), `GoalLedger` (yapılandırılmış goal-döngüsü ΔΣ defteri, 2026-10-10: `Patch`/`Schema`/`Validator` saf yama dikişi, depolama revizyonları ve sıkıştırma sabitleme/yeniden-enjeksiyonlu durumlu `Ledger`, `Verifier`/`VerifySpec` tri-durumlu FS yeniden-doğrulaması, `DriftNote` ve `ObservationProjection` — `goal.ledger.*` ile varsayılan AÇIK) ve `AutoApply` (`buffer.auto_apply` politika sahibi). |
| 18 | **`platform`** | `Rubik::Platform` | Çapraz platform yardımcıları (`PATHEXT`, `which`, `kill_tree`, `path_under?`). |
| 19 | **`plugin`** | `Rubik::Plugin` | Drop-in eklenti depolama (`Storage`), `Rubik.plugin` DSL'i ve `$LOAD_PATH` refcount. |
| 20 | **`prompt`** | `Rubik::Prompt` | Sistem istemi oluşturucular (`ContextBuilder`), `<operational_rules>` (Kural 1-8 High-SNR), dinamik XML etiketleri (`<subagents>`, `<workspace_status>`, `<buffer_status>`), token tahmini (`TokenEstimator`) ve konuşma compaction'ı (`ContextCompactor`/`EmergencyCompactor`). |
| 21 | **`repair`** | `Rubik::Repair` | Kendi kendini onaran çalışma zamanı döngüleri ve teşhis tabanlı düzeltme. |
| 22 | **`repl`** | `Rubik::REPL` | Etkileşimli kabuk (`Shell`), 14 domain komut modülü (`system`, `buffer`, `session`, `workspace`, `lsp`, `agent`, `plugins`, `mcp`, `skills`, `tasks`, `subagents`, `storage`, `pruner`, `dmesg`), sunum katmanı, yarı deterministik KÖK pencere budayıcısına ev sahipliği yapar (`repl/pruner/`, `subagents.pruner.*` ile varsayılan AÇIK), `ServiceCatalog` (hizmet tanım kataloğu: yeni servis = Coeffects anahtarı + tek katalog girdisi; Parts üyeleri, ivar'lar, reader'lar ve provide satırları girdiden türetilir). |
| 23 | **`runtime`** | `Rubik::Runtime` | Spatiotemporal `Context`, `Fiber` (`ComponentFiber`) durum makinesi, LIFO $\Omega$ akümülatörü, topolojik fiber mutabakatı (`topological_sort_fibers`), saf bağlam kapanışı (headless teardown), `OverlayStorage`, `TaskManager` (`RingBuffer` & asenkron süreçler), `ServiceDefinition` (hizmet bildirimi value-object sözlüğü), `ServiceRegistration` (4 register-shim'in ortak omurgası: ctx çıkarma → provide → inverse → reconcile). |
| 24 | **`sandbox`** | `Rubik::Sandbox` | Safe Execution (her zaman aktif), tak-çıkar OS sandbox (yerleşik sürücüler `bubblewrap`, `docker`, `podman` ve sade `process` sürücüsü; docker→podman erişilebilirlik fallback'i) ve eklentilerin çalışma zamanında genişlettiği dinamik kayıt defteri (`Driver.register`) — örn. bir firejail sürücüsü (bkz. AGENTS.md §4.D). |
| 25 | **`security`** | `Rubik::Security` | Güvenlik muhafızı (`Guard`), Tree-Sitter AST komut sınıflandırıcı (175 CLI YAML, Bash/Pwsh), boru hattı zehirleme ve kritik yol engelleri. |
| 26 | **`session`** | `Rubik::Session` | Oturum kaydedici (`Recorder`), `Replayer`/`Manager`, JSONL loglama ve `rubik -c` devamlılığı. |
| 27 | **`skills`** | `Rubik::Skills` | Agent Skills altyapısı (agentskills.io): `SKILL.md` keşfi ve ön-yüz doğrulaması (`Frontmatter`, `Validator`), proje/kullanıcı kapsamlı kayıt defteri (`Registry`), gölgeleme raporlaması, `skill_manager` koefekt yaşam döngüsü (`Manager`). |
| 28 | **`storage`** | `Rubik::Storage` | `rubik://storage` dosya-sistemi veritabanı (`Store`, tip.satır.hash16 kimlikleri), URI okuma/yazma yönlendiricisi (`UriReader`, `Render`), transkript otomatik indeksleyici ve Vakanüvis kronikçisinin deterministik düzlemi (`vakanuvis/`: `Harness`, `AnnalWriter`, `MemorySteward`, `WikiSkeleton`, `DistillGate`, `Vocabulary` (ref-grameri ve etiket/durum sözlüğü SSOT'u); LLM damıtıcısı `Subagent::TypeRegistry`'deki `vakanuvis` tipiyle doğar). |
| 29 | **`tools`** | `Rubik::Tools` | 35 yerleşik araç (+ dinamik `skill` proxy'si), araç kayıt defteri (`Registry`), Elm-tarzı yönlendirici hata formatı, `Services` (araç katmanı triple-chain çözümleme görünümü: kwarg → coeffect → fresh; standalone kurulum fail-closed kalır). |
| 30 | **`ui`** | `Rubik::UI` | TUI katmanı, canlı spinner, statusline, diff renklendirici, markdown renderer. |
| 31 | **`uris`** | `Rubik::Uris` | `rubik://` sanal URI gramerinin ve üç şemasının (`storage` = FS-DB, `goal`, `subagent`) tek evi; araçlar `UriResolver` dispatch kaynağı tarafından tüketilir. |

---

## 🏗️ 3. Sistem Montaj Hattı (`Composition.build`) ve Veri Akışı

Rubik, tüm bu alt sistemleri `Composition.build` montaj katmanında deterministik sırada ayağa kaldırır:

```mermaid
flowchart TD
    User([Kullanıcı / Terminal]) -->|Girdi| Shell[Rubik::REPL::Shell]
    Shell -->|İnşa & Bağlama| Comp[Rubik::REPL::Composition.build]
    Comp --> RM[Rubik::Runtime::Manager<br/>Coeffects & Fibers]

    Shell -->|Görev| Loop[Rubik::Orchestrator::Loop]
    Loop -->|Prompt| LLM[Rubik::LLM::Router / Provider]
    LLM -->|Tool Call| StepExec[Rubik::Orchestrator::StepExecutor]

    StepExec --> Tools[Rubik::Tools::Registry<br/>35 Built-in + Skill Proxy + Custom Tools]
    Tools -->|Dosya İşlemleri| Buffer[Rubik::Buffer::Manager]
    Tools -->|Sözdizim/Tip Kontrolü| LSP[Rubik::LSP::Manager]
    Tools -->|Kabuk/Test Yürütümü| Sandbox[Rubik::Sandbox::Runner]
    Tools -->|Öz-Evrim| Overlay[Rubik::Runtime::OverlayStorage]

    Buffer -->|Canlı Geri Bildirim| UI[Rubik::UI::Renderer & Statusline]
    LSP -->|Teşhis Bildirimi| Loop
    StepExec -->|Adım Çıktısı| UI
    UI -->|Render| User
```

---

## 🛡️ 4. Tasarım Değişmezleri (Invariants)

1. **Tampon Güvencesi (Buffer Invariant):** Model tarafından yapılan tüm kod değişiklikleri diske doğrudan yazılmaz; `Buffer::Manager` sanal katmanında tutulur ve yalnızca `apply_buffer` (`!apply`) işlemiyle diske aktarılır.
2. **LIFO Ters İşlem Garantisi ($\Omega$):** Çalışma zamanında üretilen her araç (`synthesize_tool`), adaptör (`Adapter::Registry`) veya servis kaydı (`ctx.provide`), yaşam döngüsü bittiğinde ters sırayla temizlenir.
3. **Çoklu Platform Saydamlığı:** Dosya yolları, işlem sonlandırma ağaçları (`kill_tree`) ve kabuk çağrıları platforma göre şeffaf bir şekilde yönetilir.
4. **Falsy-Safe Coeffect Semantiği:** `false` koefekt değerleri meşru bağımlılık girdileridir (`sandbox: false`, `dry_run: false`). `Context#require`, `Context#get` ve `Coeffects.get` varlık denetimini `nil?` üzerinden yürütür.
5. **Konteyner ve Süreç İzolasyon Bütünlüğü:** Docker sandbox sürücüsü ana makineyi en az yetki (`--read-only`, `--cap-drop ALL`, `--security-opt no-new-privileges`) ile korur; timeout anında konteyner (`docker rm -f`) ve süreç ağacı (`kill_tree`) deterministik olarak temizlenir.

---

## 💎 5. Saf Ruby & Sıfır-Native Bağımlılık Mimarisi

Rubik, Windows, macOS ve Linux sistemlerinde **harici C derleyicisi (GCC, Clang, MSVC) veya C-extension derleme adımı gerektirmeden** sıfır-kurulum çalışacak şekilde tasarlanmıştır:
- **Ruby AST:** Ruby 3.4+ (proje tabanı) ile yerleşik gelen resmi **Prism** ayrıştırıcısını kullanır; harici native gem bağımlılığı yoktur.
- **Çok Dilli Tree-Sitter AST & Hibrit Semantik Motoru:** Python, Go, Rust, TypeScript, TSX, JavaScript/JSX, C, C++ ve Zig dillerinde (12 kaynak uzantısı üzerine 9 tree-sitter grameri) `tree_sitter_language_pack` ile derlenmiş C/Rust çekirdekli gramerler üzerinden tam sözdizim ağacı ayrıştırması yapar; yorum/string içi süslü parantez tuzaklarına ve modern dil kalıplarına karşı dayanıklıdır. Ağ veya kütüphane erişilemezliği durumunda sessizce eski regex çıkarıcılara (`FallbackCleaner`) geri çekilen fail-safe graceful fallback mimarisiyle çalışır. Ortak C/C++ walker'ı include'ları, typedef'leri, struct/union/class belirteçlerini (iç içe tipler `Outer::Inner` olarak nitelenir), sınıf içi üye tanım ve bildirimlerini (`Class#method`), namespace'leri (`app::Widget#run`), sınıf dışı tanımları, constructor/destructor/operator'leri ve şablonları (template_declaration açılarak) kapsar; makro gövdeleri ve sınıf dışı serbest fonksiyon prototipleri kapsam dışıdır. Her çıkarım yapılandırılmış bir durum döndürür (`Extractor.extract_result`: `:ok` / `:partial` / `:failed` / `:unavailable` + kaynak), böylece çöken bir ayrıştırma boş bir dosyayla asla karıştırılmaz — ve başarısız bir yeniden indeksleme, dosyanın önceki sembollerini sessizce silmek yerine (bir log satırıyla) korur.
- **Dil Sunucusu Desteği (LSP):** İleri düzey tip ve semantik analiz için harici native derleme yerine sistemde kurulu standart dil sunucularına (`gopls`, `rust-analyzer`, `solargraph`, `pyright` vb.) RFC 8089 uyumlu JSON-RPC ile bağlanır.
- **Güvenli Komut AST (Safe Execution):** Bash ve PowerShell komutlarını çalıştırmadan önce `tree_sitter` gem'i ve derlenmiş gramerlerle AST düzeyinde çözümler; 175 CLI aracı için yapılandırılmış kurallarla boru hattı zehirlemesi, kök dizin yazımı ve tehlikeli bayrakları yakalar; başarısızlık durumunda fail-safe regex fallback devreye girer.

---

## 🔒 6. Eşzamanlılık (Thread-Safety) ve Devre Kesici (Circuit Breaker)

- **Re-entrant Buffer Senkronizasyonu:** `Buffer::Manager`, eşzamanlı arka plan AST indeksleme ve çoklu fiber erişimlerine karşı `Monitor` ile korunur.
- **Kernel Ring Buffer Eşzamanlılığı:** `Rubik::Kernel::Dmesg`, çoklu arka plan iş parçacıkları (kworker, alt ajanlar, LLM stream'leri) ve okuyucu fiberler arasında `Monitor` ile thread-safe çalışır.
- **Kernel Init & Unit Eşzamanlılığı:** `Rubik::Kernel::Init` ve `Rubik::Kernel::Unit`, birimlerin durum geçişleri ve LIFO kapanışında `Monitor` ile korunur.
- **Topolojik Fiber ve Bağlam Eşzamanlılığı:** `Rubik::Runtime::Manager` ve `Rubik::Runtime::Context`, re-entrant `Monitor` ile çoklu iş parçacıklarında güvenli mutabakat (`reconcile_all`), kilitlenmesiz topolojik sıralama ve sinyal-güvenli (Interrupt/SystemExit) LIFO kapanışı sağlar.
- **TerminalGuard ve Reline Ekran Koruması:** `Rubik::REPL::TerminalGuard`, asenkron kworker ve arka plan birim bildirimleri konsola basılırken kullanıcının o an yazmakta olduğu Reline satırını `Monitor`, ANSI satır temizleme (`\r\e[2K`) ve `Reline.redisplay` ile thread-safe korur.
- **Sessiz Eşzamanlılık Sınırı (`Rubik::Concurrency.silently`/`.map`):** Fiber Scheduler tabanlı olay döngüsü üzerinde, bloklayan görünümlü I/O kodu çağrı noktasında hiçbir sözdizimi değişikliği olmadan eşzamanlı çalışır. Sadece I/O eşzamanlılığıdır (CPU işi GVL'de seri kalır); regular-file okuma park etmez (zararsız şekilde seri çalışır); sınırlar `lib/rubik/concurrency.rb` başlığında belgelenmiştir. Drain-sonrası-yükselt hata politikası: gövde hatası kazanır, aksi halde en düşük doğum-sırası fiber hatası yükseltilir, kardeşler loglanır (asla yutulmaz). Zamanlayıcı kurulumu geri-alınabilirdir (ensure içinde `Fiber.set_scheduler(nil)`).

---

## 📡 7. Çekirdek Telemetri ve Olay Mimarisi (`Rubik::Kernel`)

### 7.1 Çekirdek Telemetri ve Olay Halkası (`Rubik::Kernel::Dmesg`)

Sistem çapındaki asenkron olaylar, subagent bildirimleri, HTTP/LLM hataları ve mikro-çekirdek teşhisleri merkezi `Rubik::Kernel::Dmesg` halkasında toplanır:
- **Monotonik Süreklilik:** Kesinlikle artan 64-bit sıra numarası (`seq`) ve `Process::CLOCK_MONOTONIC` tabanlı süreç saati (`uptime`). Duvar saati (NTP) kaymalarından etkilenmez.
- **Sıfır Bellek Sızıntısı (Bounded Memory):** Sabit 2048 kayıtlık önceden tahsis edilmiş dairesel dizi (`Array.new(capacity)`). Eski kayıtların üzerine $\mathcal{O}(1)$ zaman karmaşıklığıyla yazılır, bellek ayak izi oturum boyunca sabit kalır.
- **Eşzamanlılık Koruması:** `Monitor` tabanlı re-entrant thread-safety ile çoklu fiber ve arka plan iş parçacıklarının eşzamanlı `log` ve `tail` çağrıları tam güvenceye alınır.
- **Coeffects & Araç Entegrasyonu:** `Rubik::Coeffects::DMESG` üzerinden `Runtime::Context`'e enjekte edilir (`ctx.provide(:dmesg, dmesg)`, `ctx.require(:dmesg)`). REPL üzerinde `!dmesg` operatör komutu ve LLM için `:read` riskli `dmesg` yerleşik aracıyla tam çift-yönlü erişilebilirlik sunar.

### 7.2 Deterministik Olay Dağıtıcısı ve Kworker Kuyruğu (`Rubik::Kernel::Dispatcher`)

`Rubik::Kernel::Dispatcher`, mikro-çekirdek mimarisinde asenkron olayların deterministik dağıtımını sağlayan FIFO iş parçacığıdır:
- **Kworker Arka Plan Kuyruğu:** Olaylar `Thread::Queue` kuyruğuna alınır ve adanmış `rubik-kworker` daemon iş parçacığı (`process_queue`) tarafından tek hat üzerinde tüketilir.
- **Non-blocking Olay Gönderimi:** `post(event_name, payload, ...)` çağrısı $\mathcal{O}(1)$ sürede döner; çağıran iş parçacığı veya REPL döngüsü asla bloklanmaz.
- **Deterministik Tek Hat (FIFO) Dağıtımı:** Olaylar yayınlandığı sırada sıralanır. Eşzamanlı üreticilerin gönderdiği olaylar kworker hattında deterministik biçimde abonelere iletilir.
- **Dmesg Otomatik Telemetrisi:** Dağıtılan her olay eşzamanlı olarak Dmesg halkasına `event:<event_name>` mesajıyla, alt sistem, önem düzeyi ve ek veri öznitelikleriyle birlikte otomatik işlenir.
- **Abone Hata İzolasyonu (Fault Isolation):** Bir abonenin fırlattığı istisna (`StandardError`) yakalanır, Dmesg ve log sistemine hata olarak kaydedilir. Worker iş parçacığı çökmez ve diğer aboneler ile sonraki olaylar kesintisiz işlenmeye devam eder.
- **LIFO Yaşam Döngüsü ve Temizlik:** `sync_drain(timeout)` mekanizması ile kuyruktaki olayların tükenmesi senkronize edilir. `subscribe(event, context: ctx)` çağrısı `context.on_dispose` ile otomatik unsubscription kaydeder; `ServiceCatalog` ise `runtime_manager.context.on_dispose { dispatcher.stop }` ile oturum kapanışında LIFO kurallarına uygun temizlik sağlar.
- **EventBus Geriye Uyumluluk Köprüsü:** `Rubik::EventBus`, `Dispatcher` üzerinde ince bir cephe (facade) olarak yapılandırılmıştır. `emit` metodu `post` + `sync_drain` çağrısıyla eski senkron beklentileri %100 korur.

### 7.3 Birleşik Çekirdek Yürütme Birimleri (`Rubik::Kernel::Unit`)

Arka plan komutları (`TaskManager::Task`), özerk alt ajanlar (`Subagent::Instance`) ve çekirdek servislerinin durum ve kaynak yönetimi `Rubik::Kernel::Unit` temel sınıfı altında birleştirilmiştir:
- **Deterministik Durum Çizgesi:** Birimler 8 durumlu (`:pending`, `:active`, `:paused_error`, `:waiting_budget`, `:budget_exhausted`, `:completed`, `:failed`, `:reaped`) sonlu durum makinesi (FSM) ile yönetilir. Durum geçişleri `transition_to!` üzerinden atomik (`Monitor`) olarak gerçekleşir.
- **Terminal Durum İzolasyonu:** `:reaped` durumuna ulaşan bir birim asla başka bir duruma geçemez; `:completed` ve `:failed` durumundaki birimler yalnızca çöp toplama (reap) adımıyla `:reaped` olabilir.
- **Otomatik Kernel Telemetrisi:** Her durum geçişinde Dmesg halkasına `unit:<id> state transition <from> -> <to>` teşhis kaydı düşülür ve Dispatcher kuyruğuna `:unit_state_changed` asenkron olayı postalanır.
- **Alt Sınıf Sarmalayıcıları:**
  - `Rubik::Kernel::ProcessUnit`: `TaskManager` görevlerini sarmalar; durdurma (`kill`) ve durum senkronizasyonunu (`sync_state!`) arka plan OS süreçleriyle köprüler.
  - `Rubik::Kernel::SubagentUnit`: `Subagent::Instance` yürütücülerini sarmalar; bütçe/hata durumunda duraklatma (`paused_error`, `waiting_budget`, `budget_exhausted`) ve sürdürme (`resume`) döngülerini yönetir.

### 7.4 Kök Süpervizör Yaşam Döngüsü ve Zombi Süreç Temizliği (`Rubik::Kernel::Init` - PID 1)

`Rubik::Kernel::Init`, işletim sistemlerindeki PID 1 `init`/`systemd` sürecine benzer biçimde Rubik çalışma zamanının en üst yaşam döngüsü süpervizörüdür:
- **Tek Doğruluk Kaynağı (SSOT):** Çalışma zamanındaki tüm süreçler (`ProcessUnit`) ve alt ajanlar (`SubagentUnit`), başlatıldıkları anda `Init` süpervizörüne kaydedilir (`register`).
- **LIFO Kapanış Garantisi (AGENTS.md §1.A/B):** Oturum sonlandığında veya `kill_all` / `stop` çağrıldığında, birimler kayıt sıralarının tam tersi kronolojik sırada (LIFO - Last In First Out) sonlandırılır. Üst birimler alt birimlerden önce kapanmaz; böylece kaynak sızıntısı ve yarım kalmış arka plan işlemleri engellenir.
- **Zombi Süreç Temizliği (`reap_dead_units!`):** Terminal duruma (`:completed`, `:failed`) geçmiş birimlerin tahsis edilmiş disposable alt-bağlamları (`ctx.extend`) güvenli bir şekilde imha edilir (`safely_dispose_context`) ve birim `:reaped` durumuna geçirilir.
- **Bağlam ve Coeffect Entegrasyonu:** `Rubik::Coeffects::INIT` anahtarıyla `Runtime::Context`'e enjekte edilir (`ctx.provide(:init, init)`, `ctx.require(:init)`). Kök bağlam kapandığında (`ctx.on_dispose`), `Init` süpervizörü otomatik olarak tetiklenerek tüm alt birimleri LIFO sırasıyla imha eder.

### 7.5 Spatiotemporal Saf Bağlam Kapanışı (Headless Teardown) ve Topolojik Fiber Mutabakatı

Rubik'in spatiotemporal çalışma zamanı (`Rubik::Runtime`) ve servis kataloğu (`Rubik::REPL::ServiceCatalog`), REPL kabuğundan bağımsız, saf bağlam güdümlü (pure context-driven) ve deterministik bir yaşam döngüsü sunar:

- **Saf Bağlam Kapanışı (Headless Context Disposal):** REPL/Shell örneği bulunmayan bağımsız betiklerde, testlerde veya headless daemon modunda, yalnızca `runtime_manager.context.dispose` çağrısı yapıldığında arka plandaki tüm LSP dil sunucuları (`lsp_manager.stop_all`), MCP harici sunucu süreçleri (`mcp_manager.stop_all`), Dispatcher kworker iş parçacığı (`dispatcher.stop`) ve Init süpervizörü (`init.stop`) LIFO ($\Omega$) ters işlem garantisiyle atomik olarak durdurulur.
  - Bu bağlantı, `ServiceCatalog` tanımlarındaki `after_inject` kancalarıyla `values[:runtime_manager]&.context&.on_dispose` üzerinden kurulur.
  - `Shell#stop` çağrısı, bağlam kapanışı sonrasında çalıştırıldığında idempotent ve güvenli (no-op) kalır; alt süreçlerin mükerrer kapatılması sessizce tolere edilir.
- **Topolojik Fiber Mutabakatı (`Manager#reconcile_all`):**
  - `Runtime::Manager`, kayıtlı bileşenleri (`ComponentFiber`) aktive ederken rastgele veya hash sırasıyla değil; bileşenlerin sağladığı (`provides:`, fiber adı) ve tükettiği (`inject:`, `requires:`) servislerin bağımlılık yönlü çevrimsiz çizgesine (DAG - Directed Acyclic Graph) göre topolojik olarak sıralar (`topological_sort_fibers`, Kahn algoritması).
  - Kök servisleri ve bağımsız bileşenler önce, bağımlı tüketici bileşenler sonra aktive edilir. Bu sayede gereksiz ara deaktive/yeniden aktive dalgalanmaları önlenir.
- **Döngü İzolasyonu ve Kilitlenmesizlik (Cycle Isolation & Deadlock Freedom):**
  - Karşılıklı döngüsel bağımlılık (`A -> B -> A`) tespit edildiğinde sistem kilitlenmez. Çevrime giren fiber'lar `handle_fiber_cycle` ile izole edilerek `:failed` durumuna geçirilir ve çalışma zamanı uyarısı üretilir. Bağımsız fiber'ların yaşam döngüsü kesintisiz sürdürülür.
- **Dmesg Bağlam Kapanış Telemetrisi:**
  - `Context#dispose` başladığında, bitirildiğinde veya bir ters işlem (`inverse`) yürütülürken hata fırlattığında olaylar `Dmesg` halkasına yapılandırılmış olarak kaydedilir:
    - Başlangıç: `dmesg.log(:context, :info, "Beginning context dispose with N inverse(s)")`
    - Hata Durumu: `dmesg.log(:context, :err, "Dispose inverse failed: <Class>: <Message>")`
    - Tamamlanma: `dmesg.log(:context, :info, "Context dispose complete; N inverse(s) executed")`
  - Fiber bağımlılık döngüleri de `dmesg.log(:runtime, :err, "Dependency cycle detected among fibers: ...")` ile çekirdek telemetrisine aktarılır.

---

## 🪟 8. ShellDeps — Arayüz-Daraltıcı Façade ve PR Kontrol Listesi

> Require-seviyesi değişmezler
> (`orchestrator/runtime/tools/llm → repl` yok) CI'da
> `test/unit/test_architectural_boundaries.rb` ile zorlanır; aşağıdaki liste
> statik analizin göremediği metot-seviyesi coupling içindir.

### 8.1 `Orchestrator::ShellDeps` (`lib/rubik/orchestrator/shell_deps.rb`)

`Loop` tarafından inşa edilen tüm işbirlikçiler — `StepExecutor`,
`BudgetManager`, `StreamManager` — Loop durumuna **yalnızca bu façade
üzerinden** erişir; ham `@loop` reach-through yasaktır (Law of Demeter).
Loop kendisi `@shell_deps = ShellDeps.new(self)` ile façade'i tutar ve
işbirlikçilerine enjekte eder.

| Yüzey | Semantik | Örnekler |
| :--- | :--- | :--- |
| `SURFACE` (okuma) | Loop erişimcileri `method_missing` + `respond_to_missing?` ile **iletilir**, yeniden beyan edilmez — test dublörleri minimal kalır, `deps.respond_to?(...)` sorguları gerçek semantiği korur | `deps.provider`, `deps.history`, `deps.step_count`, `deps.safe_config` |
| Komut yüzeyi (yazma) | Loop'un `attr_accessor` alanları sızdırılmaz; mutasyonlar adlandırılmış komutlardır | `replace_history!`, `reset_invalid_tools!`, `record_invalid_tool!`, `mark_last_turn_streamed!`, `flag_context_warning!`, `emergency_compact_and_notify!` |
| `loop_instance` | Yalnızca tur-sonuç sözleşmesi: sonuç hash'i Loop nesnesini taşır, Shell devamı `continue_loop` ile sürdürür | `turn_result` |

**Kurallar:**
1. İşbirlikçi kurulumu `ShellDeps.wrap(loop_or_deps)` ile yapılır; façade ya da
   çıplak loop (test dublörü) kabul edilir.
2. Loop'a erişilebilir yeni durum eklenirken önce kategori seçilir: salt-okuma
   ise `SURFACE`'e, mutasyon ise adlandırılmış komut metoduna. Yeni bir public
   Shell metodu Loop'tan çağrılacaksa 7.2'deki ikinci madde işletilir.
3. Davranış kilidi: `test/unit/test_shell_deps.rb` (SURFACE iletimi, komut
   yüzeyi, `respond_to?` sözleşmesi, minimal dublör uyumu).
4. Kaynak-guard kilidi (Bulgu 5): işbirlikçilerde çıplak `@loop` ivarı yasak —
   Loop durumuna erişim yalnızca ShellDeps üzerinden
   (`test_no_raw_loop_ivar_reach_through_in_collaborators`); Loop'un
   `@shell'e dokunuşları gerekçeli beyaz listeyle sınırlı
   (`test_loop_shell_touches_stay_on_the_allowlist`; constructor ataması,
   config/commands sözleşme okumaları — `buffer.auto_apply` okuması 2026-09-22
   birleştirmesinde `Orchestrator::AutoApply`'e taşındı, beyaz liste küçüldü).

### 8.2 PR İnceleme Kontrol Listesi (Shell / Loop Büyüme Disiplini)

`lib/rubik/repl/shell.rb` veya `lib/rubik/orchestrator/loop.rb` dokunulan
her PR'da inceleyici şunları sorar:

- [ ] **Yeni davranış mixin'e mi, çekirdeğe mi?** Shell'e yeni bir public
      metot/ömür döngüsü davranışı eklerken önce mixin evi sorulur:
      lifecycle, presentation, config_wiring, composition, hooks,
      confirmations, turn_recorder. Çekirdek sınıfa ek yalnızca sınıflar-arası
      orkestrasyon kodu içindir.
- [ ] **Loop yeni Shell yüzeyine mi dokunuyor?** Orchestrator'dan Shell'e
      erişim yalnızca `ShellDeps` daraltıcı üzerinden. Yeni bir Shell metodu
      Loop'tan çağrılacaksa önce ShellDeps `SURFACE`'e eklenip eklenmeyeceği
      tartışılır; doğrudan `shell.xxx` reach-through red sebebidir. CI'da
      kaynak-guard ile kilitli: işbirlikçilerde çıplak `@loop` yasağı +
      `loop.rb`'de `@shell` beyaz listesi (`test_architectural_boundaries.rb`).
      Yeni bir `@shell` dokunuşu gerekçesini PR'da yazar ve guard beyaz
      listesine açıkça ekler.
- [ ] **Yeni bir işbirlikçi çıkarılmalı mı?** Aynı sorumlulukta ≥2 özel metot
      birikmişse (örn. provider-config → `ProviderResolver`), ShellDeps/StepExecutor
      deseni izlenir: dar yapıcı enjeksiyonu + Loop'ta private delegasyon şimleri.
- [ ] **Satır/sembol bütçesi:** PR, Shell'i ~600 satırın veya Loop'u ~400
      satırın üzerine çıkarıyorsa gerekçe zorunludur; aksi hâlde çıkarma
      (extraction) planlanır.

### 8.3 `REPL::CommandContext` — Komut Ekseninde Daraltıcı

Bang-komut işleyicileri tüm Shell'i değil, her dispatch'te inşa edilen
`Rubik::REPL::CommandContext`'i alır (`handler.call(args, ctx)`); inşaat
`InputExecution#execute_command` içinde, `with_output(TeeIO...)` yakalama
takasından SONRA yapılır — böylece `ctx.out` her zaman kayıt/LLM-geçmişi
yakalamasına akan IO'dur. Yüzey kapalıdır: servis okuyucuları
`ServiceCatalog.reader_names`'den türetilir (ikinci liste yok),
`conversation_history` / `active_loop` write-through erişicilerle
yeniden bağlanabilir, geri kalan her şey adlandırılmış tek satırlık etkidir.
`register_command`, ivar erişimi, `respond_to?` keşfi ve `method_missing`
yoktur. Komut modüllerinde çıplak `shell` yalnızca kayıt omurgasında
(`def self.register(shell)` + `shell.register_command`) görünebilir;
kilit: `test_repl_command_context_guard.rb` (omurga beyaz listesi +
ivar yasağı + katalog-türetme + allowlist-rot öz-denetimi) ve kapalı
yüzey dondurması `test_command_context.rb`. Kullanım özetleri omurgada
`usage:` meta verisi olarak tek-tapuludur; `!help <cmd>` bunu basar.
Özel komut dispatch'leri (SynthesizeCommandTool, OverlayStorage#eval_command,
PreflightRunner) 2-arity'ye ctx (IO-ördeği), 3-arity'ye ham shell verir.

### 8.4 `REPL::TerminalGuard` — Asenkron Ekran Koruması ve Non-blocking REPL

Asenkron alt ajanlar (`SubagentUnit`) ve arka plan komutları (`ProcessUnit`) arka planda çalışırken REPL komut satırının bloklanmadan kullanıcıya serbest bırakılması (Prompt Liberation) ve arka plan bildirimlerinin aktif girdi satırını bozamayacağı bir koruma hattı `Rubik::REPL::TerminalGuard` ile sağlanır:
- **Zero Prompt Clobbering:** Kullanıcı prompt'ta yazı yazarken (`rubik > ...`) arka plandan acil bildirim geldiğinde, ANSI `\r\e[2K` ile aktif satır silinir, bildirim temiz bir satıra yazdırılır ve `Reline.redisplay` çağrılarak kullanıcının yazdığı yarım metin ve imleç alt satıra bozulmadan yeniden çizilir.
- **Sessiz Bildirim Tamponu (Quiet Inbox Buffering):** Acil olmayan arka plan olayları doğrudan ekrana basılmak yerine `Dmesg` ring buffer'ına ve `notice_inbox`'a sessizce akar. Kullanıcı yeni satır açtığında veya Enter tuşuna bastığında `flush_notices!` ile düzenli boşaltılır.
- **Eşzamanlı REPL Etkileşimi:** Arka planda bağımsız birimler yürütülürken kullanıcı `!dmesg`, `!subagents`, `!tasks` gibi durum sorguları çalıştırabilir veya yeni bir istek girebilir.
- **Reaktif Ajan Uyandırma:** Prompt boşta ve kullanıcının girdi satırı boşken bir subagent tamamlanınca/duraklayınca/hata alınca/mesaj gönderince `TerminalGuard#safe_wakeup!` bloke okumaya bir Enter enjekte eder; dönen boş satır `execute_subagent_notice_turn!` ile agent-0 için otonom bir bildirim değerlendirme turuna dönüşür (`[reactive subagent wake-up]` işaretli sentetik prompt; `REPL::PendingNoticeQueue` uyanış bayrağıdır). Kullanıcı yazı yazarken, `!paste`/burst toplarken (`with_collecting`) veya `subagents.reactive_wakeup: false` iken uyandırma yapılmaz; bildirimler `@conversation_history`e enjekte edilir ve bir sonraki turda görülür. Subagent adım bütçesi şeffaflığı: sistem promptunda `Allocated Step Budget: N steps` ve her adımda `[Step X/Y]` göstergesi (%75 uyarı mandalı kaldırıldı; `Budget#step_marker`).

### 8.5 Kernel & Asenkron Alt Sistem Konsolidasyonu

Sistemdeki asenkron alt sistemler (Kernel, Init, Dispatcher, EventBus, Dmesg, TaskManager, Subagents) tekil ve deterministik bir SSOT altında konsolide edilmiştir:
- **Tekil Dispatcher & kworker:** `ServiceCatalog` montajında `dmesg` ve `dispatcher` tanımları `event_bus` önüne alınarak, başlangıçta dummy worker thread açıp sonradan öldürme takası kaldırılmış; sistem genelinde tek bir kalıcı `rubik-kworker` iş parçacığı bırakılmıştır.
- **Canlı SubagentUnit Durum Senkronizasyonu:** `Subagent::Instance` durum geçişleri anında `Unit#sync_state!` ile `Kernel::Unit` durum makinesine ve `Dmesg` halkasına yansıtılır; eşzamanlı olarak `:unit_state_changed` olayı fırlatılır.
- **Turn-Boundary Zombie Reaping:** Her turn tamamlandığında (kullanıcıya prompt verilmeden önce `ensure` bloğunda) `Init#reap_dead_units!` tetiklenerek tamamlanmış/başarısız birimlerin disposable alt-bağlamları (`context.dispose`) derhal LIFO sırasıyla toplanır (`:reaped`).
- **Reaktif Görev Uyanışı:** `ProcessUnit` (arka plan komutu) tamamlandığında `Lifecycle#handle_unit_event`, ekrana güvenli bildirim basmanın yanı sıra aktif LLM döngüsüne (`@active_loop`) ve `@conversation_history` içine `<task_notification ...>` formatında bildirim enjekte eder.

---

[English source](architecture.md) · [Belge dizini](../index.md) · [Türkçe README](../../README.tr.md).
