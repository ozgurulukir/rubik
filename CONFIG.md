# ⚙️ Rubik Yapılandırma Kılavuzu (CONFIG.md)

Bu belge, **Rubik AI Coding Agent**&apos;ın yapılandırma hiyerarşisini, tüm ayar seçeneklerini (knobs), dinamik LLM sağlayıcılarını (providers), modellerin bağlam limitlerini (context limits), bellek içi tampon (buffer) politikalarını ve REPL komutlarını detaylandırır.

---


## 🏛️ 1. Yapılandırma Hiyerarşisi ve Öncelik Sırası

Rubik, yapılandırmayı katmanlı ve transaksiyonel (`YAML::Store`) bir modelde birleştirir (deep merge):

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ 1. Varsayılan Çekirdek Ayarlar (Default Config)                         │
│    └─► 2. Global Kullanıcı Ayarları (~/.rubik/config.yml)               │
│         └─► 3. Proje Özel Ayarları (.rubik/config.yml veya rubik.yml)   │
│              └─► 4. REPL Çalışma Zamanı Parametreleri                   │
└─────────────────────────────────────────────────────────────────────────┘
```

- **Global Yapılandırma:**
  - **Linux / macOS:** `~/.rubik/config.yml`
  - **Windows:** `C:\Users\<Kullanıcı>\.rubik\config.yml` (`%USERPROFILE%\.rubik\config.yml`)
- **Proje Yapılandırması:** Proje kök dizinindeki `.rubik/config.yml` veya `rubik.yml` (Yalnızca o proje için geçerlidir, global ayarları ezer).



## 📄 Tam Açıklayı Yapılandırma Şablonu

```yaml
# ==============================================================================
# 🎲 Rubik Configuration File (.rubik/config.yml veya ~/.rubik/config.yml)
# ==============================================================================

# ------------------------------------------------------------------------------
# 🌊 0. LLM İletişimi ve Canlı Token Akışı (Streaming vs. Batch)
# ------------------------------------------------------------------------------
llm:
  # Canlı token akışı (Streaming) motoru:
  #   • true  : Model yanıtı üretilir üretilmez token token terminale akar (0s TTFT).
  #             Ctrl+C ile anında kesilebilir, gereksiz token tüketimi önlenir (Varsayılan).
  #   • false : Bloklayıcı batch modu. Yanıtın tamamı üretilene kadar beklenir ve topluca basılır.
  stream: true

# 💡 STREAMING VS. BATCH VE %50 MALİYET TASARRUFU KILAVUZU:
#   • Streaming Modu (`llm.stream: true`):
#       - İnteraktif REPL oturumları ve eşli programlama için idealdir.
#       - Modelin düşünce zinciri anında ekranda belirir; gecikme algısı sıfırdır.
#       - İstenmeyen kod üretimi veya döngü fark edildiğinde Ctrl+C ile milisaniyede kesilir.
#   • Batch Modu (`llm.stream: false`):
#       - Arka plan scriptleri, CI/CD pipeline'ları ve otomatik analizler için uygundur.
#       - Özel Batch Endpoint'leri (OpenAI Batch API, Anthropic Message Batches):
#         24 saatlik SLA ile asenkron çalışan batch endpoint'leri %50'ye varan maliyet
#         indirimi ve çok daha yüksek rate limit kotaları sunar.
#
# ------------------------------------------------------------------------------
# 🖥️ 0-b. Display Katmanı (Hibrit TUI: Tema, Spinner, Statusline, Markdown)
# ------------------------------------------------------------------------------
# Rubik'in terminal görüntüleme katmanı Plan 51 ile yenilendi: ⏺/⎿ ajan akış
# dili, canlı fiil spinner'ı, prompt üstü statusline, canlı markdown render'ı
# ve renkli diff görüntüleyici. Tüm yüzeyler yetenek algısıyla çalışır: TTY
# olmayan borularda, NO_COLOR=1 veya RUBIK_TEST=1 altında çıktı klasik düz
# metne döner ve oturum kayıtları asla ANSI kodu içermez.
ui:
  # Renk modu: auto (varsayılan; TTY ise açar) | always | never
  color: auto
  # Glif seti: unicode (⏺ ⎿ ✻) | ascii (eski conhost terminal fallback'i)
  glyphs: unicode
  # Açılışta sürüm + model + çalışma alanı banner'ı (yalnızca interaktif TTY)
  banner: true
  # LLM beklerken canlı fiil spinner'ı (Düşünüyor, Kavuruyor, Damıtıyor...)
  spinner: true
  # Özel spinner fiilleri (boş bırakılırsa yerleşik Türkçe seti kullanılır)
  spinner_verbs: []
  # Asistan yanıtının markdown işlenmesi: live (satır satır canlı) | off
  markdown: live
  # Prompt üstü bağlam şeridi (model, bağlam yüzdesi, kirli tampon, sandbox)
  statusline: true
  # Statusline şablonu; yer tutucular: {project} {branch} {model} {ctx}
  # {dirty} {sandbox} {verbosity}
  statusline_template: "{model} · ctx {ctx} · {dirty} · sandbox {sandbox}"
  # Kutulu girdi alanı denemesi (üst çerçeve + sol ray; beta, varsayılan kapalı)
  input_box: false

