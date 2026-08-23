# 30 — Dinamik ve Yapılandırılabilir LLM Sağlayıcıları (Provider Registry), Özel Endpoint'ler ve Model Bağlam Limiti (Context Limit) Yönetimi

**Durum:** 📋 **Planlandı** · **Zorluk:** Orta–Zor · **Öneri kaynağı:** Kullanıcı Talebi & Mimari İstişare · **Faz:** 5 (Genişletilebilir LLM Katmanı)  
**İlgili Planlar:** [09 — LLM Sağlayıcı Soyutlaması](09-llm-saglayici-soyutlamasi.md) · [17 — Native Tool-Calling & Model Router](17-native-tool-calling-ve-model-yonlendirme.md) · [22 — LLM Durumsal Farkındalık](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md) · [25 — Yapılandırma Kalıcılığı](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md) · [CONFIG.md](../CONFIG.md) · [Index](index.md)

---

## 🎯 1. Mevcut Durum Analizi & Problem

Mevcut durumda Rubik LLM katmanı (`lib/rubik/llm/`):
- `Registry` içinde yalnızca 3 sabit sınıfı (`OllamaProvider`, `OpenAIProvider`, `AnthropicProvider`) barındırmaktadır.
- `OpenAIProvider`, doğrudan `https://api.openai.com/v1/chat/completions` adresine ve `OPENAI_API_KEY` değişkenine sabit kodlanmıştır (hardcoded).
- Yerel veya harici **OpenAI-uyumlu (OpenAI-compatible)** sunucular (örn: **vLLM, LMStudio, OpenRouter, Groq, DeepSeek, Together, Mistral, LocalAI**) için özel endpoint ve header desteği bulunmamaktadır.
- Modellerin **bağlam penceresi limitleri (context window / token limit)** (`32k`, `128k`, `200k` vb.) yapılandırılamamakta ve bağlam yöneticisi tarafından izlenememektedir.

---

## 💡 2. Hedeflenen Çözüm & Mimari Tasarım

Kullanıcıların tek bir YAML bloğuyla veya REPL komutuyla herhangi bir yeni LLM sağlayıcısını ve modellerini sisteme ekleyebilmesini sağlayan **Dinamik Sağlayıcı ve Model Kataloğu** geliştirilecektir.

```text
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                DİNAMİK LLM SAĞLAYICI MİMARİSİ                                    │
├─────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                 │
│  1. Config-Driven Provider Tanımlama (providers:):                                              │
│     • Provider Adı (openrouter, groq, deepseek, vllm_local, lmstudio, anthropic, ollama, custom)│
│     • Endpoint Tipi (openai_compatible, anthropic, ollama, custom)                              │
│     • Endpoint URL / Base URL                                                                   │
│     • API Key Referansı (api_key_env veya opsiyonel inline api_key)                             │
│     • Özel HTTP Header'ları (örn: OpenRouter için HTTP-Referer, X-Title)                         │
│                                                                                                 │
│  2. Model Seviyesinde Bağlam ve Yetenek Kataloğu:                                               │
│     • model_name: string                                                                        │
│     • context_limit: integer (örn: 128000, 32768, 8192)                                         │
│     • max_output_tokens: integer (örn: 4096, 8192)                                              │
│     • supports_tools: boolean (Native function calling desteği)                                 │
│                                                                                                 │
│  3. Bağlam Limiti Farkındalığı & Güvenlik Kalkanı:                                              │
│     • ContextBuilder, aktif modelin context_limit değerini bilir.                               │
│     • Token kullanımı sınıra yaklaştığında (%80+) sistem_context içine uyarı ekler veya          │
│       bağlamı akıllıca özetler (pruning/truncation).                                            │
│                                                                                                 │
│  4. REPL !provider & !model Entegrasyonu:                                                       │
│     • !provider list / !providers : Kayıtlı tüm sağlayıcıları ve modelleri listeler             │
│     • !provider add <name> <type> <endpoint> : Dinamik sağlayıcı kaydeder                       │
│     • !model list : Tüm modelleri context limitleri ve rolleriyle gösterir                      │
│                                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## ⚙️ 3. Yeni Yapılandırma Şeması (`.rubik/config.yml` veya `~/.rubik/config.yml`)

```yaml
# ------------------------------------------------------------------------------
# 🌐 Dinamik LLM Sağlayıcıları (Providers Registry)
# ------------------------------------------------------------------------------
providers:
  # 1. OpenRouter (Yüzlerce model, tek API)
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

  # 2. DeepSeek
  deepseek:
    type: openai_compatible
    endpoint: https://api.deepseek.com/chat/completions
    api_key_env: DEEPSEEK_API_KEY
    models:
      - name: deepseek-chat
        context_limit: 64000
      - name: deepseek-reasoner
        context_limit: 64000

  # 3. Groq (Ultra Yüksek Hız)
  groq:
    type: openai_compatible
    endpoint: https://api.groq.com/openai/v1/chat/completions
    api_key_env: GROQ_API_KEY
    models:
      - name: llama-3.3-70b-versatile
        context_limit: 128000
      - name: llama3-70b-8192
        context_limit: 8192

  # 4. Yerel vLLM / LMStudio / Ollama OpenAI Uyumluluk Sunucusu
  local_vllm:
    type: openai_compatible
    endpoint: http://localhost:8000/v1/chat/completions
    models:
      - name: Qwen/Qwen2.5-Coder-32B-Instruct
        context_limit: 32768

