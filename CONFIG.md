# ⚙️ Rubik Yapılandırma Kılavuzu (CONFIG.md)

Bu belge, **Rubik AI Coding Agent**'ın yapılandırma hiyerarşisini, tüm ayar seçeneklerini (knobs), dinamik LLM sağlayıcılarını (providers), modellerin bağlam limitlerini (context limits), bellek içi tampon (buffer) politikalarını ve REPL komutlarını detaylandırır.

---

## 🏛️ Yapılandırma Hiyerarşisi ve Öncelik Sırası

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

---

## 📄 Tam Açıklamalı Yapılandırma Şablonu

```yaml
# ==============================================================================
# 🎲 Rubik Configuration File (.rubik/config.yml veya ~/.rubik/config.yml)
# ==============================================================================

# ------------------------------------------------------------------------------
# 🌐 1. Dinamik LLM Sağlayıcıları ve Özel Endpoint'ler (Providers Registry)
# ------------------------------------------------------------------------------
# İstediğiniz sayıda OpenAI-uyumlu (OpenRouter, Groq, DeepSeek, vLLM, LMStudio vb.),
# Ollama veya Anthropic sağlayıcısını ve modellerini buraya tanımlayabilirsiniz.
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

  # C. Groq (Ultra Yüksek Hız)
  groq:
    type: openai_compatible
    endpoint: https://api.groq.com/openai/v1/chat/completions # (veya sadece https://api.groq.com/openai/v1)
    api_key_env: GROQ_API_KEY
    models:
      - name: llama-3.3-70b-versatile
        context_limit: 128000
      - name: deepseek-r1-distill-llama-70b
        context_limit: 128000

  # D. Cline API Gateway
  cline:
    type: openai_compatible
    endpoint: https://api.cline.bot/api/v1/chat/completions # (veya sadece https://api.cline.bot)
    api_key_env: CLINE_API_KEY
    models:
      - name: cline-pass/deepseek-v4-flash
        context_limit: 64000
      - name: deepseek/deepseek-r1
        context_limit: 128000

  # E. Yerel vLLM / LMStudio / Ollama OpenAI Uyumluluk Sunucusu
  local_vllm:
    type: openai_compatible
    endpoint: http://localhost:8000/v1/chat/completions # (veya sadece http://localhost:8000)
    models:
      - name: Qwen/Qwen2.5-Coder-32B-Instruct
        context_limit: 32768

# ------------------------------------------------------------------------------
# 🧠 2. Model ve Çoklu Rol Yönlendirme (Multi-Role Router)
# ------------------------------------------------------------------------------
model:
  provider: openrouter          # 'openrouter', 'cline', 'deepseek', 'groq', 'anthropic', 'openai', 'ollama'
  name: deepseek/deepseek-chat  # Model adı
  endpoint: https://openrouter.ai/api/v1/chat/completions

models:
  # Varsayılan Rol (Genel eşli kodlama, analiz ve sohbet)
  default:
    provider: openrouter
    name: deepseek/deepseek-chat

  # Hızlı Rol (!plan üretimi veya hafif bağlam sorguları)
  fast:
    provider: groq
    name: llama-3.3-70b-versatile

  # Gelişmiş Rol (Karmaşık refactor veya uzun süreli !goal otonom döngüsü)
  advanced:
    provider: openrouter
    name: anthropic/claude-3.7-sonnet

# Router Modu: 'auto' (görev tipine göre otomatik seçer) veya 'manual' (default model kullanılır)
router:
  mode: auto

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

  # Bütçe uyarı eşiği (0.75 = Bütçenin %75'inde modele XML yakınsama uyarısı gönderir)
  warn_at_ratio: 0.75

  # Bütçe aşıldığında REPL'de otomatik devam sorma
  ask_continue_on_limit: true

# ------------------------------------------------------------------------------
# 🛠️ 4. Tool Girdi / Çıktı ve Akıllı Bağlam Kırpma (Tool I/O & Truncation)
# ------------------------------------------------------------------------------
tools:
  # Tek bir tool çıktısının maksimum karakter sınırı (Bağlam patlamasını önler)
  max_output_chars: 12000

  # Maksimum satır sınırı
  max_output_lines: 300

  # Kırpma stratejisi: 'head_tail' (baş ve son satırları korur), 'head_only', 'tail_only'
  truncation_strategy: head_tail

  # Tool yürütüm zaman aşımı (saniye)
  timeout_seconds: 30

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
  #   • 'manual'    : Değişiklikler yalnızca '!apply' komutuyla diske yazılır (Varsayılan & En Güvenli)
  #   • 'on_test'   : '!test' komutu çalıştırılmadan hemen önce tamponu diske uygular
  #   • 'on_finish' : Görev başarıyla tamamlandığında tamponu diske uygular
  #   • 'always'    : Model tampona yazdığı anda anında diske kaydeder
  auto_apply: manual

  # Modelin apply_buffer aracını kendi inisiyatifiyle çağırabilmesine izin ver
  model_can_apply: true

  # REPL promptunda kirli tampon dosya sayısını göster (örn: rubik (app) [DIRTY: 2 ✎] >)
  prompt_indicator: true

  # Kirli tampon varken REPL'den çıkış yapıldığında kullanıcıyı uyar
  exit_guard: true

  # Belirli sayıda tur boyunca unapplied tampon varsa hatırlatıcı mesaj göster
  reminder_interval: 3

# ------------------------------------------------------------------------------
# 🛡️ 7. Güvenlik, Sandbox ve Süreç İzolasyonu
# ------------------------------------------------------------------------------
sandbox:
  driver: auto                  # 'auto', 'docker', 'wasm', veya 'process'
  image: rubik-sandbox:latest
  timeout_seconds: 15
  memory_limit_mb: 512
  cpus: "1.0"
  allow_network: false
  wasm:
    runtime: wasmtime

# Kendi kendini onarma döngüsü maksimum adım sayısı
repair:
  max_attempts: 3

# Ağ erişim izni (Global varsayılan)
network:
  allow: false

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
  #   • 'hybrid'             : Eski tool çıktılarını kırpar + en eski diyalogları özetler (Varsayılan)
  #   • 'prune_tool_results' : Sadece eski araç çıktılarını budar
  #   • 'sliding_window'     : Belirli bir pencere dışındaki turları atar
  #   • 'off'                : Otomatik sıkıştırmayı kapatır
  compaction_strategy: hybrid
  max_tokens_ratio: 0.85
  tool_result_prune_chars: 1500
  preserve_first_n: 2
  preserve_last_n: 6
  safety_margin_tokens: 1024
  auto_recover_on_overflow: true

# ------------------------------------------------------------------------------
# 📺 9. Kullanıcı Arayüzü ve Verbosity (Ayrıntı Düzeyi)
# ------------------------------------------------------------------------------
ui:
  # Canlı ajan izleme ve adım çıktı ayrıntı düzeyi:
  #   • 'quiet'   (0) : Sıfır ara gürültü, sadece nihai yanıt ve hatalar
  #   • 'normal'  (1) : Temiz, estetik adım & araç özet çıktısı (Varsayılan)
  #   • 'verbose' (2) : Detaylı JSON argümanları, ilk 5 satır çıktı önizlemesi ve [Thought]
  #   • 'debug'   (3) : Tam ham araç I/O, milisaniyelik süreler ve teşhis
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
```

