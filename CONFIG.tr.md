# ⚙️ Rubik Yapılandırma Kılavuzu (CONFIG.md)

> Bu belge, [`CONFIG.md`](CONFIG.md) dosyasının Türkçe çevirisidir ve güncelliğini yitirmiş olabilir; çelişki halinde İngilizce sürüm esastır.

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

  # Token tavanı kesintilerinde (finish_reason: length / max_tokens) otonom devam döngüsü:
  # Modelin düşünme süreci (thinking) veya uzun kod üretimi çıktıyı kestiğinde durmak yerine
  # otomatik olarak kaldığı noktadan devam etmesini sağlar.
  auto_continue_on_length: true

  # Otomatik devam için güvenlik sigortası (sonsuz döngüyü önleyen maksimum devam sayısı):
  max_auto_continues: 3

  # Anthropic Claude 3.7 Thinking modelleri için akıl yürütme bütçe oranı (0.0 - 0.8).
  # Bağlantı kopuktuğu için 2026-10-05'te tamamlandı: değer artık
  # istek opts'larına köprülenir. null = gönderilmez, adaptör kendi yedeğini kullanır
  # (llm/anthropic.rb içinde 0.5). Ayarlanırsa çıktı token bütçesinin belirtilen
  # yüzdesi düşünmeye gider:
  thinking_budget_ratio: null

  # OpenAI akıl yürütme modelleri (o1, o3-mini) için düşünme yoğunluğu:
  # 'low' | 'medium' | 'high'. null = gönderilmez. DİKKAT: null olmayan bir değer
  # openai_compatible'daki reasoning_model? saptamasını da tetikler — yalnızca
  # gerçekten akıl yürütme modeli için ayarlayın:
  reasoning_effort: null

  # Ağ zaman aşımları (saniye): open_timeout = TCP bağlantı kurulumu,
  # stream_timeout = akış başladıktan sonra parantez içinde (inter-chunk) sessizlik tavanı:
  open_timeout: 15
  stream_timeout: 120

  # Modelin akıl yürütme (reasoning) içeriğini yakala ve bağlamda tut:
  capture_reasoning: true

  # Varsayılan maksimum çıktı token bütçesi (modele göre dinamik akıllı tavanlar kullanılır):
  default_max_output_tokens: 4096

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
# Rubik'in terminal görüntüleme katmanı yenilendi: ⏺/⎿ ajan akış
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
  # Çok satırlı yapıştırma: iki readline dönüşü arasındaki süre bu pencerenin
  # (ms) altındaysa satırlar tek prompt turn'ünde birleştirilir. Elle yazılan satırlar
  # bu pencerenin üzerinde kaldığından asla birleştirilmez. Kesin Multi-line giriş için
  # REPL'de `!paste` komutunu kullanın (nokta ile bitirin).
  paste_join_window_ms: 120

  # Etkileşimli terminalde prompt başlamadan önceki süre (milisaniye).
  # Sıfır veya pozitif tam sayı; 0 kapatır, 2000 iki saniye bekletir.
  prompt_grace_window_ms: 1000
  # Sessiz bildirim tamponu: true yapıldığında arka plandaki alt ajan veya görev
  # bildirimleri doğrudan ekrana basılmaz, notice_inbox'ta biriktirilir ve yeni prompt
  # öncesinde topluca dökülür (!config set ui.quiet_notices true).
  quiet_notices: false