# 💡 DISPLAY KATMANI İPUÇLARI:
#   • `rubik --no-color`  : ANSI renk/banner/spinner'ı tamamen kapatır (CI uyumlu).
#   • `rubik --color`     : Boruya yönlendirilse bile renkleri zorlar (CLICOLOR_FORCE).
#   • NO_COLOR=1 ortam değişkeni de desteklenir (https://no-color.org).
#   • `!config set ui.color never -g` gibi tüm ui.* anahtarları REPL çalışırken
#     değiştirilebilir; display katmanı anında yeniden inşa edilir (refresh_ui!).
#   • Spinner thread'i Runtime Context'inin LIFO ters işlemiyle (ctx.on_dispose)
#     yok edilir; oturum kapanışında sızıntı olmaz (AGENTS.md protokolü).
#
# ------------------------------------------------------------------------------
# 🌐 1. Dinamik LLM Sağlayıcıları ve Özel Endpoint'ler (Providers Registry)
# ------------------------------------------------------------------------------
# İstediğiniz sayıda OpenAI-uyumlu (OpenRouter, DeepSeek, Ollama, LMStudio vb.),
# Mistral AI veya Anthropic sağlayıcısını ve modellerini buraya tanımlayabilirsiniz.
providers:
  # A. OpenRouter (Yüzlerce model, tek API)
  openrouter:
    type: openai_compatible
    endpoint: https://openrouter.ai/api/v1/chat/completions
    api_key_env: OPENROUTER_API_KEY
    headers:
      HTTP-Referer: https://github.com/ozgurulukir/rubik
      X-Title: Rubik AI Coding Agent
    models:
      - name: anthropic/claude-3.7-sonnet
        context_limit: 200000
      - name: deepseek/deepseek-r1
        context_limit: 128000
      - name: deepseek/deepseek-chat
        context_limit: 64000
      - name: meta-llama/llama-3.3-70b-instruct
        context_limit: 128000
      - name: qwen/qwen-2.5-coder-32b-instruct
        context_limit: 32768

  # B. DeepSeek (Resmi API)
  deepseek:
    type: openai_compatible
    endpoint: https://api.deepseek.com/chat/completions # (veya sadece https://api.deepseek.com)
    api_key_env: DEEPSEEK_API_KEY
    models:
      - name: deepseek-chat
        context_limit: 64000
      - name: deepseek-reasoner
        context_limit: 64000

  # C. Cline API Gateway
  cline:
    type: openai_compatible
    endpoint: https://api.cline.bot/api/v1/chat/completions # (veya sadece https://api.cline.bot)
    api_key_env: CLINE_API_KEY
    models:
      - name: cline-pass/deepseek-v4-flash
        context_limit: 64000
      - name: deepseek/deepseek-r1
        context_limit: 128000

  # D. Ollama / LMStudio OpenAI Uyumluluk Sunucusu
  ollama:
    type: openai_compatible
    endpoint: http://localhost:8000/v1/chat/completions # (veya sadece http://localhost:8000)
    models:
      - name: Qwen/Qwen2.5-Coder-32B-Instruct
        context_limit: 32768

  # F. Yerel Ollama (native /api/chat protokolü, Plan 61)
  # num_ctx: Ollama sunucusuna gönderilen bağlam penceresi. Tanımsızsa
  #   modelin kayıtlı context_limit'i kullanılır — aksi halde Ollama prompt'un
  #   başını kendi varsayılanı (~2-4k token) ile sessizce keser ve model eski
  #   konuşmayı "unutur". Küçük GPU'larda VRAM'i sınırlamak için buraya
  #   sabit bir değer yazabilirsiniz.
  ollama_native:
    type: ollama
    endpoint: http://localhost:11434
    num_ctx: 32768
    default_model: qwen2.5-coder:7b

  # E. Mistral AI
  mistral:
    type: openai_compatible
    endpoint: https://api.mistral.ai/v1/chat/completions
    api_key_env: MISTRAL_API_KEY
    models:
      - name: mistral-large
        context_limit: 32000
      - name: mistral-small
        context_limit: 32000

