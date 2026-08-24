# 📋 Plan 45: Kod Tabanı Genelinde Spatiotemporal Öz-Evrilen Çalışma Zamanı, Otonom Hata Teşhisi ve LLM Destekli Adaptör Sentezi

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** İleri Düzey · **Faz:** 5 (Öz-Evrilen Çalışma Zamanı & Otonom Ajan Mimarisi)  
> **İlgili Planlar:** [11](11-kendi-kendini-iyilestirme-self-repair.md), [13](13-izole-process-sandbox-ve-kaynak-limiti.md), [18](18-tree-sitter-ast-ve-lsp-entegrasyonu.md), [20](20-spatiotemporal-runtime-context-ve-fiber-yasam-dongusu.md), [24](24-kendi-kendini-gelistiren-arac-sentezi.md), [29](29-derin-lsp-ve-canli-derleyici-entegrasyonu.md), [33](33-spatiotemporal-koefektler-ve-ters-islemler.md), [44](44-llm-egitim-uyumlu-arac-isimlendirmesi-grep-ve-tool-aliasing.md)

---

## 🎯 1. Vizyon ve `AGENTS.md` İdealleriyle Yüzleşme

### 🛑 Mevcut Mimari Eksiklikleri (Geniş Perspektif):
1. **Statik & Kırılgan Hardcode Bileşenler:**
   - **LSP Katmanı:** `Client::SERVERS` içinde statik komut dizgileri.
   - **Test & Linter Adaptörleri:** `Rubik::Adapter::Registry` içinde statik komutlar (`go test`, `cargo test`, `rspec`). Özel paket yöneticileri (`pnpm`, `poetry`, `bundle exec`, `cargo nextest`) veya eksik flag'ler olduğunda kilitleniyor.
   - **Çevre Keşfi (Env Discovery):** Sanal ortamlar (`venv`, `rbenv`, `nvm`), Nix/ASDF shim'leri dinamik taranmıyor.
2. **Sessiz Başarısızlık Yutma (Silent Failure Swallowing — `AGENTS.md Anti-Pattern ❌`):**
   - Alt süreçler (LSP, Sandbox, Adapter) çöktüğünde veya zaman aşımına uğradığında `stderr`, çıkış kodları ve hata bağlamı zenginleştirilip LLM'e sunulmuyor; genel bir hata metniyle sessizce sonlanıyor.
3. **LLM'in Kendi Çevresini Otonom İyileştirememesi (No Reflexive Self-Evolution):**
   - Bir aracın, LSP sunucusunun veya test koşucusunun çalışmaması durumunda LLM araya girip durumu **otonom bir refleks olarak teşhis edip düzeltemiyor**. Sadece kullanıcının manuel `!synthesize` veya `!config` demesi bekleniyor.