# 💡 DISPLAY KATMANI İPUÇLARI:
#   • `rubik --no-color`  : ANSI renk/banner/spinner'ı tamamen kapatır (CI uyumlu).
#   • `rubik --color`     : Boruya yönlendirilse bile renkleri zorlar (CLICOLOR_FORCE).
#   • NO_COLOR=1 ortam değişkeni de desteklenir (https://no-color.org).
#   • `!config set ui.color never -g` gibi tüm ui.* anahtarları REPL çalışırken
#     değiştirilebilir; display katmanı dinamik olarak yeniden inşa edilir (refresh_ui!).
#   • Spinner thread'i Runtime Context LIFO ters işlemiyle (ctx.on_dispose)
#     kapatılır; temizlik başarılı olduğunda oturum kapanışında durdurulur (AGENTS.md protokolü).
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

  # F. Yerel Ollama (native /api/chat protokolü)
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
# sticky: true iken serbest metin turları konuşma boyunca yerleşik
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

  # !goal otonom test-geçirme döngüsü için adım sayısı (Varsayılan: 100)
  goal_max_steps: 100

  # !plan plan üretimi adım sayısı (Varsayılan: 15)
  plan_max_steps: 15

  # Bütçe uyarı eşiği (0.75 = Bütçenin %75&apos;inde modele XML yakınsama uyarısı gönderir)
  warn_at_ratio: 0.75

  # Bütçe aşıldığında REPL'de otomatik devam sorma
  ask_continue_on_limit: true

  # !goal modunda kullanıcıya sormadan önce otonom uzatma hakkı (Varsayılan: 0; N = N kez +20 adım otomatik uzat)
  goal_auto_continue_limit: 0

  # !goal erken sonuçlanma koruması: canlı alt ajan varken maestro text-only
  # sonuç yazsa veya finish çağırsa döngü kapanmaz — alt ajanlar bitene dek
  # otomatik beklenir ve bildirimler enjekte edilir. Bu beklemenin tek seferde
  # üst sınırı (saniye; 0 = bloklamasız, anında yeniden-prompt; Varsayılan: 300)
  goal_wait_timeout: 300

# ------------------------------------------------------------------------------
# Merkezi Storage (rubik://storage sanal FS-DB)
# ------------------------------------------------------------------------------
storage:
  # storage veritabanı ve absorb açık mı (storage aracı + URI rotaları)
  enabled: true

  # Depo kökü (~ genişletilir). Projeler altında: <root>/<project>/store/
  root: ~/.rubik/rubikstorage

  # Proje slug'ı override'u; null ise worktree kök dizin adından türetilir
  project: null

  # true: yeni oturum dosyaları + subagent transcriptları storage köküne
  # absorbe edilir (worktree temiz kalır); eski .rubik/ konumları okunur.
  # Dikkat: değer yapılandırmada YOKSA legacy davranış korunur.
  absorb_artifacts: true

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

  # Devre kesici (circuit breaker): tekrarlayan tool hatalarında arka arkaya
  # `threshold` kez hata sonrası `cooldown_seconds` boyunca kesici açılır.
  # (V29 tasarım kararı: varsayılan kapalı — network_retry_count ve
  # subagents.error_wait_timeout hata yollarını zaten yönetir)
  circuit_breaker:
    enabled: false
    threshold: 5
    cooldown_seconds: 60

  # Native hız yolları: sistemdeki rg (ripgrep) ve git
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
# 🔌 5.1 Model Context Protocol (MCP) ve Spatiotemporal Araç Entegrasyonu
# ------------------------------------------------------------------------------
mcp:
  # MCP motorunu etkinleştir (true: Harici MCP sunucularını bağlar)
  enabled: true

  # Connect handshake timeout'u (saniye; initialize + tools/list). Yavaş
  # spawn'lı sunucular açılışı bu süre kadar bekletir; per-server "timeout"
  # bu değeri ezer. Geçersiz değer (sayı değil / <= 0) uyarıyla bir sonraki
  # kaynağa düşer — boot asla kötü bir knob'dan patlamaz.
  timeout: 10

  # tools/call gidiş-dönüş timeout'u (saniye). ping 5s sabittir (teknik probe).
  call_timeout: 30

  # MCP sunucularını arka planda yükle (nil = ortam-duyarlı: üretimde async,
  # RUBIK_TEST=1 altında senkron; true/false zorlar). Arka plan yüklemesi ilk
  # prompt'u bloklamaz; tamamlanma `!dmesg -s mcp` ile ve REPL notice'ıyla
  # görünür. Boot sürerken !mcp disable/remove kararı kullanıcı kararını ezer.
  async_load: null

  # Kayıtlı MCP sunucu tanımları (stdio transport); per-server "timeout"
  # global mcp.timeout'u ezer (yalnız connect handshake'i):
  servers:
    # filesystem:
    #   command: "npx"
    #   args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    #   enabled: true
    #   timeout: 30
    # fetch:
    #   command: "uvx"
    #   args: ["mcp-server-fetch"]
    #   enabled: true
    # NOT: Uzun satır içi yorumlayıcı payload'ları yerine dosya tabanlı
    # sunucu komutları tercih edin (`ruby -e '<çok satır>'`): Windows'ta uzun
    # çok satırlı `-e` çocukları sessizce yanıt vermez hale gelebiliyor
    # (issue #54). Sunucu betiğini bir dosyaya yazın ve `args` ile yolunu
    # verin.