# ------------------------------------------------------------------------------
# 🧠 2. Model ve Çoklu Rol Yönlendirme (Multi-Role Router)
# ------------------------------------------------------------------------------
model:
  provider: openrouter          # &apos;openrouter&apos;, &apos;cline&apos;, &apos;deepseek&apos;, &apos;mistral&apos;, &apos;anthropic&apos;, &apos;openai&apos;, &apos;ollama&apos;
  name: deepseek/deepseek-chat  # Model adı
  endpoint: https://openrouter.ai/api/v1/chat/completions

models:
  # Varsayılan Rol (Genel eşli kodlama, analiz ve sohbet)
  default:
    provider: openrouter
    name: deepseek/deepseek-chat

  # Hızlı Rol (!plan üretimi veya hafif bağlam sorguları)
  fast:
    provider: ollama
    name: llama3

  # Gelişmiş Rol (Karmaşık refactor veya uzun süreli !goal otonom döngüsü)
  advanced:
    provider: openrouter
    name: anthropic/claude-3.7-sonnet

# Router Modu: 'auto' (görev tipine göre otomomatic seçer) veya 'manual' (default model kullanılır)
# sticky (Plan 61): true iken serbest metin turları konuşma boyunca yerleşik
#   provider/model'e bağlı kalır; "hızlı kontrol et" gibi anahtar kelimeler
#   konuşma ortasında modeli değiştirmez. Geçiş yalnızca !model komutuyla veya
#   yeni konuşmayla olur. false → her turda yeniden sınıflandırma (eski davranış).
router:
  mode: auto
  sticky: true

# ------------------------------------------------------------------------------
# 🤖 3. Agentic Orkestrasyon ve Adım Bütçesi (Agentic Step Budget)
# ------------------------------------------------------------------------------
agent:
  # Standart interaktif promptlar için maksimum adım sayısı (Varsayılan: 40)
  max_steps: 40

  # !goal otonom test-geçirme döngüsü için adım sayısı (Varsayılan: 80)
  goal_max_steps: 80

  # !plan plan üretimi adım sayısı (Varsayılan: 15)
  plan_max_steps: 15

  # Bütçe uyarı eşiği (0.75 = Bütçenin %75&apos;inde modele XML yakınsama uyarısı gönderir)
  warn_at_ratio: 0.75

  # Bütçe aşıldığında REPL&apos;de otomatik devam sorma
  ask_continue_on_limit: true

# ------------------------------------------------------------------------------
# 🛠️ 4. Tool Girdi / Çıktı ve Akıllı Bağlam Kırpma (Tool I/O & Truncation)
# ------------------------------------------------------------------------------
tools:
  # Tek bir tool çıktısının maksimum karakter sınırı (Bağlam patlamasını önler)
  max_output_chars: 12000

  # Maksimum satır sınırı
  max_output_lines: 300

  # Kırpma stratejisi: &apos;head_tail&apos; (baş ve son satırları korur), &apos;head_only&apos;, &apos;tail_only&apos;
  truncation_strategy: head_tail

  # Tool yürütüm zaman aşımı (saniye)
  timeout_seconds: 30

  # Native hız yolları (Plan 52): sistemdeki rg (ripgrep) ve git
  # binary'leriyle grep_search ve bağlam taramasını hızlandırır.
  #   • auto : rg/git varsa hızlı yol, yoksa saf Ruby (Varsayılan)
  #   • on   : hızlı yolu zorla (binary yoksa sessizce saf Ruby'ye döner)
  #   • off  : saf Ruby yollarını zorla (deterministik, spawn yok)
  # ENV geçersiz kılmaları: RUBIK_NATIVE=off | on | auto, RUBIK_RG_PATH=<tam yol>
  native: auto

  # Cerrahi hedefli kod düzenleme (`replace_file_content`) ve Elm derleyicisi
  # tarzı hata formatlayıcı (`DiagnosticReporter` & `FuzzyMatcher`):
  # frontier seviyesindeki LLM'lerin en yüksek ilk deneme başarı oranına (first-attempt pass rate)
  # ulaşmasını sağlar. Değiştirilmek istenen blok bulunamadığında diff-lcs ile en yakın
  # satırlar ve DidYouMean önerileri otomatik sunulur.