4. **Spatiotemporal Coeffect İzolasyonunun Yarım Kalması:**
   - Harici servisler (LSP, DB, Process runner'lar) `Context` içinde birer reaktif Fiber / Coeffect olarak modellenmediği için LIFO temizleme ve atomik geri alma (`atomic failure rollback`) işletilemiyor.

---

## 🏛️ 2. Bütüncül Çözüm Mimarisi (Self-Evolving Runtime Architecture)

```
 ┌────────────────────────────────────────────────────────────────────────────────────────┐
 │                      Rubik Spatiotemporal Unified Context (ctx)                        │
 └───────────────────────────────────────────┬────────────────────────────────────────────┘
                                             │
      ┌──────────────────────────────────────┼──────────────────────────────────────┐
      ▼                                      ▼                                      ▼
┌──────────────┐                      ┌──────────────┐                       ┌──────────────┐
│  LSP Service │                      │ Test Runner  │                       │ Linter / AST │
│   Coeffect   │                      │   Coeffect   │                       │   Coeffect   │
└──────┬───────┘                      └──────┬───────┘                       └──────┬───────┘
       │ Execution Failure                   │ Unknown Runner / Missing Flag        │ Unsupported Syntax
       └─────────────────────────────┬───────┴──────────────────────────────────────┘
                                     │
                                     ▼ (Capture Stderr, ExitCode, Env, Attempted Command)
       ┌────────────────────────────────────────────────────────────────────────────┐
       │               Autonomous Diagnostic & Reflection Engine (ADRE)             │
       │       "Neden başarısız oldu? Çevre neyi gerektiriyor? Hangi flag eksik?"   │
       └─────────────────────────────────────┬──────────────────────────────────────┘
                                             │
                                             ▼
       ┌────────────────────────────────────────────────────────────────────────────┐
       │          Isolated Sub-Context Probing Sandbox (ctx.extend())               │
       │   1. Multi-Candidate Discovery (Path, Shim, Flag probing)                  │
       │   2. Dynamic LLM Adapter Synthesis (generate candidate adapter)           │
       │   3. Pre-flight Handshake / Verification in Sandbox                        │
       │   4. Failure -> LIFO Unwind & Log / Success -> Atomic Promotion            │
       └─────────────────────────────────────┬──────────────────────────────────────┘
                                             │ Verified
                                             ▼
       ┌────────────────────────────────────────────────────────────────────────────┐
       │   Live Context Promotion (ctx.provide) & YAML::Store Persistence           │
       │   "Runtime çevreye adapte oldu, sıfır kesintiyle (zero-downtime) devam et!" │
       └────────────────────────────────────────────────────────────────────────────┘
```

---

## ⚙️ 3. Kod Tabanı Genelinde 4 Ana Geliştirme Sütunu

### 🏛️ Sütun 1: Evrensel Dinamik Keşif & Probing Motoru (`Rubik::Runtime::Discovery`)
Statik hardcode listeleri yerine her alt sistem için dinamik çevre taraması:
1. **LSP Keşfi:** Sistemdeki binary'leri (`which`), flag'leri (`--stdio`, `stdio`), shim'leri (`rbenv`, `nvm`, `cargo`) dinamik probe eder.
2. **Test & Build Keşfi:** Proje kökünde `Gemfile`, `package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod` dosyalarını analiz ederek doğru test runner adaylarını (`bundle exec rspec`, `pnpm test`, `pytest`, `cargo nextest`) otomatik sıralar.
3. **Formatlayıcı & Linter Keşfi:** Kurulu formatter ve linter'ları algılar.

### 🧠 Sütun 2: Otonom Hata Teşhisi ve Yansıtma Motoru (`Rubik::Runtime::DiagnosticEngine`)
Herhangi bir alt süreç veya araç başarısız olduğunda:
- `stderr`, `stdout`, çıkış kodu ve çalıştırılan ortam değişkenleri yakalanır.
- Sessizce hata yutulmaz; zenginleştirilmiş yapılandırılmış hata nesnesi (`ExecutionFailure`) oluşturulur.
- Otomatik teşhis: Bilinen kalıplar (missing stdio flag, uninstalled package, wrong runner, permission denied) taranır.

### 🛠️ Sütun 3: LLM Destekli Otonom Adaptör Sentezi (`Rubik::Tools::RepairRuntimeTool`)
Ajanın çalışma zamanını otonom olarak iyileştirebilmesi için yerel araçlar:
1. **`repair_runtime_service` (Kanonik)** — `Aliases: ["fix_service", "repair_lsp", "repair_runner"]`:
   - Başarısız olan servisi (`lsp`, `test_runner`, `linter`, `command`) zengin hata günlüğüyle analiz eder.
   - LLM'in önerdiği yeni komut veya adaptörü izole sub-context (`ctx.extend()`) içinde test eder.
   - Başarılı olursa canlı çalışma zamanına sağlar (`ctx.provide`) ve `YAML::Store`'a kaydeder.
2. **Ajan Döngüsünde Otonom Refleks (Autonomous Recovery Reflex):**
   - Model bir test veya LSP çalıştırmak istediğinde altyapı çökerse, döngü hatayı doğrudan ajana verip "Bunu izole alt bağlamda onarmak için hipotezini dene" fırsatı tanır.

### 🔄 Sütun 4: Spatiotemporal Coeffect Entegrasyonu (`AGENTS.md` Tam Uyumu)
- Tüm harici servisler (LSP sunucuları, Test sandbox'ları, Background watcher'lar) `Rubik::Runtime::Context` üzerinde birer Coeffect olarak tescil edilir (`ctx.provide("lsp:#{lang}", client)`).
- **Locality of Disposal (Yerel Ters İşlem):** Servis oluşturulduğu anda kapatma/temizleme lambda'sı accumulator'a (`ctx.register_disposable`) eklenir.
- Bir servis değiştirildiğinde veya yeniden yüklendiğinde, eski servis sıfır zombi process bırakacak şekilde LIFO sırasıyla temizlenir.

---

## 🧪 4. Test ve Kalite Güvencesi

1. **`test/unit/test_runtime_discovery.rb`:**
   - Proje tipine göre dinamik test runner ve LSP adaylarının doğru keşfi.
2. **`test/unit/test_autonomous_diagnostic_and_repair.rb`:**
   - Bozuk bayraklı bir LSP/test komutunun çalıştırılması $\rightarrow$ `DiagnosticEngine`'in `stderr`'i yakalaması $\rightarrow$ `repair_runtime_service` ile sub-context'te onarılıp ana context'e yükseltilmesi.
3. **`test/unit/test_spatiotemporal_coeffect_lifecycle.rb`:**
   - 100 ardışık adaptör değişimi ve reload senaryosunda zombi process veya bellek sızıntısı olmadığını doğrulayan LIFO stress testi.
4. **Mevcut Test Süiti:** Tüm 305 testin kesintisiz %100 yeşil kalması (305 runs, 2178 assertions, 0 failures, 0 errors).

---

## 🚀 5. Uygulama Adımları

1. **Aşama 1 (Kullanıcı Onayı):** Bütüncül Plan 45 mimarisi incelendi ve onaylandı.
2. **Aşama 2 (Çoklu Ajan Takım Çalışması):**
   - **Reviewer:** Bileşen arayüzlerini ve veri akışını netleştirdi.
   - **Executor:** Discovery, DiagnosticEngine, repair_runtime_service ve Coeffect entegrasyonunu kodladı.
   - **Auditor:** Red-team denetimi ve spatiotemporal invariant kontrolü tamamlandı.
3. **Aşama 3 (Onay & Push):** Test süiti bağımsız olarak doğrulandı, kullanıcı onayı bekleniyor.