# ------------------------------------------------------------------------------
# 📝 6. Bellek İçi Dosya Tamponu (In-Memory Buffer) ve Güvenlik
# ------------------------------------------------------------------------------
buffer:
  # Tampon düzenlemeleri bellekte aşamalar (stage); bir APPLY çalışana kadar
  # hiçbir şey diske gitmez. İki bağımsız anahtar uygulamayı belirler:
  #   auto_apply      — SİSTEMİN tamponu ne zaman otomatik boşaltacağı
  #   model_can_apply — MODELİN apply_buffer aracıyla erken boşaltma yetkisi
  #
  #   auto_apply          Otomatik boşaltma zamanı
  #   manual (varsayılan) yok — yalnızca açık apply (operatör !apply veya
  #                       model_can_apply izin veriyorsa apply_buffer aracı)
  #   on_test             !test / run_tests hemen öncesi
  #   on_finish           Görev tamamlandığında (finish aracı / subagent bitişi)
  #   always              Her tampon yazımından hemen sonra
  #
  # model_can_apply: false, model düzlemi için insan incelemesi modudur:
  # apply_buffer aracı reddeder ve tamponu diske yalnızca operatör !apply
  # komutu yazar. Tam inceleme kapısı için auto_apply: manual ile birleştirin —
  # diğer auto_apply modları kendi tetikleyicilerinde yine otomatik boşaltır
  # (anahtar modeli kapılar, politikayı değil). Varsayılan true kalır: mevcut
  # akışlar buna dayanır ve false açık opt-out'tur.
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

  # Atomiklik: her dosya atomik yazılır (geçici dosya + rename), ancak
  # çok dosyalı apply bir işlem (transaction) DEĞİLDİR. Yazım sırasında hata
  # olursa önce yazılan dosyalar diskte kalır; hata/rapor applied, failed,
  # still-dirty ve conflict-skipped girdilerini adlandırır ve yeniden deneme
  # yalnızca kalan kirli dosyaları yazar.

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
  shell: auto                   # 'auto', 'bash', 'pwsh', 'cmd' veya 'sh'

security:
  # Engellenen dosya yazma, kök ekleme ve tehlikeli komut girişimlerinin kaydedildiği denetim günlüğü.
  # Açıkça `null`/boş değer = denetim KAPALI (Guard#for_config); oturum sırasında
  # !config set ile canlı değiştirilebilir (Plan: guard-policy-unification).
  audit_log_path: ~/.rubik/audit.log