---

## 🕹️ REPL Üzerinden Canlı Yapılandırma ve 3 Kademeli Kalıcılık Kapsamı (Scoping)

Rubik REPL içerisindeyken ayarları dosya açmadan anlık olarak değiştirebilirsiniz. Yapılan değişikliklerin kalıcılık düzeyi komut sonundaki bayraklara göre belirlenir ve işlem sonunda anında geri bildirim verilir:

| Kapsam (Scope) | Bayrak (Flag) | Kalıcılık Durumu | Geri Bildirim Bildirimi |
| :--- | :--- | :--- | :--- |
| **Session Only** | *(Bayraksız)* veya `-s` / `--session` | Yalnızca o anki oturum boyunca bellekte aktiftir; diske yazılmaz. | `[Session only]` |
| **Project Level** | `-p` veya `--project` | Proje kökündeki `.rubik/config.yml` içine kalıcı kaydedilir. | `[Project level (.rubik/config.yml)]` |
| **System Level** | `-g` veya `--global` | Kullanıcı ev dizinindeki `~/.rubik/config.yml` içine kalıcı kaydedilir. | `[System level (~/.rubik/config.yml)]` |

---

### 1. Dinamik Sağlayıcı & Model Yönetimi (CRUD - `!provider` / `!providers`)
```bash
# READ (Listeleme):
!providers                               # Kayıtlı tüm LLM sağlayıcılarını, endpoint'lerini ve modellerini listeler
!provider list                           # Sağlayıcı özet tablosunu gösterir

# CREATE (Ekleme):
!provider add deepseek openai_compatible https://api.deepseek.com/chat/completions --key=sk-your-key --model=deepseek-coder --context=64000 -g
!provider add openrouter openai_compatible https://openrouter.ai/api/v1/chat/completions --key-env=OPENROUTER_API_KEY --model=anthropic/claude-3.7-sonnet --context=200000 -g
!provider add-model openrouter deepseek/deepseek-v4-flash --context=64000 -g # Sağlayıcıya yeni model tanımlar

# UPDATE (Güncelleme):
!provider set deepseek key sk-new-secret-key -g   # API anahtarını günceller
!provider set deepseek endpoint https://api.deepseek.com/chat/completions -g # Endpoint'i günceller
!provider set-context openrouter deepseek/deepseek-v4-flash 131072 -g # Belirli modelin context limitini günceller
!provider add-model deepseek deepseek-coder --context=128000 -g       # Modeli context limitiyle günceller

# DELETE (Silme):
!provider remove-model deepseek deepseek-chat -g  # Belirli bir modeli sağlayıcıdan siler
!provider remove openrouter -g                    # Sağlayıcıyı tamamen siler
```

