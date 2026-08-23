# ⚙️ Rubik Yapılandırma Kılavuzu (CONFIG.md)

Bu belge, **Rubik AI Coding Agent**'ın yapılandırma hiyerarşisini, tüm ayar seçeneklerini (knobs), dinamik LLM sağlayıcılarını (providers), modellerin bağlam limitlerini (context limits) ve REPL komutlarını detaylandırır.

---

## 🏛️ Yapılandırma Hiyerarşisi ve Öncelik Sırası

Rubik, yapılandırmayı katmanlı bir modelde birleştirir (merge):

```text
┌─────────────────────────────────────────────────────────────┐
│ 1. Varsayılan Çekirdek Ayarlar (Default Config)             │
│    └─► 2. Global Kullanıcı Ayarları (~/.rubik/config.yml)   │
│         └─► 3. Proje Özel Ayarları (.rubik/config.yml)      │
│              └─► 4. REPL Çalışma Zamanı Parametreleri       │
└─────────────────────────────────────────────────────────────┘
```

- **Global Yapılandırma:** `~/.rubik/config.yml` (Tüm projelerde geçerli ortak ayarlar).
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
# İstediğiniz sayıda OpenAI-uyumlu (vLLM, LMStudio, OpenRouter, Groq, DeepSeek vb.),
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
      - name: anthropic/claude-3.5-sonnet
        context_limit: 200000
      - name: meta-llama/llama-3.3-70b-instruct
        context_limit: 128000
      - name: qwen/qwen-2.5-coder-32b-instruct
        context_limit: 32768

  # B. DeepSeek
  deepseek:
    type: openai_compatible
    endpoint: https://api.deepseek.com/chat/completions
    api_key_env: DEEPSEEK_API_KEY
    models:
      - name: deepseek-chat
        context_limit: 64000
      - name: deepseek-reasoner
        context_limit: 64000

  # C. Groq (Ultra Yüksek Hız)
  groq:
    type: openai_compatible
    endpoint: https://api.groq.com/openai/v1/chat/completions
    api_key_env: GROQ_API_KEY
    models:
      - name: llama-3.3-70b-versatile
        context_limit: 128000

  # D. Yerel vLLM / LMStudio / Ollama OpenAI Uyumluluk Sunucusu
  local_vllm:
    type: openai_compatible
    endpoint: http://localhost:8000/v1/chat/completions
    models:
      - name: Qwen/Qwen2.5-Coder-32B-Instruct
        context_limit: 32768

# ------------------------------------------------------------------------------
# 🧠 2. Model ve Çoklu Rol Yönlendirme (Multi-Role Router)
# ------------------------------------------------------------------------------
model:
  provider: ollama              # 'ollama', 'openrouter', 'groq', 'deepseek', 'anthropic', 'openai'
  name: gpt-oss:120b-cloud      # Model adı
  host: http://localhost:11434  # Host / Endpoint URL'i

models:
  # Varsayılan Rol (Genel eşli kodlama, analiz ve sohbet)
  default:
    provider: ollama
    name: gpt-oss:120b-cloud
    host: http://localhost:11434

  # Hızlı Rol (!plan üretimi veya hafif bağlam sorguları)
  fast:
    provider: ollama
    name: fast-coder:3b
    host: http://localhost:11434

  # Gelişmiş Rol (Karmaşık refactor veya uzun süreli !goal otonom döngüsü)
  advanced:
    provider: anthropic
    name: claude-3-5-sonnet
    host: http://localhost:11434

# Router Modu: 'auto' (görev tipine göre otomatik seçer) veya 'manual' (default model kullanılır)
router:
  mode: manual

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
    ruby: "typeprof --lsp"
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

  # REPL promptunda kirli tampon dosya sayısını göster (örn: rubik [DIRTY: 2 ✎] >)
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

# Ağ erişim izni
network:
  allow: false

# ------------------------------------------------------------------------------
# 📁 8. Bağlam Tarama Filtreleri (Context Engine)
# ------------------------------------------------------------------------------
context:
  include: []
  exclude:
    - ".git"
    - "node_modules"
    - "vendor/bundle"
    - "target"
    - ".rubik"
```

---

## 🕹️ REPL Üzerinden Canlı Yapılandırma Komutları

Rubik REPL içerisindeyken ayarları dosya açmadan anlık olarak değiştirebilir ve `--project` veya `--global` parametreleriyle kalıcı kaydedebilirsiniz:

### 1. Dinamik Sağlayıcı & Model Yönetimi (CRUD - `!provider` / `!providers`)
```bash
# READ (Listeleme):
!providers                               # Kayıtlı tüm LLM sağlayıcılarını, endpoint'lerini ve modellerini listeler
!provider list                           # Sağlayıcı özet tablosunu gösterir

# CREATE (Ekleme):
!provider add deepseek openai_compatible https://api.deepseek.com/v1/chat/completions --key=sk-your-key --model=deepseek-coder --context=64000
!provider add openrouter openai_compatible https://openrouter.ai/api/v1/chat/completions --key-env=OPENROUTER_API_KEY --model=anthropic/claude-3.5-sonnet --context=200000
!provider add-model deepseek deepseek-chat --context=64000  # Mevcut sağlayıcıya yeni model ekler

# UPDATE (Güncelleme):
!provider set deepseek key sk-new-secret-key   # API anahtarını günceller
!provider set deepseek endpoint https://api.deepseek.com/v2/chat/completions # Endpoint'i günceller
!provider add-model deepseek deepseek-coder --context=128000 # Model context limitini günceller

# DELETE (Silme):
!provider remove-model deepseek deepseek-chat  # Belirli bir modeli sağlayıcıdan siler
!provider remove openrouter                    # Sağlayıcıyı tamamen siler
```

### 2. Model ve Rol Yönetimi (`!model`)
```bash
!model                                   # Mevcut model rollerini, context limitlerini ve router durumunu listeler
!model ollama/qwen2.5-coder:7b           # Varsayılan modeli anında değiştirir
!model set fast groq/llama-3.3-70b-versatile  # Hızlı rol modelini ayarlar
!model set advanced openrouter/anthropic/claude-3.5-sonnet -p # Projeye özel gelişmiş model belirler
!model route auto                        # Otomatik akıllı görev yönlendirmesini açar
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
