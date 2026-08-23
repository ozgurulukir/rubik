# ⚙️ Rubik Yapılandırma Kılavuzu (CONFIG.md)

Bu belge, **Rubik AI Coding Agent**'ın yapılandırma hiyerarşisini, tüm ayar seçeneklerini (knobs) ve REPL üzerinden dinamik yapılandırma komutlarını detaylandırır.

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
# 🧠 1. Model ve Çoklu Rol Yönlendirme (Multi-Role Router)
# ------------------------------------------------------------------------------
model:
  provider: ollama              # 'ollama', 'anthropic', 'openai', 'gemini'
  name: gpt-oss:120b-cloud      # Model adı
  host: http://localhost:11434  # Ollama host URL'i

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
# ⚡ 2. Language Server Protocol (LSP) ve Canlı Derleyici Teşhisi
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
# 📝 3. Bellek İçi Dosya Tamponu (In-Memory Buffer) ve Güvenlik
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
# 🛡️ 4. Güvenlik, Sandbox ve Süreç İzolasyonu
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
# 📁 5. Bağlam Tarama Filtreleri (Context Engine)
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

### 1. Genel Ayarlar (`!config`)
```bash
!config path                             # Aktif global ve proje ayar dosyası yollarını gösterir
!config get buffer.auto_apply            # Belirli bir ayarın değerini okur
!config set buffer.auto_apply on_test    # Global config'e kaydeder
!config set buffer.auto_apply on_test -p # Proje config'ine (.rubik/config.yml) kaydeder
```

### 2. Model ve Rol Yönetimi (`!model`)
```bash
!model                                   # Mevcut model rollerini ve router durumunu listeler
!model ollama/qwen2.5-coder:7b           # Varsayılan modeli anında değiştirir
!model set fast ollama/fast-coder:3b     # Hızlı rol modelini ayarlar
!model set advanced anthropic/claude-3-5-sonnet -p # Projeye özel gelişmiş model belirler
!model route auto                        # Otomatik akıllı görev yönlendirmesini açar
```

### 3. LSP Kontrolleri (`!lsp`)
```bash
!lsp status                              # Dil sunucularının aktiflik ve PID durumunu gösterir
!lsp on                                  # LSP motorunu açar
!lsp off                                 # LSP motorunu kapatır ve tüm çalışan süreçleri durdurur
!lsp start rust                          # Belirli bir dil sunucusunu manuel başlatır
!lsp stop rust                           # Belirli bir dil sunucusunu durdurur
!lsp diag                                # Tüm projedeki derleyici hatalarını listeler
!lsp diag src/main.rs                    # Belirli bir dosyadaki hataları listeler
```

### 4. Tampon Politikası (`!autoapply`)
```bash
!autoapply status                        # Tampon ayarlarını ve kirli dosya durumunu gösterir
!autoapply manual                        # Yalnızca !apply ile kaydet
!autoapply on_test                       # Testten önce otomatik uygula
!autoapply always                        # Her yazımda anında diske uygula
```
