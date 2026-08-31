# Plan 69 — Kapsamlı Dokümantasyon Mimarisi: 22 Çekirdek Domain, Standart Ajan Araçları Kataloğu ve LLM Otonom Öz-Evrim Rehberi

> **Domain:** Documentation / Architecture / Extensibility / LLM Self-Evolution
> **Kaynak:** Dokümantasyon Eksiklik Analizi ve LLM Öz-Evrim Değerlendirmesi (Ağustos 2026)
> **Durum:** ⏳ Planlandı
> **Öncül Planlar:** [24](24-kendi-kendine-evrilen-arac-sentezi-ve-calisma-zamani-denetimi.md) · [51](51-display-tui-ve-cikis-bicimlendirme-katmani.md) · [54](54-built-in-araclar-ve-orkestrasyon-altyapisi-temizligi.md) · [56](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md) · [63](63-repl-kabuk-mimarisi-ayrisimi-composition-build.md) · [68](68-sifir-kurulum-kullanici-eklenti-mimarisi-dropin-dizinler-ve-yonetim-hatti.md)

---

## 1. Amaç ve Kapsam

Rubik projesinin kullanıcı, komut (`COMMANDS.md`), ayar (`CONFIG.md`), eklenti (`PLUGINS.md`) ve teorik protokol (`AGENTS.md`) dokümantasyonu son derece güçlü olmakla birlikte, kod tabanının 22 çekirdek domain'inin mimari bütünlüğü, 22 yerleşik ajan aracının tam kataloğu ve LLM modellerinin Rubik'i çalışma zamanında nasıl otonom evrilteceği (Self-Evolution) konularında geliştirici ve model açısından önemli dokümantasyon eksikleri bulunmaktadır.

Bu plan:
1. **`ARCHITECTURE.md` (22 Çekirdek Domain Haritası ve Sistem Veri Akışı):** Rubik'in `lib/rubik/` altındaki 22 bağımsız alt sistemini (`buffer`, `ast`, `orchestrator`, `runtime`, `sandbox`, `lsp`, `ui`, `context`, `session`, `diagnostics` vb.), Mermaid veri akış diyagramlarını, `Composition.build` montaj hattını ve tasarım değişmezlerini (`invariants`) belgeler.
2. **`TOOLS.md` (22 Yerleşik Ajan Aracı Kataloğu):** Ajanın ve operatörün kullanabildiği 22 standart yerleşik aracın parametre şemalarını, takma adlarını (`aliases`), risk sınıflarını (`:read`, `:write`, `:execute`), dönüş tiplerini ve Elm-tarzı teşhis formatlarını (`=== Runtime Execution Diagnostic ===`) eksiksiz bir referans tablosuna dönüştürür.
3. **`SELF_EVOLUTION.md` & `PLUGINS.md` Güncellemesi (LLM Otonom Öz-Evrim Kılavuzu):** LLM'lerin çalışma zamanında `synthesize_tool`, `synthesize_command` ve Plan 68 `Rubik.plugin` DSL'i ile Rubik'i nasıl adım adım, güvenli (LIFO $\Omega$ ters etki, sub-context izolasyonu, SHA-256 manifest) ve kalıcı olarak evrilttiğini uçtan uca örneklerle açıklar.
4. **Çapraz Referans Entegrasyonu:** `README.md`, `COMMANDS.md`, `CONFIG.md`, `PLUGINS.md` ve plan indeksleri (`_plan/index.md`) arasında tutarlı bağlantı ağı kurar.

---

## 2. Mimari Tasarım ve Fazlar

### Faz A — `ARCHITECTURE.md`: 22 Çekirdek Domain Haritası & Veri Akışı

Rubik'in modüler monolit mimarisini kuşbakışı açıklayan `ARCHITECTURE.md` oluşturulur:

1. **Sistem Genel Bakışı ve Tasarım Felsefesi:**
   - Spatiotemporal Composability (Revertible Effects & Reactive Coeffects).
   - In-Memory Virtual Buffer First (Sıfır riskli dosya işlemleri).
   - Pure-Ruby Cross-Platform Core (Windows 11 / Linux / macOS uyumluluğu).
