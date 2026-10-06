# 📜 Açık Kaynak Atıfları & Üçüncü Taraf Bildirimleri

> Bu belge, [`ATTRIBUTION.md`](ATTRIBUTION.md) dosyasının Türkçe çevirisidir ve güncelliğini yitirmiş olabilir; çelişki halinde İngilizce sürüm esastır.

Rubik, devlerin omuzlarında yükselir. Bu belge; kodları, fikirleri ve araçlarıyla Rubik'i mümkün kılan açık kaynak projelerini, akademik araştırmaları ve mühendislik topluluklarını anar ve onlara itibar eder.

---

## 🍴 1. Fork Edilen & Port Edilen Projeler

### bash-classify
- **Orijinal Proje:** [`bash-classify`](https://github.com/fprochazka/bash-classify)
- **Orijinal Yazar:** Filip Procházka ([@fprochazka](https://github.com/fprochazka))
- **Orijinal Dil:** Python
- **Lisans:** MIT License
- **Rubik Entegrasyonu:**
  - [`lib/rubik/security/classifier/`](lib/rubik/security/classifier/) altında saf Ruby'ye port edildi.
  - Kapsamlı komut veritabanını içerir ([`lib/rubik/security/classifier/commands/`](lib/rubik/security/classifier/commands/) altındaki 172 popüler CLI aracı tanım YAML dosyası).
  - AST ayrıştırma için `tree-sitter` kullanacak biçimde uyarlandı; birinci sınıf **PowerShell** (`pwsh`) cmdlet risk sınıflandırması ve yürütme politikası denetimi ile genişletildi.

```
MIT License

Copyright (c) 2025 Filip Prochazka

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 🏛️ 2. Teorik & Mimari Temeller

### Spatiotemporal Composability
- **Makale:** *"A Programming Paradigm for Spatiotemporal Composability"*
- **Yazarlar:** Yifan Shi (Peking University, DeepSeek-AI), Wei Zhang (Peking University), Tianyi Cui (DeepSeek-AI)
- **Referans Mimarisi:** Cordis / Cordiverse Meta-Framework
- **Rubik'teki Uygulama:**
  - Teorik omurga [`AGENTS.md`](AGENTS.md) içinde kodifiye edildi.
  - **Temporal Composability:** Monoidal LIFO Inverse Accumulator ($\Omega$), [`Rubik::Runtime::Context`](lib/rubik/runtime/context.rb) içinde gerçeklenmiştir.
  - **Spatial Composability:** Reactive Coeffect bağımlılık DAG'ı ($\Sigma \vdash C : \tau$), [`Rubik::Runtime::ComponentFiber`](lib/rubik/runtime/fiber.rb) ve [`Rubik::Runtime::Manager`](lib/rubik/runtime/manager.rb) içinde gerçeklenmiştir.
  - Zero-downtime hot reloading, aktivasyon hatasında atomik rollback ve sızıntısız yaşam döngüsü yönetimi.

---

## 🌳 3. AST Ayrıştırma & Çok Dilli Ekosistem

### Tree-sitter
- **Proje:** [`tree-sitter`](https://github.com/tree-sitter/tree-sitter)
- **Yazarlar:** Max Brunsfeld and the Tree-sitter Authors
- **Lisans:** MIT License
- **Kullanım:** Çok dilli semantik kod zekası, sembol çıkarımı ve komut güvenlik analizi için hızlı, artımlı ve sağlam concrete syntax tree ayrıştırma.

### tree_sitter_language_pack
- **Proje:** [`tree-sitter-language-pack`](https://github.com/xberg-io/tree-sitter-language-pack)
- **Bakımcı:** xberg-io
- **Lisans:** MIT License
- **Yararlanılan Gramerler:**
  - `tree-sitter-bash`
  - `tree-sitter-powershell`
  - `tree-sitter-ruby`
  - `tree-sitter-python`
  - `tree-sitter-go`
  - `tree-sitter-rust`
  - `tree-sitter-c`
  - `tree-sitter-zig`
  - `tree-sitter-typescript` / `tree-sitter-javascript`

---

## 🛡️ 4. İşletim Sistemi Sandbox & İzolasyon

### Bubblewrap (`bwrap`)
- **Proje:** [`bubblewrap`](https://github.com/containers/bubblewrap)
- **Yazarlar:** Project Atomic / Flatpak / GNOME katkıcıları
- **Lisans:** LGPL-2.0-or-later
- **Rubik Entegrasyonu:**
  - [`Rubik::Sandbox::Driver::BubblewrapDriver`](lib/rubik/sandbox/driver/bubblewrap.rb), root ayrıcalıkları gerektirmeden donanım tarafından zorunlu kılınan dosya sistemi ve ağ sınırlandırması (confinement) için ayrıcalıksız kullanıcı namespace'lerini (`CLONE_NEWUSER`, `CLONE_NEWNET`, `CLONE_NEWPID`) kullanır.

### Container Runtime'ları (Docker & Podman)
- **Projeler:** [`moby/moby` (Docker Engine)](https://github.com/moby/moby) · [`containers/podman`](https://github.com/containers/podman)
- **Lisanslar:** Apache-2.0 (Docker/Moby) · GPL-2.0-or-later (Podman; libpod)
- **Rubik Entegrasyonu:**
  - [`Rubik::Sandbox::Driver::DockerDriver`](lib/rubik/sandbox/driver/docker.rb) ve [`Rubik::Sandbox::Driver::PodmanDriver`](lib/rubik/sandbox/driver/podman.rb) bu motorları **yalnızca harici CLI araçları** olarak kullanır (hiçbir kaynak kod dahil edilmedi): workspace bind-mount'ları, bellek/CPU/pids limitleri ve varsayılan olarak kapalı ağ (network-off) sınırlandırması.
  - [`Rubik::Sandbox::Driver::ProcessDriver`](lib/rubik/sandbox/driver/process.rb), çekirdek seviyesinde bir sandbox bulunmadığında her zaman kullanılabilir olan doğrudan host yedeğini (fallback) sağlar.

---

## 💎 5. Açık Kaynak Ruby Gem'leri & Kütüphaneleri

| Gem | Yazar / Bakımcı | Lisans | Rubik'teki Rolü |
| :--- | :--- | :--- | :--- |
| **`diff-lcs`** | Austin Ziegler | MIT / Artistic / GPL | Longest Common Subsequence tabanlı unified diff üretimi ve hunk birleştirme ([`Rubik::Buffer::Diff`](lib/rubik/buffer/diff.rb)). |
| **`tty-prompt`** | Piotr Murach | MIT | Etkileşimli komut satırı seçim diyalogları, çoklu seçim soruları ve anketler. |
| **`tty-spinner`** | Piotr Murach | MIT | Yönetilen, bloklamayan (non-blocking) yaşam döngüsü spinner'ları ve ilerleme bildirimi. |
| **`tty-markdown`** | Piotr Murach | MIT | Etkileşimli REPL içinde terminal ANSI/renklendirilmiş Markdown render'ı. |
| **`tty-which`** | Piotr Murach | MIT | Çapraz platform çalıştırılabilir binary bulucu. |
| **`pastel`** | Piotr Murach | MIT | Temiz, zincirlenebilir ANSI terminal renklendirme ve tema boyama. |
| **`strings-ansi`** | Piotr Murach | MIT | REPL biçimlendiricileri için ANSI bilinçli dize kısaltma ve hizalama. |
| **`reline`** | Hiroshi SHIBATA & Ruby Team | Ruby License / BSD-2-Clause | Satır düzenleme, geçmiş gezinme, otomatik tamamlama kancaları ve headless terminal adaptasyonu. |
| **`prism`** | Kevin Newton & Ruby Core Team | MIT | Yüksek performanslı Ruby ayrıştırma ve AST çıkarımı ([`Rubik::AST::RubyExtractor`](lib/rubik/ast/ruby_extractor.rb)). |
| **`minitest`** | Ryan Davis & seattlerb | MIT | Rubik'in 1.690+ birim, entegrasyon ve contract testini çalıştıran hızlı, modüler test suite'i. |
| **`rubocop`** | Bozhidar Batsov & contributors | MIT | Statik kod analizi, stil zorlaması ve mimari hijyen kapıları (gates). |
| **`benchmark`, `logger`, `pstore`, `reline`, `fiddle`** | Ruby core / rubygems teams | Ruby License / BSD-2-Clause | Ruby 3.4/3.5'te varsayılan setten çıkarıldıkları için `rubik.gemspec` içinde açıkça sabitlenen (pinned) Ruby stdlib gem'leri. |

---

## 🌐 6. Endüstri Spesifikasyonları & Açık Protokoller

- **Language Server Protocol (LSP):**
  - Microsoft Corporation spesifikasyonu (MIT / CC BY 4.0 altında lisanslıdır).
  - Rubik'in çapraz dil tanılamalarını, sembol ana hatlarını ve jump-to-definition özelliğini besler.
- **Model Context Protocol (MCP):**
  - Anthropic, PBC'nin spesifikasyonu ve referans mimarisi (MIT License altında lisanslıdır).
  - Rubik'in dinamik çoklu sunucu araç keşfini, stdio transport'unu ve spatiotemporal araç izolasyonunu besler.
- **Server-Sent Events (SSE):**
  - Gerçek zamanlı LLM token yanıtlarının akışı ve olay telemetrisi için W3C Recommendation standardı.
- **Semantic Versioning 2.0.0:**
  - Tom Preston-Werner spesifikasyonu (CC BY 3.0).

---

## ⚖️ 7. Rubik'in Lisansı

Rubik'in kendisi **MIT License** altında lisanslanmıştır.  
Tam lisans metni için [`LICENSE`](LICENSE) dosyasına bakın.