# ------------------------------------------------------------------------------
# ⚡ 5. Language Server Protocol (LSP) ve Canlı Derleyici Teşhisi
# ------------------------------------------------------------------------------
lsp:
  # LSP motorunu etkinleştir (true: Derleyici doğruluğunda tip/teşhis, false: Saf AST)
  enabled: true

  # İlgili kaynak dosya açıldığında dil sunucusunu arka planda otomatik başlat
  auto_start: true

  # write_file çağrıldığında derleyici/linter hatalarını anında modele geri bildir
  auto_diagnostics: true

  # Çok dilli LSP sunucu ikili eşlemeleri
  servers:
    rust: "rust-analyzer"
    typescript: "typescript-language-server --stdio"
    javascript: "typescript-language-server --stdio"
    python: "ruff server"
    ruby: "typeprof --lsp --stdio"
    bash: "bash-language-server start"
    crystal: "crystalline"
    gleam: "gleam lsp"
    go: "gopls"
    zig: "zls"
    c: "clangd"
    cpp: "clangd"

# ------------------------------------------------------------------------------
# 📝 6. Bellek İçi Dosya Tamponu (In-Memory Buffer) ve Güvenlik
# ------------------------------------------------------------------------------
buffer:
  # Diske otomatik uygulama politikası:
  #   • &apos;manual&apos;    : Değişiklikler yalnızca &apos;!apply&apos; komutuyla diske yazılır (Varsayılan & En Güvenli)
  #   • &apos;on_test&apos;   : &apos;!test&apos; komutu çalıştırılmadan hemen önce tamponu diske uygular
  #   • &apos;on_finish&apos; : Görev başarıyla tamamlandığında tamponu diske uygular
  #   • &apos;always&apos;    : Model tampona yazdığı anda anında diske kaydeder
  auto_apply: manual

  # Modelin apply_buffer aracını kendi inisiyatifiyle çağırabilmesine izin ver
  model_can_apply: true

  # REPL promptunda kirli tampon dosya sayısını göster (örn: rubik (app) [DIRTY: 2 ✎] >)
  prompt_indicator: true

  # Kirli tampon varken REPL&apos;den çıkış yapıldığında kullanıcıyı uyar
  exit_guard: true

  # Belirli sayıda tur boyunca unapplied tampon varsa hatırlatıcı mesaj göster
  reminder_interval: 3

  # Diskte harici değişiklik tespit edildiğinde tampon uygulama politikası:
  #   • 'skip'      : Harici değişen dosyayı atlar, veri kaybını önler (Varsayılan & En Güvenli)
  #   • 'overwrite' : Harici değişikliği yok sayıp tampon içeriğini diske zorla yazar
  on_external_modification: skip

# ------------------------------------------------------------------------------
# 🛡️ 7. Güvenlik, Safe Execution ve Pluggable Sandbox İzolasyonu
# ------------------------------------------------------------------------------
sandbox:
  enabled: false                # true: sandbox kafesi devrede, false: doğrudan güvenli host çalışması
  driver: bwrap                 # 'bwrap' (Linux varsayılan), 'docker', 'podman' veya tak-çıkar motor ('firejail')
  prompt_on_startup: true       # Linux & bwrap tespit edildiğinde açılışta nazik öneri gösterimi
  image: rubik-sandbox:latest   # Container motorları için varsayılan imaj
  timeout_seconds: 15
  memory_limit_mb: 512
  cpus: "1.0"
  allow_network: false
  shell: auto                   # 'auto', 'bash', 'pwsh', 'cmd' veya 'sh' (Plan 55)

security:
  # Engellenen dosya yazma, kök ekleme ve tehlikeli komut girişimlerinin kaydedildiği denetim günlüğü:
  audit_log_path: ~/.rubik/audit.log

