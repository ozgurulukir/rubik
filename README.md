# 🎲 Rubik — Autonomous AI Coding Agent & REPL Harness

> **Spatiotemporal Composability & Self-Evolving Runtime** mimarisiyle inşa edilmiş, saf Ruby ile yazılmış yeni nesil otonom eşli kodlama (pair programming) ve REPL harness'ı.

[![Ruby Version](https://img.shields.io/badge/ruby-3.3%2B-red.svg)](https://www.ruby-lang.org)
[![Protocol](https://img.shields.io/badge/protocol-AGENTS.md-blue.svg)](AGENTS.md)
[![Config Guide](https://img.shields.io/badge/docs-CONFIG.md-green.svg)](CONFIG.md)
[![Test Suite](https://img.shields.io/badge/tests-137%20runs%20%7C%20100%25%20passed-brightgreen.svg)]()

---

## ⚡ Öne Çıkan Özellikler

- 🛡️ **Sıfır Riskli Bellek İçi Tampon (In-Memory Buffer):** Model kod yazdığında dosyalarınız hemen diske yazılmaz; bellekteki sanal tamponda hazırlanır. `!diff` ile inceleyebilir, `!apply` ile onaylayabilir veya `!undo` ile saniyeler içinde geri alabilirsiniz.
- ⚡ **Canlı LSP Derleyici Teşhisi (Live In-Buffer Diagnostics):** Model kod yazarken `rust-analyzer`, `typescript-language-server`, `ruff`, `typeprof` gibi dil sunucuları devrededir. Sözdizim veya tip hatası yapıldığında henüz testler çalışmadan model uyarılır.
- 🌳 **Reaktif AST Semantik Grafı:** Ruby (Prism), Python, Go, Rust, Zig ve C dillerinde sembol, fonksiyon, sınıf ve çağrı grafını (`!symbols`, `!outline`, `!refs`) milisaniyeler içinde çözer.
- 🤖 **Çoklu Rol Model Yönlendirmesi (Multi-Role Router):** Hafif işler ve planlama için hızlı modelleri (`fast`), karmaşık otonom görevler için güçlü modelleri (`advanced`) otomatik veya manuel yönlendirir (Ollama, Anthropic Claude, OpenAI).
- 🧬 **Kendi Kendine Evrilen Çalışma Zamanı (Self-Evolving Runtime):** Model çalışma anında yeni REPL komutları (`!db_seed`) veya yerleşik araçlar (`synthesize_tool`) üretebilir ve güvenli sandbox'ta doğrulayıp canlı oturuma dahil edebilir.

---

## 🚀 Hızlı Başlangıç (Quickstart)

### 1. Gereksinimler
- **Ruby:** 3.3.0 veya üzeri (`ruby -v`)
- **LLM Sağlayıcısı:** Yerel [Ollama](https://ollama.ai) (`ollama run qwen2.5-coder:7b`) veya Anthropic / OpenAI API anahtarı.

### 2. Çalıştırma
Projeyi klonlayın veya doğrudan çalıştırılabilir ikiliyi başlatın:

```bash
# Proje dizininde REPL'i başlatın
./bin/rubik

# Veya sisteminizde global kullanmak için ~/.local/bin dizinine bağlayın:
ln -sf $(pwd)/bin/rubik ~/.local/bin/rubik
rubik
```

### 3. İlk Oturum Örneği

```text
rubik (my_project) [main] > !status
Project: my_project (main)
Default Model: ollama/gpt-oss:120b-cloud
Dirty buffer: false

rubik (my_project) [main] > Kullanıcı kayıt formunu doğrulayan bir helper fonksiyonu yaz
 [Rubik::Act] Calling write_file (lib/validator.rb)...
 [Rubik::Verify] -> In-memory buffer updated. Type `!diff` to view, `!apply` to save.

rubik (my_project) [main] [DIRTY: 1 ✎] > !diff
+ def validate_user(params)
+   raise "Invalid email" unless params[:email]&.include?("@")
+ end

rubik (my_project) [main] [DIRTY: 1 ✎] > !test
Applied 1 file(s) before test. All 12 tests passed!
```

---

## 🕹️ Temel REPL Bang Komutları

| Komut | Açıklama |
| :--- | :--- |
| **`!status`** | Aktif proje, git dalı, varsayılan model ve tampon durumunu görüntüler. |
| **`!diff`** | Diske henüz yazılmamış bellek içi tampon değişikliklerini renkli diff olarak listeler. |
| **`!apply`** | Tampondaki tüm değişiklikleri onaylayıp diske yazar. |
| **`!undo`** / **`!rollback <id>`** | Yapılan son değişikliği veya belirtilen snapshot'ı anında geri alır. |
| **`!plan <görev>`** | Görev için adım adım uygulama planı üretir ve onayınızı ister. |
| **`!goal <hedef>`** | Testler %100 geçene kadar otonom döngüde (`Plan -> Act -> Verify`) kod yazar ve onarır. |
| **`!lsp <status\|on\|off\|diag>`** | Dil sunucularını ve anlık derleyici hata listesini yönetir. |
| **`!symbols <sorgu>`** | AST grafında sembol, sınıf ve fonksiyon araması yapar. |
| **`!outline <dosya>`** | Bir kaynak dosyanın sınıflarını ve metot ağacını döker. |
| **`!session <list\|resume>`** | Geçmiş çalışma oturumlarını listeler veya kaldığı yerden devam ettirir (`rubik -c`). |
| **`!config <get\|set\|path>`** | Çalışma zamanı ayarlarını görüntüler veya günceller. |
| **`!help`** | Tüm kayıtlı yerleşik ve dinamik sentezlenmiş komutları listeler. |

---

## ⚙️ Yapılandırma

Tüm model, LSP, tampon politikası ve sandbox ayarları hakkında detaylı bilgi için:  
👉 **[CONFIG.md — Rubik Yapılandırma Kılavuzu](CONFIG.md)** belgesine göz atın.

---

## 🏛️ Mimari Protokol ve Yol Haritası

- 🌌 **Spatiotemporal Composability Protokolü:** [`AGENTS.md`](AGENTS.md)
- 🗺️ **29 Tamamlanan Mimari Plan ve Yol Haritası:** [`_plan/index.md`](_plan/index.md)
- 📜 **Orijinal Tasarım Spesifikasyonu:** [`_proposal/rubik-codingAgent-mainProposal.md`](_proposal/rubik-codingAgent-mainProposal.md)
