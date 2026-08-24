# 🎲 Rubik — Autonomous AI Coding Agent & REPL Harness

> **Spatiotemporal Composability & Self-Evolving Runtime** mimarisiyle inşa edilmiş, saf Ruby ile yazılmış yeni nesil otonom eşli kodlama (pair programming) ve REPL harness'ı.

[![Ruby Version](https://img.shields.io/badge/ruby-3.3%2B-red.svg)](https://www.ruby-lang.org)
[![Protocol](https://img.shields.io/badge/protocol-AGENTS.md-blue.svg)](AGENTS.md)
[![Commands Guide](https://img.shields.io/badge/docs-COMMANDS.md-yellow.svg)](COMMANDS.md)
[![Config Guide](https://img.shields.io/badge/docs-CONFIG.md-green.svg)](CONFIG.md)
[![Test Suite](https://img.shields.io/badge/tests-258%20runs%20%7C%20100%25%20passed-brightgreen.svg)]()

---

## ⚡ Öne Çıkan Özellikler

- 🛡️ **Sıfır Riskli Bellek İçi Tampon (In-Memory Buffer):** Model kod yazdığında dosyalarınız hemen diske yazılmaz; bellekteki sanal tamponda hazırlanır. `!diff` ile inceleyebilir, `!apply` ile onaylayabilir veya `!undo` ile saniyeler içinde geri alabilirsiniz.
- 🏢 **Çoklu Çalışma Alanı & Ek Kök Dizinler (Multi-Workspace Roots):** Monorepo veya kardeş paket mimarilerinde (`../shared-kernel`, `../proto`) harici kök dizinleri güvenle ekleyip (`!workspace add`), salt-okunur veya yazılabilir (`--rw`) modda tampon ve AST indeksine dahil edebilirsiniz.
- ⚡ **Canlı LSP Derleyici Teşhisi (Live In-Buffer Diagnostics):** Model kod yazarken `rust-analyzer`, `typescript-language-server`, `ruff`, `typeprof` gibi dil sunucuları devrededir. Sözdizim veya tip hatası yapıldığında henüz testler çalışmadan model uyarılır.
- 🌳 **Reaktif, Asenkron ve Kalıcı AST Semantik Grafı:** Ruby (Prism), Python, Go, Rust, Zig, C ve TypeScript/TSX/JS/JSX dillerinde sembol, fonksiyon, sınıf ve çağrı grafını (`!symbols`, `!outline`, `!refs`) arka planda asenkron tarar, disk önbelleği (`.rubik/cache/ast_index.json`) ile 0 ms anlık başlatır.
- 🤖 **Dinamik LLM Sağlayıcıları & Çoklu Rol Yönlendirmesi:** OpenAI uyumlu tüm endpoint'ler (DeepSeek, Groq, OpenRouter, Mistral, vLLM), Anthropic Claude, OpenAI ve yerel Ollama desteği ile hafif/ağır görev yönlendirmesi.
- 🧬 **Spatiotemporal Composability & Kendi Kendine Evrilen Çalışma Zamanı:** Model çalışma anında yeni REPL komutları (`synthesize_command`) veya yerleşik araçlar (`synthesize_tool`) üretebilir; her yan etki LIFO ters işlem akümülatörü ($\Omega$) ile güvenle takip edilir.
- 📺 **Kademeli Canlı Ajan İzleme (Step Formatter & Verbosity):** `quiet`, `normal`, `verbose`, `debug` seviyeleri ile adım ilerlemesi, araç çağrıları, yürütüm süreleri ve ara düşünceler anlık izlenir (`!verbosity`, `!verbose`).

---

## 🚀 Hızlı Başlangıç (Quickstart)

### 1. Gereksinimler
- **Ruby:** 3.3.0 veya üzeri (`ruby -v`)
- **LLM Sağlayıcısı:** Yerel [Ollama](https://ollama.ai) (`ollama run qwen2.5-coder:7b`) veya DeepSeek, OpenRouter, Anthropic, OpenAI API anahtarı.

### 2. Çalıştırma
Projeyi klonlayın veya doğrudan çalıştırılabilir ikiliyi başlatın:

```bash
# Proje dizininde REPL'i başlatın
./bin/rubik

# Veya sisteminizde global kullanmak için ~/.local/bin dizinine bağlayın:
ln -sf $(pwd)/bin/rubik ~/.local/bin/rubik
rubik
```

### 3. Sağlayıcı (Provider) & Model Ekleme
İstediğiniz OpenAI uyumlu herhangi bir sağlayıcıyı tek satırla bağlayabilirsiniz:

```bash
# REPL içerisinden sağlayıcı ekleme:
rubik > !provider add deepseek openai_compatible https://api.deepseek.com/v1/chat/completions --key=sk-... --model=deepseek-coder --context=64000
rubik > !model deepseek/deepseek-coder
```

### 4. İlk Oturum Örneği

```text
rubik (my_project) [main] > !status
Project: my_project (main)
Default Model: deepseek/deepseek-coder
Dirty buffer: false

rubik (my_project) [main] > Kullanıcı kayıt formunu doğrulayan bir helper fonksiyonu yaz
 ▶ [Step 1/40] write_file (path: "lib/validator.rb")
 ✔ [Obs] 3 lines (2.4ms)

[Rubik] In-memory buffer updated. Type `!diff` to view, `!apply` to save.

rubik (my_project) [main] [DIRTY: 1 ✎] > !diff
+ def validate_user(params)
+   raise "Invalid email" unless params[:email]&.include?("@")
+ end

rubik (my_project) [main] [DIRTY: 1 ✎] > !test
Applied 1 file(s) before test. All 12 tests passed!
```

> [!TIP]
> **GitHub CLI (`gh`), `git push` veya Paket Yöneticileri İçin Ağ İzni:**  
> Rubik varsayılan olarak izole güvenlik sandbox'ı (`allow_network: false`) uygular. Modelin `gh`, `cargo` veya `npm` gibi internete çıkan komutlar çalıştırması gerekiyorsa REPL içerisinden tek komutla izin verebilirsiniz:
> ```bash
> !config set sandbox.allow_network true -p   # Aktif projeye özel ağ izni verir
> ```

---

## 🕹️ REPL Bang Komutları

Tüm 30+ etkileşimli komutun detaylı parametreleri, bayrakları ve kullanım senaryoları için:  
👉 **[COMMANDS.md — Kapsamlı REPL Komut Kılavuzu](COMMANDS.md)** belgesine göz atın.

### Özet Komut Tablosu

| Komut Grubu | Önemli Komutlar | Açıklama |
| :--- | :--- | :--- |
| **Model & Sağlayıcı** | `!provider`, `!providers`, `!model` | Sağlayıcı ekleme/silme (CRUD), model rol ataması ve akıllı yönlendirme. |
| **Ajan & Planlama** | `!plan`, `!goal`, `!steps` | Adım adım planlama, otonom hedef döngüsü ve adım bütçesi yönetimi. |
| **Tampon & Snapshot** | `!diff`, `!apply`, `!autoapply`, `!undo` | Bellek içi sanal dosya tamponu inceleme, diske kaydetme ve geri alma. |
| **Runtime & Fiberler** | `!runtime`, `!fibers`, `!services` | Coeffect servisleri, aktif/bekleyen fiberler ve $\Omega$ ters işlem derinliği. |
| **Kod Zekası & LSP** | `!lsp`, `!symbols`, `!outline`, `!refs` | Derleyici hata teşhisi ve semantik AST graf aramaları. |
| **Test & Yürütüm** | `!test`, `!lint`, `!format`, `!sh` | Çok dilli test koşumu ve güvenli sandbox kabuk yürütümü. |
| **Oturum & Ayarlar** | `!session`, `!history`, `!config`, `!verbosity`, `!status` | Oturum kaydetme, `rubik -c` ile devam etme, ayrıntı düzeyi ve canlı ayarlar. |
| **Çalışma Alanı & Kökler** | `!workspace`, `!roots` | Çoklu kök dizin ekleme/çıkarma (`add`/`remove`), izin (`--rw`) ve durum listeleme. |

---

## ⚙️ Yapılandırma

Tüm model, LSP, tampon politikası, sağlayıcılar ve sandbox ayarları hakkında detaylı bilgi için:  
👉 **[CONFIG.md — Rubik Yapılandırma Kılavuzu](CONFIG.md)** belgesine göz atın.

---

## 🏛️ Mimari Protokol ve Yol Haritası

- 🌌 **Spatiotemporal Composability Protokolü:** [`AGENTS.md`](AGENTS.md)
- 🕹️ **Kapsamlı REPL Komut Kılavuzu:** [`COMMANDS.md`](COMMANDS.md)
- ⚙️ **Yapılandırma Kılavuzu:** [`CONFIG.md`](CONFIG.md)
- 🗺️ **42 Tamamlanan Mimari Plan ve Yol Haritası:** [`_plan/index.md`](_plan/index.md)
- 📜 **Orijinal Tasarım Spesifikasyonu:** [`_proposal/rubik-codingAgent-mainProposal.md`](_proposal/rubik-codingAgent-mainProposal.md)