# `sandbox.shell` — run_command komutlarının hangi kabukla çalışacağı (Plan 55).
# `auto` (varsayılan) komut başına sözdizimi kapısıyla seçer:
#   - bash-zorunlu sözdizimi (<(...), >(...), /dev/null, heredoc)  -> bash
#   - PowerShell parmak izi ($env:, Verb-Noun cmdlet'leri: Select-String, Get-*, ConvertTo-*, ...) -> pwsh
#   - $-değişkeni/komut ikamesi ($(...), `, $VAR) ve POSIX tek-tırnak ('...') [Windows] -> bash
#   - düz komutlar (&&, ||, |, ikili çağrılar)                      -> Windows: cmd, diğer: bash (sh)
# Seçim, komut sonucunda etiketlenir: `[EXIT 1] (bash) ...`. Sistem istemi,
# kabuk davranışını <environment> satırıyla modele önceden bildirir.
# `powershell` (5.1) kasıtlı olarak küme dışıdır: `&&` zincirlerini desteklemez
# ve çıkış kodlarını güvenilmez biçimde yayar; açık seçimde de `auto`'ya döner.

# Kendi kendini onarma döngüsü maksimum adım sayısı
repair:
  max_attempts: 3

# Ağ erişim izni (Global varsayılan)
network:
  allow: false

### 🛡️ Safe Execution vs Sandbox İzolasyon Matrisi

