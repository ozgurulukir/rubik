# 🏛️ Rubik Sistem Mimarisi (System Architecture)

> **Protokol:** [`AGENTS.md`](AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **İlgili Kılavuzlar:** [`TOOLS.md`](TOOLS.md) · [`SELF_EVOLUTION.md`](SELF_EVOLUTION.md) · [`PLUGINS.md`](PLUGINS.md) · [`COMMANDS.md`](COMMANDS.md) · [`CONFIG.md`](CONFIG.md)

---

## 📖 1. Sistem Genel Bakışı ve Tasarım Felsefesi

Rubik, saf Ruby (3.3+) ile yazılmış, **Spatiotemporal Composability & Self-Evolving Runtime** mimarisi üzerine kurulu modüler bir otonom kodlama harness'ıdır.

### Temel Mimari İlkeler:
1. **Spatiotemporal Composability (Revertible Effects & Reactive Coeffects):** Sistemdeki her işlem bir uzay-zaman bağlamında izole edilir; her yan etki LIFO ($\Omega$) ters işlem kaydıyla atomik olarak geri alınabilir.
2. **In-Memory Virtual Buffer First:** Model kod yazdığında dosyalar doğrudan diske yazılmaz; sanal tamponda hazırlanır. Sıfır riskli manipülasyon, snapshot geçmişi ve anında geri alma (`!undo`) sunar.
3. **Pure-Ruby Cross-Platform Core:** POSIX (Linux, macOS) ve Windows 11 ortamlarında harici native bağımlılık olmadan sorunsuz çalışır.

---

## 🧩 2. 22 Çekirdek Domain Sözlüğü ve Sorumluluk Matrisi

Rubik'in `lib/rubik/` dizini altındaki 22 bağımsız alt sistemi:

| # | Domain | Modül / Sınıf | Sorumluluk & Görev |
| :--- | :--- | :--- | :--- |
| 1 | **`adapter`** | `Rubik::Adapter` | Çok dilli test, lint ve format çalıştırma adaptörleri (Ruby, Python, Go, Rust, TS vb.). |
| 2 | **`ast`** | `Rubik::AST` | Prism parser, semantik sembol ve çağrı grafı (`Graph`), kalıcı JSON disk önbelleği. |
| 3 | **`benchmark`**| `Rubik::Benchmark` | Ajan performans ve kabul kıyaslama test çatısı. |
| 4 | **`buffer`** | `Rubik::Buffer` | Bellek içi sanal tampon (`Manager`), snapshot geçmişi, LIFO undo ve diff motoru. |
| 5 | **`config`** | `Rubik::Config` | Katmanlı YAML yapılandırma (defaults, deep ops, store, schema validation). |
| 6 | **`context`** | `Rubik::Context` | Kod haritası, AST indeksleme, token tahmini ve akıllı compaction/pruning. |
| 7 | **`diagnostics`**| `Rubik::Diagnostics` | Elm-tarzı hata formatlayıcı, `ExecutionFailure` sınıflandırması ve geri bildirim. |
| 8 | **`event_bus`**| `Rubik::EventBus` | Asenkron ve senkron olay yayın/abone (`Pub/Sub`) omurgası. |
| 9 | **`llm`** | `Rubik::LLM` | Sağlayıcı soyutlamaları (OpenAI, Claude, Ollama, Custom), model yönlendirici (`Router`). |
| 10 | **`lsp`** | `Rubik::LSP` | Dil sunucusu yöneticisi, RFC 8089 URI desteği, bellek içi canlı tanı. |
| 11 | **`orchestrator`**| `Rubik::Orchestrator`| Ajan döngüsü (`Loop`), `StepExecutor`, `BudgetManager`, `StreamManager`, `ActivityLog`. |
| 12 | **`platform`** | `Rubik::Platform` | Çapraz platform yardımcıları (`PATHEXT`, `which`, `kill_tree`, `path_under?`). |
| 13 | **`plugin`** | `Rubik::Plugin` | Drop-in eklenti depolama (`Storage`), `Rubik.plugin` DSL'i ve `$LOAD_PATH` refcount. |
| 14 | **`prompt`** | `Rubik::Prompt` | Sistem istemi oluşturucular, `<operational_rules>`, dinamik XML etiketleri. |
| 15 | **`repair`** | `Rubik::Repair` | Kendi kendini onaran çalışma zamanı döngüleri ve teşhis tabanlı düzeltme. |
| 16 | **`repl`** | `Rubik::REPL` | Etkileşimli kabuk (`Shell`), 8 domain komut modülü (`agent`, `buffer` vb.), sunum katmanı. |
| 17 | **`runtime`** | `Rubik::Runtime` | Spatiotemporal `Context`, `Fiber` durum makinesi, LIFO $\Omega$ akümülatörü, `OverlayStorage`. |
| 18 | **`sandbox`** | `Rubik::Sandbox` | Safe Execution (her zaman aktif), tak-çıkar OS sandbox (bwrap/docker/podman/firejail), dinamik kayıt defteri. |
| 19 | **`security`** | `Rubik::Security` | Güvenlik muhafızı (`Guard`), kritik komut ve dosya yazım engelleri. |
| 20 | **`session`** | `Rubik::Session` | Oturum kaydedici (`Recorder`), JSONL loglama ve `rubik -c` devamlılığı. |
| 21 | **`tools`** | `Rubik::Tools` | 22 yerleşik araç, araç kayıt defteri (`Registry`), Elm-tarzı yönlendirici hata formatı. |
| 22 | **`ui`** | `Rubik::UI` | TUI katmanı, canlı spinner, statusline, diff renklendirici, markdown renderer. |

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
    
    StepExec --> Tools[Rubik::Tools::Registry<br/>22 Built-in + Custom Tools]
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
2. **LIFO Ters İşlem Garantisi ($\Omega$):** Çalışma zamanında üretilen her araç (`synthesize_tool`) veya servis kaydı (`ctx.provide`), yaşam döngüsü bittiğinde ters sırayla temizlenir.
3. **Çoklu Platform Saydamlığı:** Dosya yolları, işlem sonlandırma ağaçları (`kill_tree`) ve kabuk çağrıları platforma göre şeffaf bir şekilde yönetilir.

---

## 💎 5. Saf Ruby & Sıfır-Native Bağımlılık Mimarisi

Rubik, Windows, macOS ve Linux sistemlerinde **harici C derleyicisi (GCC, Clang, MSVC) veya C-extension derleme adımı gerektirmeden** sıfır-kurulum çalışacak şekilde tasarlanmıştır:
- **Ruby AST:** Ruby 3.3+ ile yerleşik gelen resmi **Prism** ayrıştırıcısını kullanır; harici native gem bağımlılığı yoktur.
- **Çok Dilli Semantik AST:** Python, Go, Rust, TypeScript, Zig, C gibi dillerde regex tabanlı dayanıklı heuristik çıkarıcılar ve `FallbackCleaner` ile çalışır.
- **Dil Sunucusu Desteği (LSP):** İleri düzey tip ve semantik analiz için harici native derleme yerine sistemde kurulu standart dil sunucularına (`gopls`, `rust-analyzer`, `solargraph`, `pyright` vb.) RFC 8089 uyumlu JSON-RPC ile bağlanır.

---

## 🔒 6. Eşzamanlılık (Thread-Safety) ve Devre Kesici (Circuit Breaker)

- **Re-entrant Buffer Senkronizasyonu:** `Buffer::Manager`, eşzamanlı arka plan AST indeksleme ve çoklu fiber erişimlerine karşı `Monitor` ile korunur.
- **LSP Crash Circuit Breaker:** Bozuk veya sürekli çöken dil sunucularının döngüye girip sistemi tıkamasını önlemek için üst üste 3 çöküşte LSP devre kesicisi devreye girer (`:circuit_open`) ve 5 dakika boyunca otomatik yeniden başlatmayı askıya alır. `!lsp restart` ile manuel olarak sıfırlanabilir.