# `sandbox.shell` — run_command komutlarının hangi kabukla çalışacağı.
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
   - **172 CLI YAML Kural Veritabanı:**
     172 popüler CLI aracı (`lib/rubik/security/classifier/commands/*.yaml`) için tanımlanmış kurallarla alt komutlar, argümanlar ve bayraklar semantik kategorilere (`read`, `write`, `execute`, `network`, `destructive`, `elevated` vb.) ayrılır.
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

  # Alt ajanın bağlam penceresi yedeği (token): yönlendirilen model kaydında
  # context_limit yoksa bu değer kullanılır (subagent/instance.rb, supervisor.rb):
  max_tokens: 32768

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
  # Acil kesme stratejisi: yapısal sıkıştırma/taşma kurtarma yetmediğinde
  # devreye giren EmergencyCompactor'ın kör kesme katmanının stratejisi.
  #   • &apos;head_tail&apos; : Mesaj başı + sonu korunur, orta atılır (Varsayılan)
  #   • &apos;head_only&apos; : Yalnızca mesaj başı korunur
  #   • &apos;tail_only&apos; : Yalnızca mesaj sonu korunur
  # Geçersiz değerler sessizce &apos;head_tail&apos;e döner; compaction_strategy&apos;nin
  # yönettiği yapısal katmanı DEĞİL, yalnızca acil kesme katmanını etkiler.
  emergency_truncate_strategy: head_tail
  auto_recover_on_overflow: true
  # Hatalı/iptal edilen turlar da [Turn failed/cancelled/incomplete]
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
  # Başlangıçta yüklenecek ek eklenti dosya yolları (mutlak veya kök-göreli):
  load: []
  # Eklenti adı takma adları (alias => gerçek eklenti adı):
  aliases: {}

skills:
  # Agent Skills altyapısını (agentskills.io) etkinleştir:
  enabled: true
  # Ek keşif dizinleri (mutlak veya kök-göreli; .rubik/skills ve ~/.rubik/skills
  # her zaman taranır):
  paths: []
  # Keşiften hariç tutulacak skill adları:
  disabled: []
  # Skill gövdesinin (SKILL.md body) bağlama yüklenmeden önceki karakter sınırı —
  # tools.max_output_chars altında kalması için küçük tutulur:
  max_body_chars: 8000

project:
  # Test/derleme komutu (örn. "bundle exec rake test"); nil = adaptör otomatik saptar:
  test_command: null

# ------------------------------------------------------------------------------
# 🧮 10-b. AST Isınma ve Test Çalıştırıcıları (AST Warm-up & Test Runners)
# ------------------------------------------------------------------------------
ast:
  # REPL açılışında AST semantik grafı arka plan fiber'ında ısıtılır
  # (repl/lifecycle.rb warm_up!). null = ortama duyarlı varsayılan (üretimde
  # true, RUBIK_TEST=1 altında false); true/false ile zorlayabilirsiniz:
  async_warm: null

test:
  # run_tests adaptörünün çağıranın süre vermediği durumlardaki duvar saati
  # tavanı (saniye, adapter/base.rb):
  timeout: 30
  # Dil başına test çalıştırıcı override'u; anahtar = dil anahtarı
  # (örn. ruby, python, javascript), değer = tam komut. Boş = Discovery
  # otomatik saptar (tools/builtins/exec.rb synthesize_adapter):
  runners: {}