2. **22 Çekirdek Domain Sözlüğü ve Sorumluluk Matrisi:**
   - `Rubik::Adapter`: Çok dilli test, lint ve format çalıştırma adaptörleri.
   - `Rubik::AST`: Prism parser, regex çıkarıcılar, semantik çağrı grafı ve kalıcı JSON disk önbelleği.
   - `Rubik::Benchmark`: Ajan performans ve kabul kıyaslama çatısı.
   - `Rubik::Buffer`: Bellek içi sanal tampon, snapshot geçmişi, LIFO undo ve diff motoru.
   - `Rubik::Config`: Katmanlı YAML yapılandırma (defaults, deep ops, store, validation).
   - `Rubik::Context`: Kod haritası, AST indeksleme, token tahmini ve akıllı compaction/pruning.
   - `Rubik::Diagnostics`: Elm-tarzı hata formatlayıcı, `ExecutionFailure` sınıflandırması.
   - `Rubik::EventBus`: Asenkron ve senkron olay yayın/abone hattı.
   - `Rubik::LLM`: Sağlayıcı soyutlamaları (OpenAI, Claude, Ollama, Custom), model yönlendirici (Router).
   - `Rubik::LSP`: Dil sunucusu yöneticisi, RFC 8089 URI desteği, bellek içi canlı tanı.
   - `Rubik::Orchestrator`: Ajan döngüsü (`Loop`), `StepExecutor`, `BudgetManager`, `StreamManager`, `ActivityLog`.
   - `Rubik::Platform`: Çapraz platform yardımcıları (`PATHEXT`, `which`, `kill_tree`, `path_under?`).
   - `Rubik::Plugin`: Drop-in eklenti depolama (`Storage`), `Rubik.plugin` DSL'i ve `$LOAD_PATH` refcount.
   - `Rubik::Prompt`: Sistem istemi oluşturucular, `<operational_rules>`, dinamik XML etiketleri.
   - `Rubik::Repair`: Kendi kendini onaran çalışma zamanı döngüleri.
   - `Rubik::REPL`: Etkileşimli kabuk, 8 domain komut modülü (`agent`, `buffer`, `workspace` vb.), sunum katmanı.
   - `Rubik::Runtime`: Spatiotemporal `Context`, `Fiber` durum makinesi, LIFO $\Omega$ akümülatörü, `OverlayStorage`.
   - `Rubik::Sandbox`: Süreç izolasyonu, Docker/Podman/WASM sürücüleri, kabuk oto-seçimi (`auto`).
   - `Rubik::Security`: Güvenlik muhafızı (`Guard`), kritik komut ve dosya yazım engelleri.
   - `Rubik::Session`: Oturum kaydedici (`Recorder`), JSONL loglama ve `rubik -c` devamlılığı.
   - `Rubik::Tools`: 22 yerleşik araç, araç kayıt defteri (`Registry`), Elm-tarzı geri bildirim.
   - `Rubik::UI`: TUI katmanı, canlı spinner, statusline, diff renklendirici, markdown renderer.
3. **Mermaid Mimari Veri Akış Şeması:**
   - REPL Girişi $\to$ `Composition.build` $\to$ `Orchestrator::Loop` $\to$ `StepExecutor` $\to$ `Tools` $\to$ `Buffer` / `LSP` / `Sandbox` $\to$ `UI::Renderer`.

---

### Faz B — `TOOLS.md`: 22 Standart Ajan Aracı Kataloğu

Ajanın çağırabildiği 22 built-in aracın (`lib/rubik/tools/builtins/`) eksiksiz referans tablosu:

1. **Dosya ve Arama Araçları:**
   - `read_file`, `write_file`, `list_files`, `replace_file_content`, `grep_search`.
2. **Kod Semantiği ve LSP Araçları:**
   - `search_symbols`, `get_outline`, `find_references`, `get_symbol`, `lsp_diagnostics`, `lsp_hover`, `lsp_definition`.
3. **Test, Kabuk ve Yürütüm Araçları:**
   - `run_tests`, `run_command`, `exec_repl_command`.
4. **Çalışma Zamanı ve Öz-Evrim Araçları:**
   - `synthesize_tool`, `synthesize_command`, `inspect_runtime`, `provide_service`, `apply_buffer`, `repair_runtime_service`.