### 2. Model, Rol ve Context Limiti Yönetimi (`!model`)
```bash
!model                                                      # Mevcut model rollerini, context limitlerini ve router durumunu listeler
!model openrouter deepseek/deepseek-v4-flash                # Sağlayıcı ve modeli ayrı argümanlarla belirleme (Önerilen)
!model set default openrouter deepseek/deepseek-v4-flash    # Varsayılan role atama
!model set fast openrouter mistralai/mistral-7b-instruct    # Hızlı role atama
!model set advanced openrouter anthropic/claude-3.7-sonnet  # Gelişmiş role atama
!model openrouter/cline-pass/deepseek-v4-flash              # Bölülü (/) formatta belirleme
!model route auto                                           # Otomatik akıllı görev yönlendirmesini açar

# CONTEXT LIMIT DEĞİŞTİRME:
!model context 65536                                        # Aktif varsayılan (default) modelin context limitini değiştirir
!model context fast 32768                                   # Hızlı (fast) rolündeki modelin context limitini değiştirir
!model context advanced 200000                              # Gelişmiş (advanced) modelin context limitini değiştirir
!model context cline cline-pass/deepseek-v4-flash 128000    # Belirli bir sağlayıcı/modelin context limitini günceller
```

### 3. Agentic Adım Bütçesi (`!steps`)
```bash
!steps                                   # Aktif adım bütçesi ve uyarı eşiklerini gösterir
!steps 50                                # Standart görev bütçesini 50 adıma çıkarır
!steps goal 100                          # !goal otonom döngü bütçesini 100 adıma çıkarır
!steps plan 20 -p                        # Projeye özel plan adım bütçesini 20 yapar
```

### 4. LSP Kontrolleri (`!lsp`)
```bash
!lsp status                              # Dil sunucularının aktiflik ve PID durumunu gösterir
!lsp on                                  # LSP motorunu açar
!lsp off                                 # LSP motorunu kapatır ve tüm çalışan süreçleri durdurur
!lsp start rust                          # Belirli bir dil sunucusunu manuel başlatır
!lsp stop rust                           # Belirli bir dil sunucusunu durdurur
!lsp diag                                # Tüm projedeki derleyici hatalarını listeler
!lsp diag src/main.rs                    # Belirli bir dosyadaki hataları listeler
```

### 5. Tampon Politikası (`!autoapply`)
```bash
!autoapply status                        # Tampon ayarlarını ve kirli dosya durumunu gösterir
!autoapply manual                        # Yalnızca !apply ile kaydet
!autoapply on_test                       # Testten önce otomatik uygula
!autoapply always                        # Her yazımda anında diske uygula
```

### 6. Genel Ayarlar (`!config`)
```bash
!config path                             # Aktif global ve proje ayar dosyası yollarını gösterir
!config get buffer.auto_apply            # Belirli bir ayarın değerini okur
!config set buffer.auto_apply on_test    # Global config'e kaydeder
!config set buffer.auto_apply on_test -p # Proje config'ine (.rubik/config.yml) kaydeder
```

### 7. Spatiotemporal Runtime ve Fiber Denetimi (`!runtime` / `!fibers` / `!services`)
```bash
!runtime                                 # Aktif coeffect servisleri, fiber durumları ve LIFO ters işlem derinliğini gösterir
!fibers                                  # Yalnızca çalışan, bekleyen ve hata alan fiberlerin detaylı durumunu listeler
!services                                # Context'e sağlanan kayıtlı çekirdek servisleri listeler
```

### 8. Verbosity ve Canlı Ajan İzleme (`!verbosity` / `!verbose`)
```bash
!verbosity                               # Aktif ayrıntı düzeyini (quiet/normal/verbose/debug) gösterir
!verbosity quiet                         # Sessiz mod (0)
!verbosity normal                        # Standart mod (1)
!verbosity verbose                       # Ayrıntılı mod (2)
!verbosity debug                         # Hata ayıklama modu (3)
!verbosity verbose -p                    # Projeye özel (.rubik/config.yml) olarak kaydeder
!verbose                                 # normal ve verbose arasında anında geçiş yapar (toggle)
!verbose on                              # Ayrıntılı modu açar
!verbose off                             # Ayrıntılı modu kapatır (normal moda döner)
```

### 9. Çoklu Çalışma Alanı ve Harici Dizin İzinleri (`!workspace` / `!roots` / `!allow`)
```bash
!workspace                               # Yapılandırılmış birincil ve ek kök dizinleri listeler
!workspace list                          # Kök dizin durumunu ve izinlerini döker
!roots list                              # !workspace list ile aynıdır
!workspace add ../shared-lib             # Salt-okunur ek kök dizin ekler ve AST indeksine dahil eder
!workspace add ../core-contracts --rw    # Yazılabilir (--rw) modda ek kök dizin ekler
!workspace add ../proto --rw -p          # Projeye özel (.rubik/config.yml) kalıcı kaydeder
!workspace remove ../shared-lib          # Ek kök dizini çalışma alanından çıkarır
!allow /tmp                              # Sandbox'ın /tmp dizinine erişmesine izin verir
!allow-dir C:/workspace/build            # Windows harici derleme dizinine erişim izni verir
```