# ------------------------------------------------------------------------------
# 👥 11. Alt Ajan Orkestrasyonu ve Süreç Ağacı
# ------------------------------------------------------------------------------
subagents:
  # Eşzamanlı çalışabilecek maksimum alt ajan sayısı (concurrency guard):
  max_concurrency: 10
  # Maksimum iç içe derinlik sınırı (recursion depth limit):
  max_depth: 2
  # Alt ajan başına varsayılan maksimum adım bütçesi:
  default_max_steps: 88
  # Alt ajan başarıyla tamamlandığında veya test öncesi tamponu otomatik diske yaz:
  auto_apply_buffer: true
  # Boşta bekleyen ajanı (agent-0) subagent tamamlanma/duraklama/
  # hata/mesaj/soru olaylarıyla otomatik uyandır (reactive wakeup); false = bildirimler
  # yalnızca bir sonraki kullanıcı turunda görülür (eski davranış):
  reactive_wakeup: true
  # Alt ajanın ask_question ile maestro'ya sorduğu soru için bloklı bekleme süresi
  # (saniye). Bu sürede send_message ile cevap gelmezse alt ajan "en iyi takdirinle
  # devam et" rehberiyle kaldığı adımdan sürer:
  question_timeout: 300
  # Özenli tasfiye: bitmiş (completed/failed) alt ajan bu grace süresi (saniye)
  # sonunda otomatik reap edilir — bellekteki history serbest bırakılır, dayanıklı
  # transkript ve storage indeksi kalır, durum mezar taşından sorgulanabilir
  # kalır. 0 = otomatik tasfiye kapalı (yalnız 'reap' aksiyonu ile elle):
  reap_finished_after: 300
  # Sorgulanabilir mezar taşı (tombstone) sayısı sınırı — aşılınca en eski
  # mezar taşı FIFO ile evict edilir:
  tombstone_limit: 25
  # Maestro kapısı (kullanıcı kararı 2026-10-01): maestro HER modda saf orkestratördür —
  # kök ajanda write_file/replace_file_content/run_command/run_tests ve manage_task
  # (yalnız 'start') YÜRÜTÜLMEDEN reddedilir, hata sonucu subagent'a yönlendirir.
  # false = doktrin yalnız prompt düzeyinde kalır, runtime kapısı kapalı
  # (operatör-only: ajan kendi üzerinden açamaz, yalnız !config ile):
  maestro_gate: true
  # Eşzamanlı provider isteği kapısı (ConcurrencyGate) — subagent sürüleri tek
  # seferde en fazla bu kadar paralel model isteği açar:
  provider_concurrency: 2
  # Bütçe duraklamasında (WAITING_BUDGET) grant bekleme süresi (sn) — bu sürede
  # extend gelmezse alt ajan budget-exhausted ile finalleşir:
  budget_wait_timeout: 180
  # Provider ağ hatasında yeniden deneme sayısı ve üstel backoff tabanı (sn);
  # denemeler tükenirse hata yüzeye çıkar:
  network_retry_count: 3
  network_backoff_base: 0.5
  # Hata duraklamış (error-paused) alt ajan için otomatik bekleme süresi (sn) —
  # bu sürede sürdürme gelmezse failed ile finalleşir:
  error_wait_timeout: 300
  # Ağ hatasında alt ajanı hata duraklamasına al (true); false = doğrudan düşür:
  auto_pause_on_network_error: true
  # Vakanüvis arka plan kronikcisi (plan 2026-10-04 K1-K9 + v2 2026-10-06) —
  # subagents.vakanuvis.* ailesi operatör-only'dir (yukarıdaki subagents.*
  # kuralı devralır):
  #   enabled     : Düzlem 1 (deterministik annal/memory/wiki harness) kurulsun mu
  #   distiller   : Düzlem 2 — LLM'li damıtıcı subagent doğumu (token üst sınırı
  #                 flush_events x max_steps ile bağlanır); v2'de toplu doğum
  #                 yalnızca kalıcı içerik (kart/sayfa/not satırı) değiştiyse
  #                 gerçekleşir — saf turn akışı damıtıcı yakmaz
  #   max_steps   : damıtıcı başına adım bütçesi
  #   flush_events: bu kadar olay birikince flush (süpürme + home yeniden
  #                 hesap + kirliyse damıtıcı doğumu) eşiği
  #   model       : damıtıcı modeli (nil = root provider)
  #   retention   : forget politikası — supersede (status+işaretle, iz bırakır)
  #                 | purge (satırı sert siler)
  #   root_turns  : REPL kök-turn'leri de annal'a yazılsın mı (root-turn planı
  #                 2026-10-04; false = :turn_finished aboneliği hiç kurulmaz)
  vakanuvis:
    enabled: true
    distiller: true
    max_steps: 8
    flush_events: 10
    model: null
    retention: supersede
    root_turns: true
```

---

## 📚 İlgili Dokümantasyonlar

- 🌌 **Spatiotemporal Composability Protokolü:** [`AGENTS.md`](AGENTS.md)
- 🏗️ **27 Çekirdek Domain & Mimarî Şema:** [`ARCHITECTURE.md`](ARCHITECTURE.md)
- 🧰 **33 Yerleşik Ajan Aracı Kataloğu:** [`TOOLS.md`](TOOLS.md)
- 🧬 **LLM Otonom Öz-Evrim Rehberi:** [`SELF_EVOLUTION.md`](SELF_EVOLUTION.md)
- 🕹️ **Kapsamlı REPL Komut Kılavuzu:** [`COMMANDS.md`](COMMANDS.md)