5. **Kontrol ve Akış Araçları:**
   - `finish`.
6. **Her Araç İçin Detay:**
   - Parametre JSON Şeması (`required` ve `optional` alanlar).
   - Güvenlik ve Risk Seviyesi (`:read`, `:write`, `:execute`).
   - Dönen Başarı/Hata Çıktı Formatı (Elm-style Structured Diagnostics, suggestion).

---

### Faz C — `SELF_EVOLUTION.md` & `PLUGINS.md` LLM Öz-Evrim Rehberi

LLM'in Rubik'i çalışma zamanında ve disk seviyesinde nasıl evrilttiğini gösteren rehber:

1. **Öz-Evrim Döngüsü (The Self-Evolution Cycle):**
   - Adım 1: Eksik yetenek tespiti (Örn: XML dosya dönüştürücü veya özel AST metrik çıkarıcı).
   - Adım 2: `synthesize_tool` ile fonksiyon çağırma aracı üretimi ve şema tanımlama.
   - Adım 3: İzole doğrulama (`ctx.extend()` alt-bağlamında test).
   - Adım 4: Canlı araç enjeksiyonu (`@tool_registry.register`).
   - Adım 5: Kalıcı saklama (`.rubik/tools/` + SHA-256 `.manifest.json`).
   - Adım 6: Hata durumunda LIFO $\Omega$ ters işlem ile temizlik ve rollback.
2. **Uçtan Uca Kod Örnekleri:**
   - Canlı Tool Sentezi Örneği (`synthesize_tool`).
   - Canlı Bang Komut Sentezi Örneği (`synthesize_command`).
   - Kalıcı Drop-in Eklenti Sentezi (`write_file` `.rubik/plugins/my_plugin.rb` + `!plugin add`).
3. **Güvenlik Koruma Duvarları (Guardrails):**
   - Tehlikeli kod engelleme (`Security::Guard#verify_command_safety!`).
   - Tahrifat kontrolü (`RUBIK_TRUST_OVERLAYS`).

---

### Faz D — Çapraz Dokümantasyon Bağlantıları & Plan Güncellemeleri

- [`README.md`](file:///C:/Github/rubik/README.md): Dokümantasyon tablosuna `ARCHITECTURE.md`, `TOOLS.md` ve `SELF_EVOLUTION.md` linklerinin eklenmesi.
- [`PLUGINS.md`](file:///C:/Github/rubik/PLUGINS.md): Self-evolution bölümünün derinleştirilip `SELF_EVOLUTION.md` ile çapraz bağlanması.
- [`COMMANDS.md`](file:///C:/Github/rubik/COMMANDS.md): Ajan araçları ve öz-evrim komutlarının güncellenmesi.
- `_plan/00-index.md` ve `_plan/index.md`: Plan 69 kaydının eklenmesi.

---

### Faz E — Doğrulama ve Kalite Kapısı

- Tüm doküman içi markdown linklerinin (RFC 8089 / file / relative) geçerliliğinin doğrulanması.
- Kod bloklarındaki dil etiketlerinin (`ruby`, `json`, `bash`, `mermaid`) doğrulanması.
- `bundle exec rubocop` ve `bundle exec rake test` ile sıfır regresyon doğrulanması.

---

## 3. Kabul Kriterleri (Acceptance Criteria)

- [ ] `ARCHITECTURE.md` dosyası 22 çekirdek domain'i, sorumluluk matrisini ve Mermaid akış diyagramını eksiksiz içerir.
- [ ] `TOOLS.md` dosyası 22 yerleşik ajan aracının şemasını, risk seviyelerini ve dönüş formatlarını içerir.
- [ ] `SELF_EVOLUTION.md` dosyası LLM'in araç ve eklenti sentezleme döngüsünü uçtan uca örneklerle açıklar.
- [ ] `PLUGINS.md`, `COMMANDS.md`, `CONFIG.md` ve `README.md` çapraz referanslarla senkronize edilir.
- [ ] `bundle exec rubocop` 0 ihlal ile geçer.
- [ ] `bundle exec rake test` 866+ koşumda %100 yeşil kalır.