# ------------------------------------------------------------------------------
# 🧠 Rol Tanımları (Artık tanımlı herhangi bir provider/model seçilebilir)
# ------------------------------------------------------------------------------
models:
  default:
    provider: openrouter
    name: anthropic/claude-3.5-sonnet
  fast:
    provider: groq
    name: llama-3.3-70b-versatile
  advanced:
    provider: deepseek
    name: deepseek-reasoner
```

---

## 🛠️ 4. Eklenecek ve Güncellenecek Bileşenler

### A. Jenerik OpenAI-Uyumlu Sağlayıcı (`lib/rubik/llm/openai_compatible.rb`)
- [ ] Özel endpoint URL (`endpoint:`), API key (`api_key:` veya `api_key_env:`), ek header'lar (`headers:`) ve model parametreleri alan evrensel OpenAI Chat Completions adaptörü.
- [ ] `OpenAIProvider` sınıfının bu jenerik temel sınıftan türetilmesi (kod tekrarı sıfırlanır).

### B. Dinamik Sağlayıcı Yöneticisi (`lib/rubik/llm/registry.rb`)
- [ ] `load_from_config(config)` metodu ile `config["providers"]` altındaki tüm özel sağlayıcıları dinamik olarak ayağa kaldırma.
- [ ] Model bağlam limiti sorgulama API'si: `context_limit_for(provider_name, model_name)` (varsayılan: 32768).
- [ ] Model kataloğu listeleme: `catalog` -> `{ provider => [models] }`.

### C. Model Yönlendiricisi ve Bağlam Limiti Farkındalığı (`lib/rubik/llm/router.rb`)
- [ ] `route(task_type: ...)` çıktısına modelin `context_limit` bilgisinin eklenmesi.
- [ ] `ContextBuilder.build_system_context` içine aktif modelin bağlam penceresi (`<context_budget limit="128000" />`) bilgisinin eklenmesi.

### D. REPL `!provider` Komutu ve Gelişmiş `!model` Listelemesi (`lib/rubik/repl/shell.rb`)
- [ ] `!provider list` / `!providers`: Yapılandırılmış tüm sağlayıcıları, endpoint'leri ve modellerini tablo halinde gösterir.
- [ ] `!provider add <name> <type> <endpoint> [--key-env=VAR] [--model=NAME] [--context=NUM]`: Çalışma zamanında yeni sağlayıcı ekler ve config'e kaydeder.
- [ ] `!model`: Tüm model rollerini, bağlı sağlayıcıları ve context limitlerini gösterir.

---

## 🧪 5. Kabul Kriterleri & Test Senaryoları

- [ ] Kullanıcı `config.yml` içine `openrouter`, `groq`, `local_vllm` gibi özel OpenAI-uyumlu sağlayıcılar eklediğinde `Registry` bunları hatasız yükler.
- [ ] API anahtarı `ENV` üzerinden veya doğrudan konfigürasyondan başarıyla okunur.
- [ ] `!provider list` komutu tüm sağlayıcıları ve modellerin context limitlerini listeler.
- [ ] `ContextBuilder`, modelin context limitine göre `<context_budget>` etiketini bağlama ekler.
- [ ] `test/unit/test_dynamic_llm_providers.rb` birim testleri %100 yeşil geçer.