1. **Safe Execution (Her Zaman Aktif Evrensel Politika — Tree-Sitter AST + Fail-Safe Regex):**
   - **Tree-Sitter AST Birincil Güvenlik Kalkanı:**
     Bash (`tree-sitter-bash`) ve PowerShell (`tree-sitter-powershell`) komutları çalıştırılmadan önce tam soyut sözdizim ağacı (AST) düzeyinde taranır.
   - **168 CLI YAML Kural Veritabanı:**
     168 popüler CLI aracı (`lib/rubik/security/data/*.yml`) için tanımlanmış kurallarla alt komutlar, argümanlar ve bayraklar semantik kategorilere (`read`, `write`, `execute`, `network`, `destructive`, `elevated` vb.) ayrılır.
   - **Yol Normalizasyonu & Kök Dizin Koruması:**
     AST düğümlerindeki dosya ve dizin argümanları normalize edilerek tehlikeli sistem kökleri (`/`, `C:\`, `~`, `/etc`, `/dev` vb.) ve `../` path traversal kaçışları yakalanır.
   - **Boru Hattı Zehirleme (Pipeline Poisoning) Kalkanı:**
     `|`, `&&`, `;` boru hatları ve komut zincirleri içine gizlenmiş alt komutlar recursive olarak taranır.
   - **Fail-Safe Regex Fallback:**
     Tree-sitter gramerinin hazır olmadığı veya AST ayrıştırmanın başarısız olduğu durumlarda, çok katmanlı sertleştirilmiş regex motoru (`DANGEROUS_COMMAND_PATTERNS`) devreye girerek tehlikeli komutları (`rm -rf /`, `mkfs`, `dd if=`, fork bomb vb.) bloklar.
   - **Güvenlik Denetim Günlüğü (`security.audit_log_path`):**
     Engellenen tüm yazma, kök ekleme ve komut denemeleri zaman damgası ve engelleme nedeni ile JSON Lines formatında denetim günlüğüne kaydedilir.

2. **Sandbox (İsteğe Bağlı Donanımsal/Kernel Düzeyinde İzolasyon Kafesi):**
   `sandbox.enabled: true` yapıldığında veya `!sandbox on` dendiğinde devreye girer.

| Mod / Sürücü | İzolasyon Gücü | Ağ İzolasyonu | Dosya Sistemi Sınırı | Desteklenen Platformlar |
| :--- | :---: | :---: | :---: | :--- |
| **Doğrudan Host (`sandbox.enabled: false`)** | **Doğrudan Güvenli Yürütme (Direct Safe Host)** | İzolasyonsuz (Host ağı; sahte proxy enjekte edilmez) | Yalnızca `chdir` kök dizin denetimi | Tüm platformlar (Sıfır ek yük) |
| **`bwrap` (Bubblewrap)** | **Güçlü (Strong OS Namespaces)** | Kernel `--unshare-net` | Host `/` Read-Only, workspace RW | Yalnızca Linux (OS-Gated) |
| **`docker`** | **Güçlü (Strong OCI Container)** | OCI Network namespace (`--network none`) | Mount sınırları, cgroups | Linux / macOS / Windows (Daemon) |
| **`podman`** | **Güçlü (Strong Rootless OCI)** | Rootless network namespace | Mount sınırları, cgroups | Linux / macOS / Windows (CLI) |
| **`firejail` (Eklenti)** | **Güçlü (Strong)** | Firejail `--net=none` | Whitelist/Blacklist profili | Linux (Tak-Çıkar Eklenti) |

> ℹ️ **Dürüst Ağ Politikası:** Rubik doğrudan host çalıştırmasında (`sandbox.enabled: false`) yanıltıcı `127.0.0.1:9999` proxy ortam değişkenleri enjekte etmez. Gerçek donanımsal/kernel düzeyinde ağ izolasyonu yalnızca sandbox açıkken (`bwrap` ile `--unshare-net`, `docker`/`podman` ile `--network none`) sağlanır.


# ------------------------------------------------------------------------------
# 📁 8. Bağlam Tarama ve Akıllı Sıkıştırma (Context Engine & Compactor)
# ------------------------------------------------------------------------------
context:
  include: []
  exclude:
    - ".git"
    - "node_modules"
    - "vendor/bundle"
    - "target"
    - ".rubik"

  # Bağlam sıkıştırma stratejisi:
  #   • &apos;hybrid&apos;             : Eski tool çıktılarını kırpar + en eski diyalogları özetler (Varsayılan)
  #   • &apos;prune_tool_results&apos; : Sadece eski araç çıktılarını budar
  #   • &apos;sliding_window&apos;     : Belirli bir pencere dışındaki turları atar
  #   • &apos;off&apos;                : Otomatik sıkıştırmayı kapatır
  compaction_strategy: hybrid
  max_tokens_ratio: 0.85
  tool_result_prune_chars: 1500
  preserve_first_n: 2
  preserve_last_n: 6
  safety_margin_tokens: 1024
  auto_recover_on_overflow: true
  # Plan 61: hatalı/iptal edilen turlar da [Turn failed/cancelled/incomplete]
  # damgasıyla konuşma penceresine ve oturum kaydına yazılır; böylece model
  # bir sonraki turda ne denendiğini hatırlar. false ile kapatılabilir.
  log_failed_turns: true

# ------------------------------------------------------------------------------
# 📺 9. Kullanıcı Arayüzü ve Verbosity (Ayrıntı Düzeyi)
# ------------------------------------------------------------------------------
ui:
  # Canlı ajan izleme ve adım çıktı ayrıntı düzeyi:
  #   • &apos;quiet&apos;   (0) : Sıfır ara gürültü, sadece nihai yanıt ve hatalar
  #   • &apos;normal&apos;  (1) : Temiz, estetik adım & araç özet çıktısı (Varsayılan)
  #   • &apos;verbose&apos; (2) : Detaylı JSON argümanları, ilk 5 satır çıktı önizlemesi ve [Thought]
  #   • &apos;debug&apos;   (3) : Tam ham araç I/O, milisaniyelik süreler ve teşhis
  verbosity: normal

# ------------------------------------------------------------------------------
# 🏢 10. Çoklu Çalışma Alanı, Harici Dizinler ve İzinler (Workspace Roots)
# ------------------------------------------------------------------------------
workspace:
  # İzin verilen ek kök dizinler (Monorepo, proto, shared-lib)
  additional_roots: []
  # Modelin sandbox komutlarıyla okuyabileceği harici izinli dizinler (Örn: /tmp, C:/temp)
  allowed_external_dirs: []
  # Ek kök dizinlere yazma izni verilsin mi? (false: Salt Okuma, true: Okuma-Yazma)
  allow_external_writes: false
  # Ek kök dizinler AST semantik grafı ve bağlam indeksine dahil edilsin mi?
  auto_index_additional: true

plugins:
  # Proje ve global dizinlerdeki (.rubik/plugins, ~/.rubik/plugins) drop-in eklentileri otomatik yükle.
  autoload_dropin: true
```

---

## 📚 İlgili Dokümantasyonlar

- 🌌 **Spatiotemporal Composability Protokolü:** [`AGENTS.md`](AGENTS.md)
- 🏗️ **22 Çekirdek Domain & Mimarî Şema:** [`ARCHITECTURE.md`](ARCHITECTURE.md)
- 🧰 **22 Yerleşik Ajan Aracı Kataloğu:** [`TOOLS.md`](TOOLS.md)
- 🧬 **LLM Otonom Öz-Evrim Rehberi:** [`SELF_EVOLUTION.md`](SELF_EVOLUTION.md)
- 🕹️ **Kapsamlı REPL Komut Kılavuzu:** [`COMMANDS.md`](COMMANDS.md)
