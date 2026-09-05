# 🗺️ Rubik Implementasyon Planları — Ana İndeks

> **Kaynak:** `_proposal/rubik-codingAgent-mainProposal.md` (v1.2)  
> **Protokol:** [`AGENTS.md`](../AGENTS.md) — *Protocol for Spatiotemporal Composability & Self-Evolving Runtimes*  
> **Son Güncelleme:** 1 Eylül 2026

Planlar **semantik birimlere** ayrılmıştır; 79 planın 79'u başarıyla tamamlanmıştır (Toplam 79).

---

## 📊 Plan Listesi ve Uygulama Durumu (79/79 Tamamlandı ✅ · 100% 🚀)

| # | Plan Dosyası | Durum | Zorluk | Öneri Bölümü | Faz | İlgili / Bağımlı Planlar |
| :--- | :--- | :---: | :---: | :---: | :---: | :--- |
| 01 | [Proje İskeleti ve Konfigürasyon](01-proje-iskeleti-ve-konfigurasyon.md) | ✅ **Tamamlandı** | Kolay | §7.6 | 1 | [02](02-repl-cekirdegi.md), [03](03-dosya-tamponu-snapshot-undo.md), [05](05-baglam-motoru-dosya-indeksi.md) |
| 02 | [REPL Çekirdeği ve Komut Ayrıştırıcı](02-repl-cekirdegi.md) | ✅ **Tamamlandı** | Kolay–Orta | §7.1, §8 | 1 | [01](01-proje-iskeleti-ve-konfigurasyon.md), [04](04-oturum-loglama-replay.md), [16](16-genisletilmis-arac-seti-ve-planlama.md) |
| 03 | [Bellek İçi Dosya Tamponu, Snapshot ve Undo](03-dosya-tamponu-snapshot-undo.md) | ✅ **Tamamlandı** | Orta | §7.1, §9.3 | 1 | [01](01-proje-iskeleti-ve-konfigurasyon.md), [11](11-kendi-kendine-onarim.md), [12](12-guvenlik-diff-onay.md) |
| 04 | [Oturum Loglama, History ve Replay](04-oturum-loglama-replay.md) | ✅ **Tamamlandı** | Orta | §7.1 | 1 | [02](02-repl-cekirdegi.md), [03](03-dosya-tamponu-snapshot-undo.md) |
| 05 | [Bağlam Motoru: Dosya İndeksi ve Git Durumu](05-baglam-motoru-dosya-indeksi.md) | ✅ **Tamamlandı** | Orta | §7.2 | 2 | [01](01-proje-iskeleti-ve-konfigurasyon.md), [06](06-ast-semantik-indeks.md) |
| 06 | [AST Sembol Tablosu ve Bağımlılık Grafı](06-ast-semantik-indeks.md) | ✅ **Tamamlandı** | Zor | §7.2 | 2 | [05](05-baglam-motoru-dosya-indeksi.md), [10](10-tool-calling-orkestrasyon.md), [18](18-tree-sitter-ast-ve-lsp-entegrasyonu.md) |
| 07 | [Dil Adaptör Çerçevesi](07-dil-adaptor-cercevesi.md) | ✅ **Tamamlandı** | Orta | §7.3 | 3 | [01](01-proje-iskeleti-ve-konfigurasyon.md), [08](08-hata-ayristirma-teshis.md), [11](11-kendi-kendine-onarim.md) |
| 08 | [Derleyici Çıktısı Ayrıştırma ve Teşhis](08-hata-ayristirma-teshis.md) | ✅ **Tamamlandı** | Orta–Zor | §7.4, §7.3 | 3 | [07](07-dil-adaptor-cercevesi.md), [11](11-kendi-kendine-onarim.md) |
| 09 | [LLM Sağlayıcı Soyutlaması](09-llm-saglayici-soyutlamasi.md) | ✅ **Tamamlandı** | Orta | §7.5 | 2 | [01](01-proje-iskeleti-ve-konfigurasyon.md), [10](10-tool-calling-orkestrasyon.md), [17](17-native-tool-calling-ve-model-yonlendirme.md) |
| 10 | [Tool-Calling ve Plan→Act→Verify Orkestrasyonu](10-tool-calling-orkestrasyon.md) | ✅ **Tamamlandı** | Zor | §7.5, §8 | 2 | [09](09-llm-saglayici-soyutlamasi.md), [06](06-ast-semantik-indeks.md), [16](16-genisletilmis-arac-seti-ve-planlama.md) |
| 11 | [Kendi Kendini Onarma Döngüsü](11-kendi-kendine-onarim.md) | ✅ **Tamamlandı** | Zor | §7.4 | 4 | [08](08-hata-ayristirma-teshis.md), [03](03-dosya-tamponu-snapshot-undo.md), [07](07-dil-adaptor-cercevesi.md) |
| 12 | [Güvenlik Katmanı: Diff Onayı ve Kritik Dosya](12-guvenlik-diff-onay.md) | ✅ **Tamamlandı** | Orta–Zor | §9 | 4 | [03](03-dosya-tamponu-snapshot-undo.md), [10](10-tool-calling-orkestrasyon.md), [19](19-container-ve-wasm-sandbox-izolasyonu.md) |
| 13 | [Sandbox ve Süreç İzolasyonu](13-sandbox-izolasyon.md) | ✅ **Tamamlandı** | Zor | §9.1 | 4 | [07](07-dil-adaptor-cercevesi.md), [12](12-guvenlik-diff-onay.md), [19](19-container-ve-wasm-sandbox-izolasyonu.md) |
| 14 | [Eklenti Sistemi](14-eklenti-sistemi.md) | ✅ **Tamamlandı** | Orta–Zor | §7.6 | 5 | [01](01-proje-iskeleti-ve-konfigurasyon.md), [20](20-spatiotemporal-composability-eklenti-dongusu.md) |
| 15 | [Benchmark ve Kabul Testleri](15-benchmark-kabul-testleri.md) | ✅ **Tamamlandı** | Orta | §10 | 5 | *Tüm Planlar (01–14)* |
| 16 | [Genişletilmiş Araç Seti, Planlama ve Hedef](16-genisletilmis-arac-seti-ve-planlama.md) | ✅ **Tamamlandı** | Orta–Zor | §7.5, §8 | 2–3 | [10](10-tool-calling-orkestrasyon.md), [06](06-ast-semantik-indeks.md), [12](12-guvenlik-diff-onay.md) |
| 17 | [Native LLM Tool Calling ve Model Yönlendirme](17-native-tool-calling-ve-model-yonlendirme.md) | ✅ **Tamamlandı** | Zor | §7.5 | 3 | [09](09-llm-saglayici-soyutlamasi.md), [10](10-tool-calling-orkestrasyon.md), [16](16-genisletilmis-arac-seti-ve-planlama.md) |
| 18 | [Tree-sitter Çok Dilli Semantik AST ve LSP](18-tree-sitter-ast-ve-lsp-entegrasyonu.md) | ✅ **Tamamlandı** | Zor | §7.2 | 3–4 | [06](06-ast-semantik-indeks.md), [07](07-dil-adaptor-cercevesi.md), [16](16-genisletilmis-arac-seti-ve-planlama.md) |
| 19 | [Container (Docker) ve Wasm Sandbox İzolasyonu](19-container-ve-wasm-sandbox-izolasyonu.md) | ✅ **Tamamlandı** | Zor | §9.1 | 4 | [13](13-sandbox-izolasyon.md), [12](12-guvenlik-diff-onay.md) |
| 20 | [Spatiotemporal Composability & Eklenti Döngüsü](20-spatiotemporal-composability-eklenti-dongusu.md) | ✅ **Tamamlandı** | Zor | `AGENTS.md` | 5 | [14](14-eklenti-sistemi.md), [10](10-tool-calling-orkestrasyon.md), [AGENTS.md](../AGENTS.md) |
| 21 | [LLM REPL Komut Yürütümü, Dinamik Araç Sentezi ve Overlay](21-llm-komut-sentezi-ve-calistirma.md) | ✅ **Tamamlandı** | Zor | §3 (`AGENTS.md`), §8 | 5 | [02](02-repl-cekirdegi.md), [10](10-tool-calling-orkestrasyon.md), [20](20-spatiotemporal-composability-eklenti-dongusu.md) |
| 22 | [LLM Durumsal Farkındalık & Geri Bildirim Döngüsü](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md) | ✅ **Tamamlandı** | Orta–Zor | §3 (`AGENTS.md`), §6 | 5 | [21](21-llm-komut-sentezi-ve-calistirma.md), [10](10-tool-calling-orkestrasyon.md), [02](02-repl-cekirdegi.md) |
| 23 | [XML Yapılandırılmış Bağlam & AGENTS.md Stream Entegrasyonu](23-xml-yapilandirilmis-baglam-ve-agents-protokol-entegrasyonu.md) | ✅ **Tamamlandı** | Orta–Zor | `AGENTS.md` (§1, §3) | 5 | [22](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md), [20](20-spatiotemporal-composability-eklenti-dongusu.md), [04](04-oturum-loglama-replay.md) |
| 24 | [Kendi Kendini Evrilen Araç Sentezi ve Çalışma Zamanı Denetimi](24-kendi-kendine-evrilen-arac-sentezi-ve-calisma-zamani-denetimi.md) | ✅ **Tamamlandı** | Zor | `AGENTS.md` (§1–§6) | 5 | [20](20-spatiotemporal-composability-eklenti-dongusu.md), [21](21-llm-komut-sentezi-ve-calistirma.md), [23](23-xml-yapilandirilmis-baglam-ve-agents-protokol-entegrasyonu.md) |
| 25 | [Yapılandırma Kalıcılığı ve Otomatik Kaydetme](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md) | ✅ **Tamamlandı** | Kolay–Orta | Kullanıcı Geri Bildirimi | 5 | [01](01-proje-iskeleti-ve-konfigurasyon.md), [02](02-repl-cekirdegi.md), [17](17-native-tool-calling-ve-model-yonlendirme.md) |
| 26 | [Çalışma Alanı Oturum Kalıcılığı ve `-c` ile Devam Etme](26-calisma-alani-oturum-kaliciligi-ve-c-flag-ile-devam-etme.md) | ✅ **Tamamlandı** | Kolay–Orta | Kullanıcı Talebi | 5 | [04](04-oturum-loglama-replay.md), [02](02-repl-cekirdegi.md), [25](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md) |
| 27 | [Tampon Kirli Durum Hatırlatıcı, Model Auto-Apply ve Ping](27-tampon-kirli-durum-hatirlatici-ve-akilli-ping-sistemi.md) | ✅ **Tamamlandı** | Kolay–Orta | Kullanıcı Geri Bildirimi | 5 | [03](03-dosya-tamponu-snapshot-undo.md), [02](02-repl-cekirdegi.md), [10](10-tool-calling-orkestrasyon.md), [12](12-guvenlik-diff-onay.md), [23](23-xml-yapilandirilmis-baglam-ve-agents-protokol-entegrasyonu.md) |
| 28 | [Olay Güdümlü Reaktif Bağlam, AST ve Akıllı Dosya Ağacı](28-olay-gudumlu-reaktif-baglam-ast-ve-akilli-calisma-alani-agaci.md) | ✅ **Tamamlandı** | Orta–Zor | Kullanıcı Geri Bildirimi | 5 | [05](05-baglam-motoru-dosya-indeksi.md), [06](06-ast-semantik-indeks.md), [18](18-tree-sitter-ast-ve-lsp-entegrasyonu.md), [23](23-xml-yapilandirilmis-baglam-ve-agents-protokol-entegrasyonu.md) |
| 29 | [LSP Derin Entegrasyonu, Tanılama ve Reaktif Geri Bildirim](29-lsp-derin-entegrasyonu-tanilama-ve-reaktif-geri-bildirim.md) | ✅ **Tamamlandı** | Zor | Kullanıcı Geri Bildirimi | 5 | [06](06-ast-semantik-indeks.md), [08](08-hata-ayristirma-teshis.md), [18](18-tree-sitter-ast-ve-lsp-entegrasyonu.md), [22](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md), [28](28-olay-gudumlu-reaktif-baglam-ast-ve-akilli-calisma-alani-agaci.md) |
| 30 | [Dinamik LLM Sağlayıcıları, Özel Endpoint'ler ve Bağlam Limiti](30-dinamik-llm-saglayicilari-ozel-endpointler-ve-baglam-limiti.md) | ✅ **Tamamlandı** | Orta–Zor | Kullanıcı Talebi | 5 | [09](09-llm-saglayici-soyutlamasi.md), [17](17-native-tool-calling-ve-model-yonlendirme.md), [22](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md), [25](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md) |
| 31 | [Agentic Adım Bütçesi ve Dinamik Genişletme](31-agentic-adim-butcesi-ve-dinamik-genisletme.md) | ✅ **Tamamlandı** | Orta | Kullanıcı Talebi | 5 | [10](10-tool-calling-orkestrasyon.md), [16](16-genisletilmis-arac-seti-ve-planlama.md), [22](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md), [25](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md) |
| 32 | [Agentic Tool Çağrıları, Yapılandırılmış I/O ve Akıllı Bağlam Kırpma](32-agentic-tool-cagrilari-yapilandirilmis-io-ve-akilli-baglam-kirpma.md) | ✅ **Tamamlandı** | Orta–Zor | Kullanıcı Talebi & `AGENTS.md` | 5 | [10](10-tool-calling-orkestrasyon.md), [17](17-native-tool-calling-ve-model-yonlendirme.md), [20](20-spatiotemporal-composability-eklenti-dongusu.md), [23](23-xml-yapilandirilmis-baglam-ve-agents-protokol-entegrasyonu.md), [30](30-dinamik-llm-saglayicilari-ozel-endpointler-ve-baglam-limiti.md), [31](31-agentic-adim-butcesi-ve-dinamik-genisletme.md) |
| 33 | [Spatiotemporal Coeffect Entegrasyonu, Inverses ve REPL !runtime](33-spatiotemporal-coeffect-inverses-ve-runtime-gorsellestirme.md) | ✅ **Tamamlandı** | Kolay–Orta | `AGENTS.md` Denetimi & Teamwork | 5 | [20](20-spatiotemporal-composability-eklenti-dongusu.md), [21](21-llm-komut-sentezi-ve-calistirma.md), [24](24-kendi-kendine-evrilen-arac-sentezi-ve-calisma-zamani-denetimi.md), [32](32-agentic-tool-cagrilari-yapilandirilmis-io-ve-akilli-baglam-kirpma.md) |
| 34 | [Spatiotemporal Oturum Sürekliliği, Sıfır-Token Anında Hafıza Yükleme (`rubik -c`)](34-spatiotemporal-oturum-kaliciligi-ve-aninda-hafiza-yukleme.md) | ✅ **Tamamlandı** | Orta | `AGENTS.md` & Session Management | 5 | [04](04-oturum-loglama-replay.md), [26](26-calisma-alani-oturum-kaliciligi-ve-c-flag-ile-devam-etme.md), [33](33-spatiotemporal-coeffect-inverses-ve-runtime-gorsellestirme.md) |
| 35 | [Akıllı Bağlam Sıkıştırma (Compactor), Token Tahmini ve Auto-Recovery](35-baglam-sikistirma-token-tahmini-ve-otomatik-truncation-politikasi.md) | ✅ **Tamamlandı** | Orta–Zor | `AGENTS.md` & Context Management | 5 | [23](23-xml-yapilandirilmis-baglam-ve-agents-protokol-entegrasyonu.md), [30](30-dinamik-llm-saglayicilari-ozel-endpointler-ve-baglam-limiti.md), [34](34-spatiotemporal-oturum-kaliciligi-ve-aninda-hafiza-yukleme.md) |
| 36 | [REPL Komutu / Yerel Araç Ayrımı ve Ajan Guardrail'ı](36-repl-komut-ve-yerel-arac-ayrimi-ve-ajan-yonlendirme-guardrail.md) | ✅ **Tamamlandı** | Kolay–Orta | `AGENTS.md` & Tool Calling UX | 5 | [21](21-llm-komut-sentezi-ve-calistirma.md), [22](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md), [32](32-agentic-tool-cagrilari-yapilandirilmis-io-ve-akilli-baglam-kirpma.md) |
| 37 | [Kademeli Verbosity Ayarları, Canlı Ajan İzleme ve REPL !verbosity](37-kademeli-verbosity-ayarlari-ve-canli-ajan-izleme.md) | ✅ **Tamamlandı** | Kolay–Orta | Kullanıcı Talebi & REPL UX | 5 | [16](16-genisletilmis-arac-seti-ve-planlama.md), [22](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md), [31](31-agentic-adim-butcesi-ve-dinamik-genisletme.md) |
| 38 | [YAML::Store ile Güvenli ve Transaksiyonel Yapılandırma Kalıcılığı](38-yaml-store-ile-guvenli-ve-transaksiyonel-kalicilik-refaktoru.md) | ✅ **Tamamlandı** | Kolay–Orta | Standart Kütüphane & Eşzamanlılık | 5 | [01](01-proje-iskeleti-ve-konfigurasyon.md), [25](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md), [30](30-dinamik-llm-saglayicilari-ozel-endpointler-ve-baglam-limiti.md), [37](37-kademeli-verbosity-ayarlari-ve-canli-ajan-izleme.md) |
| 39 | [Asenkron, Kademeli ve Kalıcı AST & Bağlam İndeksleme](39-asenkron-ve-kademeli-ast-onbellegi-persistent-lazy-indexing.md) | ✅ **Tamamlandı** | Orta | Performans & Büyük Repolar | 5 | [05](05-baglam-motoru-dosya-indeksi.md), [06](06-ast-semantik-indeks.md), [18](18-tree-sitter-ast-ve-lsp-entegrasyonu.md), [28](28-reaktif-baglam-motoru-ast-ve-akilli-dosya-agaci.md), [38](38-yaml-store-ile-guvenli-ve-transaksiyonel-kalicilik-refaktoru.md) |
| 40 | [Çoklu Çalışma Alanı ve Ek Kök Dizin Erişim Yönetimi](40-coklu-calisma-alani-ve-ek-kok-dizin-erisim-yonetimi.md) | ✅ **Tamamlandı** | Orta | Monorepo & Çalışma Alanı | 5 | [01](01-proje-iskeleti-ve-konfigurasyon.md), [03](03-bellek-ici-tampon-buffer-yonetimi.md), [12](12-guvenlik-denetimi-ve-onay-mekanizmasi.md), [25](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md), [38](38-yaml-store-ile-guvenli-ve-transaksiyonel-kalicilik-refaktoru.md) |
| 41 | [REPL Komut Modülerizasyonu ve Etki Alanı Ayrımı](41-repl-komut-modulerizasyonu-domain-driven-command-decoupling.md) | ✅ **Tamamlandı** | Orta | Mimari & Temiz Kod | 5 | [02](02-repl-kabugu-ve-etkilesimli-arayuz.md), [20](20-spatiotemporal-runtime-context-ve-fiber-yasam-dongusu.md), [36](36-repl-komut-ve-yerel-arac-ayrimi-ve-ajan-yonlendirme-guardrail.md), [37](37-kademeli-verbosity-ayarlari-ve-canli-ajan-izleme.md), [40](40-coklu-calisma-alani-ve-ek-kok-dizin-erisim-yonetimi.md) |
| 42 | [Orchestrator Loop Dekompozisyonu ve Ortak LLM Formatlayıcı](42-orchestrator-loop-dekompozisyonu-ve-llm-formatlayici.md) | ✅ **Tamamlandı** | Orta | Performans & Sadeleştirme | 5 | [10](10-ajan-dongusu-ve-arac-entegrasyonu.md), [17](17-yerel-arac-cagrilari-ve-router.md), [30](30-dinamik-llm-saglayicilari-ozel-endpointler-ve-baglam-limiti.md), [31](31-agentic-adim-butcesi-ve-dinamik-genisletme.md), [35](35-akilli-baglam-sikistirici-ve-dinamik-token-yonetimi.md) |
| 43 | [REPL Komutlarının Standardizasyonu ve Uçtan Uca Wiring Denetimi](43-repl-bang-komut-standardizasyonu-ve-wiring-denetimi.md) | ✅ **Tamamlandı** | Orta | CLI Ergonomisi & Tutarlılık | 5 | [02](02-repl-kabugu-ve-etkilesimli-arayuz.md), [25](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md), [37](37-kademeli-verbosity-ayarlari-ve-canli-ajan-izleme.md), [40](40-coklu-calisma-alani-ve-ek-kok-dizin-erisim-yonetimi.md), [41](41-repl-komut-modulerizasyonu-domain-driven-command-decoupling.md) |
| 44 | [LLM Eğitim Verileriyle Uyumlu Kanonik Araç İsimlendirmesi, Grep ve Tool Aliasing](44-llm-egitim-uyumlu-arac-isimlendirmesi-grep-ve-tool-aliasing.md) | ✅ **Tamamlandı** | Kolay–Orta | LLM Tool Calling Doğruluğu | 5 | [10](10-ajan-dongusu-ve-arac-entegrasyonu.md), [16](16-genisletilmis-arac-seti-ve-planlama.md), [17](17-yerel-arac-cagrilari-ve-router.md), [32](32-agentic-tool-cagrilari-yapilandirilmis-io-ve-akilli-baglam-kirpma.md), [36](36-repl-komut-ve-yerel-arac-ayrimi-ve-ajan-yonlendirme-guardrail.md) |
| 45 | [Kod Tabanı Genelinde Spatiotemporal Öz-Evrilen Çalışma Zamanı ve Otonom Adaptör Sentezi](45-spatiotemporal-oz-evrilen-calisma-zamani-ve-otonom-adaptor-sentezi.md) | ✅ **Tamamlandı** | İleri Düzey | `AGENTS.md` & Otonom Refleks | 5 | [11](11-kendi-kendini-iyilestirme-self-repair.md), [20](20-spatiotemporal-runtime-context-ve-fiber-yasam-dongusu.md), [24](24-kendi-kendini-gelistiren-arac-sentezi.md), [29](29-derin-lsp-ve-canli-derleyici-entegrasyonu.md), [33](33-spatiotemporal-koefektler-ve-ters-islemler.md), [44](44-llm-egitim-uyumlu-arac-isimlendirmesi-grep-ve-tool-aliasing.md) |
| 46 | [AST ve Bağlam Motorunun Reaktif Coeffect Servisine Dönüştürülmesi](46-ast-ve-baglam-motorunun-reaktif-coeffect-servisine-donusturulmesi.md) | ✅ **Tamamlandı** | Kolay–Orta | Spatiotemporal Coeffect | 5 | [05](05-baglam-motoru-dosya-indeksi.md), [06](06-ast-semantik-indeks.md), [20](20-spatiotemporal-runtime-context-ve-fiber-yasam-dongusu.md), [33](33-spatiotemporal-koefektler-ve-ters-islemler.md), [39](39-asenkron-ve-kademeli-ast-onbellegi-persistent-lazy-indexing.md), [45](45-spatiotemporal-oz-evrilen-calisma-zamani-ve-otonom-adaptor-sentezi.md) |
| 47 | [Orchestrator Loop'un Reaktif Sistem Fiber'ına Dönüştürülmesi](47-orchestrator-loopun-reaktif-sistem-fiberina-donusturulmesi.md) | ✅ **Tamamlandı** | Orta | Reaktif Ajan Fiber Mimarisi | 5 | [10](10-ajan-dongusu-ve-arac-entegrasyonu.md), [20](20-spatiotemporal-runtime-context-ve-fiber-yasam-dongusu.md), [30](30-dinamik-llm-saglayicilari-ozel-endpointler-ve-baglam-limiti.md), [33](33-spatiotemporal-koefektler-ve-ters-islemler.md), [42](42-orchestrator-loop-dekompozisyonu-ve-llm-formatlayici.md), [45](45-spatiotemporal-oz-evrilen-calisma-zamani-ve-otonom-adaptor-sentezi.md), [46](46-ast-ve-baglam-motorunun-reaktif-coeffect-servisine-donusturulmesi.md) |
| 48 | [Harici Erişim İzinli Dizinler ve Sıfır-AST Sandbox Güvenlik Kapısı](48-harici-erisim-izinli-dizinler-ve-sifir-ast-sandbox-guvenlik-kapisi.md) | ✅ **Tamamlandı** | Kolay–Orta | Güvenlik & Sandbox | 5 | [03](03-bellek-ici-tampon-buffer-yonetimi.md), [12](12-guvenlik-denetimi-ve-onay-mekanizmasi.md), [13](13-izole-calistirma-process-sandbox.md), [19](19-gelismis-sandbox-ve-docker-wasm.md), [40](40-coklu-calisma-alani-ve-ek-kok-dizin-erisim-yonetimi.md), [46](46-ast-ve-baglam-motorunun-reaktif-coeffect-servisine-donusturulmesi.md) |
| 49 | [Tam Kapsamlı Cross-Platform Desteği ve Windows Uyumluluk Mimarisi](49-tam-kapsamli-cross-platform-ve-windows-uyumluluk-mimarisi.md) | ✅ **Tamamlandı** | Orta–Zor | Platform Bağımsızlığı & Çekirdek Dayanıklılık | 5 | [01](01-proje-iskeleti-ve-konfigurasyon.md), [02](02-repl-cekirdegi.md), [03](03-dosya-tamponu-snapshot-undo.md), [07](07-dil-adaptor-cercevesi.md), [12](12-guvenlik-diff-onay.md), [13](13-sandbox-izolasyon.md), [18](18-tree-sitter-ast-ve-lsp-entegrasyonu.md), [29](29-lsp-derin-entegrasyonu-tanilama-ve-reaktif-geri-bildirim.md), [40](40-coklu-calisma-alani-ve-ek-kok-dizin-erisim-yonetimi.md), [45](45-spatiotemporal-oz-evrilen-calisma-zamani-ve-otonom-adaptor-sentezi.md), [48](48-harici-erisim-izinli-dizinler-ve-sifir-ast-sandbox-guvenlik-kapisi.md) |
| 50 | [Varsayılan LLM Stream İletişimi, Canlı Token Akışı ve Çift Yönlü İptal Mimarisi](50-varsayilan-llm-stream-iletisimi-ve-canli-token-akisi.md) | ✅ **Tamamlandı** | Orta | Kullanıcı Talebi & `AGENTS.md` (§1, §3) | 5 | [02](02-repl-cekirdegi.md), [09](09-llm-saglayici-soyutlamasi.md), [10](10-tool-calling-orkestrasyon.md), [17](17-native-tool-calling-ve-model-yonlendirme.md), [23](23-xml-yapilandirilmis-baglam-ve-agents-protokol-entegrasyonu.md), [25](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md), [37](37-kademeli-verbosity-ayarlari-ve-canli-ajan-izleme.md), [42](42-orchestrator-loop-dekompozisyonu-ve-llm-formatlayici.md), [49](49-tam-kapsamli-cross-platform-ve-windows-uyumluluk-mimarisi.md) |
| 51 | [Display Katmanının Hibrit TUI Mimarisi](51-display-katmani-hibrit-tui-mimarisi.md) | ✅ **Tamamlandı** | Orta–Zor | Kullanıcı Talebi & Terminal UX | 6 | [02](02-repl-cekirdegi.md), [27](27-tampon-kirli-durum-hatirlatici-ve-akilli-ping-sistemi.md), [37](37-kademeli-verbosity-ayarlari-ve-canli-ajan-izleme.md), [41](41-repl-komut-modulerizasyonu-domain-driven-command-decoupling.md), [43](43-repl-bang-komut-standardizasyonu-ve-wiring-denetimi.md), [49](49-tam-kapsamli-cross-platform-ve-windows-uyumluluk-mimarisi.md), [50](50-varsayilan-llm-stream-iletisimi-ve-canli-token-akisi.md) |
| 52 | [Yerleşik Araçların Hızlandırılması: Native Offload ve Tembel Hash](52-yerlesik-arac-hizlandirma-native-offload-ve-lazy-hash.md) | ✅ **Tamamlandı** | Orta | Performans & Araç Hattı | 6 | [05](05-baglam-motoru-dosya-indeksi.md), [06](06-ast-semantik-indeks.md), [15](15-benchmark-kabul-testleri.md), [39](39-asenkron-ve-kademeli-ast-onbellegi-persistent-lazy-indexing.md), [44](44-llm-egitim-uyumlu-arac-isimlendirmesi-grep-ve-tool-aliasing.md), [46](46-ast-ve-baglam-motorunun-reaktif-coeffect-servisine-donusturulmesi.md), [49](49-tam-kapsamli-cross-platform-ve-windows-uyumluluk-mimarisi.md) |
| 53 | [Ajan Yüzeyi Kontratı: İzleyici Sınıflandırmalı Komut Görünürlüğü ve Genişletilmiş Ajan Erişimi](53-ajan-yuzeyi-kontrati-izleyici-siniflandirmali-komut-gorunurlugu.md) | ✅ **Tamamlandı** | Kolay–Orta | Ajan Yüzeyi & Kontrat (`AGENTS.md` §1, §3) | 5 | [10](10-tool-calling-orkestrasyon.md), [12](12-guvenlik-diff-onay.md), [21](21-llm-komut-sentezi-ve-calistirma.md), [36](36-repl-komut-ve-yerel-arac-ayrimi-ve-ajan-yonlendirme-guardrail.md), [41](41-repl-komut-modulerizasyonu-domain-driven-command-decoupling.md), [43](43-repl-bang-komut-standardizasyonu-ve-wiring-denetimi.md), [45](45-spatiotemporal-oz-evrilen-calisma-zamani-ve-otonom-adaptor-sentezi.md), [47](47-orchestrator-loopun-reaktif-sistem-fiberina-donusturulmesi.md) |
| 54 | [Kod Sağlığı ve Modülerlik: Dış Değerlendirme Bulgularının Karşılanması](54-kod-sagligi-ve-modulerlik-dis-degerlendirme-bulgulari.md) | ✅ **Tamamlandı** | Kolay → Orta–Zor | Bakım & Kod Sağlığı | 6 | [07](07-dil-adaptor-cercevesi.md), [41](41-repl-komut-modulerizasyonu-domain-driven-command-decoupling.md), [42](42-orchestrator-loop-dekompozisyonu-ve-llm-formatlayici.md), [45](45-spatiotemporal-oz-evrilen-calisma-zamani-ve-otonom-adaptor-sentezi.md), [46](46-ast-ve-baglam-motorunun-reaktif-coeffect-servisine-donusturulmesi.md), [47](47-orchestrator-loopun-reaktif-sistem-fiberina-donusturulmesi.md) |
| 55 | [run_command için Platform-Kapılı Kabuk Seçimi ve Ortam Yayını](55-run-command-platform-kapili-kabuk-secimi.md) | ✅ **Tamamlandı** | Orta | Sandbox & Ajan Deneyimi | 6 | [13](13-izole-calistirma-process-sandbox.md), [49](49-tam-kapsamli-cross-platform-ve-windows-uyumluluk-mimarisi.md), [54](54-kod-sagligi-ve-modulerlik-dis-degerlendirme-bulgulari.md) |
| 56 | [Frontier LLM Beklentileriyle Uyumlu Araç Kontratları, Elm Tarzı Yönlendirici Hata Mimarisi ve Hedefli Düzenleme (replace_file_content)](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md) | ✅ **Tamamlandı** | Orta | Ajan Ergonomisi & Araç Kalitesi | 6 | [10](10-ajan-dongusu-ve-arac-entegrasyonu.md), [16](16-genisletilmis-arac-seti-ve-planlama.md), [17](17-yerel-arac-cagrilari-ve-router.md), [32](32-agentic-tool-cagrilari-yapilandirilmis-io-ve-akilli-baglam-kirpma.md), [36](36-repl-komut-ve-yerel-arac-ayrimi-ve-ajan-yonlendirme-guardrail.md), [44](44-llm-egitim-uyumlu-arac-isimlendirmesi-grep-ve-tool-aliasing.md), [52](52-yerlesik-arac-hizlandirma-native-offload-ve-lazy-hash.md), [55](55-run-command-platform-kapili-kabuk-secimi.md) |
| 57 | [Sistem Sağlamlığı, Birleşik Tanılama Füzyonu (Diagnostic Fusion), E2E Entegrasyon Testleri ve Thread-Safe AST](57-sistem-saglamligi-birlesik-tanilama-fuzyonu-e2e-ve-thread-safety.md) | ✅ **Tamamlandı** | Orta–İleri Düzey | Sistem Sağlamlığı & Güvenilirlik | 6 | [03](03-bellek-ici-tampon-buffer-yonetimi.md), [06](06-ast-semantik-indeks.md), [08](08-statik-analiz-ve-derleyici-tanilama.md), [15](15-benchmark-kabul-testleri.md), [18](18-tree-sitter-ast-ve-lsp-entegrasyonu.md), [20](20-spatiotemporal-runtime-context-ve-fiber-yasam-dongusu.md), [25](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md), [29](29-derin-lsp-ve-canli-derleyici-entegrasyonu.md), [49](49-tam-kapsamli-cross-platform-ve-windows-uyumluluk-mimarisi.md), [54](54-kod-sagligi-ve-modulerlik-dis-degerlendirme-bulgulari.md), [56](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md) |
| 58 | [Elm Tarzı Empatik Sistem & İzin Hata Teşhisi, UTF-8 Serileştirme Bağışıklığı ve Hata Toleranslı Dizin Taraması](58-elm-tarzi-sistem-hatalari-utf8-bagisikligi-ve-hata-toleransli-tarama.md) | ✅ **Tamamlandı** | Kolay–Orta | Ajan Ergonomisi & Sistem Sağlamlığı | 6 | [05](05-baglam-motoru-dosya-indeksi.md), [12](12-guvenlik-diff-onay.md), [40](40-coklu-calisma-alani-ve-ek-kok-dizin-erisim-yonetimi.md), [48](48-harici-erisim-izinli-dizinler-ve-sifir-ast-sandbox-guvenlik-kapisi.md), [51](51-display-katmani-hibrit-tui-mimarisi.md), [56](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md), [57](57-sistem-saglamligi-birlesik-tanilama-fuzyonu-e2e-ve-thread-safety.md) |
| 59 | [Çekirdek Güvenliği, Sentez Sandbox Yalıtımı, Bare Rescue İyileştirmeleri ve Modüler Test Görevleri](59-cekirdek-guvenligi-sentez-sandbox-bare-rescue-ve-moduler-testler.md) | ✅ **Tamamlandı** | Kolay–Orta | Kod Sağlığı & Güvenlik Sertleştirme | 6 | [03](03-bellek-ici-tampon-buffer-yonetimi.md), [10](10-ajan-dongusu-ve-arac-entegrasyonu.md), [12](12-guvenlik-diff-onay.md), [20](20-spatiotemporal-runtime-context-ve-fiber-yasam-dongusu.md), [24](24-kendi-kendini-gelistiren-arac-sentezi.md), [45](45-spatiotemporal-oz-evrilen-calisma-zamani-ve-otonom-adaptor-sentezi.md), [49](49-tam-kapsamli-cross-platform-ve-windows-uyumluluk-mimarisi.md), [54](54-kod-sagligi-ve-modulerlik-dis-degerlendirme-bulgulari.md), [57](57-sistem-saglamligi-birlesik-tanilama-fuzyonu-e2e-ve-thread-safety.md), [58](58-elm-tarzi-sistem-hatalari-utf8-bagisikligi-ve-hata-toleransli-tarama.md) |
| 60 | [Kritik Yol Yazma Güvenliği (Guard Entegrasyonu), Dinamik Sandbox Timeout ve Kod Sağlığı İyileştirmeleri](60-kritik-yol-guvenligi-sandbox-timeout-ve-kod-sagligi.md) | ✅ **Tamamlandı** | Orta | Güvenlik Sertleştirmesi & Kod Sağlığı | 6 | [03](03-bellek-ici-tampon-buffer-yonetimi.md), [12](12-guvenlik-diff-onay.md), [13](13-izole-calistirma-process-sandbox.md), [19](19-container-ve-wasm-sandbox-izolasyonu.md), [24](24-kendi-kendini-gelistiren-arac-sentezi.md), [41](41-repl-komut-modulerizasyonu-domain-driven-command-decoupling.md), [48](48-harici-erisim-izinli-dizinler-ve-sifir-ast-sandbox-guvenlik-kapisi.md), [49](49-tam-kapsamli-cross-platform-ve-windows-uyumluluk-mimarisi.md), [54](54-kod-sagligi-ve-modulerlik-dis-degerlendirme-bulgulari.md), [56](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md), [57](57-sistem-saglamligi-birlesik-tanilama-fuzyonu-e2e-ve-thread-safety.md), [58](58-elm-tarzi-sistem-hatalari-utf8-bagisikligi-ve-hata-toleransli-tarama.md), [59](59-cekirdek-guvenligi-sentez-sandbox-bare-rescue-ve-moduler-testler.md) |
| 61 | [LLM Bağlam Sürekliliği: Hata Turlarında Context Kaydı, Model Geçiş Tutarlılığı ve Stream/Assembly Bütünlüğü](61-llm-baglam-surekliligi-hata-turlerinde-kayit-ve-stream-butunlugu.md) | ✅ **Tamamlandı** | Orta–Zor | Bağlam Sürekliliği & Stream Bütünlüğü | 6 | [17](17-yerel-arac-cagrilari-ve-router.md), [30](30-dinamik-llm-saglayicilari-ozel-endpointler-ve-baglam-limiti.md), [31](31-agentic-adim-butcesi-ve-dinamik-genisletme.md), [32](32-agentic-tool-cagrilari-yapilandirilmis-io-ve-akilli-baglam-kirpma.md), [34](34-spatiotemporal-oturum-kaliciligi-ve-aninda-hafiza-yukleme.md), [35](35-baglam-sikistirma-token-tahmini-ve-otomatik-truncation-politikasi.md), [42](42-orchestrator-loop-dekompozisyonu-ve-llm-formatlayici.md), [50](50-varsayilan-llm-stream-iletisimi-ve-canli-token-akisi.md), [57](57-sistem-saglamligi-birlesik-tanilama-fuzyonu-e2e-ve-thread-safety.md) |
| 62 | [RuboCop Sıfır-Uyarı Temizliği: Davranış-Koruyucu Kademeli Strateji](62-rubocop-sifir-uyari-temizligi-davranis-koruyucu-kademeli-strateji.md) | ✅ **Tamamlandı** | Orta (geniş ama mekanik) | Kod Sağlığı & Lint Sıfırlama | 6 | [54](54-kod-sagligi-ve-modulerlik-dis-degerlendirme-bulgulari.md), [57](57-sistem-saglamligi-birlesik-tanilama-fuzyonu-e2e-ve-thread-safety.md), [59](59-cekirdek-guvenligi-sentez-sandbox-bare-rescue-ve-moduler-testler.md), [60](60-kritik-yol-guvenligi-sandbox-timeout-ve-kod-sagligi.md), [61](61-llm-baglam-surekliligi-hata-turlerinde-kayit-ve-stream-butunlugu.md) |
| 63 | [Dış Değerlendirme Tavsiye Triyajı: Kademeli Acil Sıkıştırma, Shell Kompozisyonu ve Maskeleme Hassasiyeti](63-dis-degerlendirme-tavsiye-triyaji-ve-davranis-koruyucu-iyilestirmeler.md) | ✅ **Tamamlandı** | Orta | Dış Değerlendirme ("Potential Concerns") | 6 | [35](35-baglam-sikistirma-token-tahmini-ve-otomatik-truncation-politikasi.md), [41](41-repl-komut-modulerizasyonu-domain-driven-command-decoupling.md), [54](54-kod-sagligi-ve-modulerlik-dis-degerlendirme-bulgulari.md), [59](59-cekirdek-guvenligi-sentez-sandbox-bare-rescue-ve-moduler-testler.md), [61](61-llm-baglam-surekliligi-hata-turlerinde-kayit-ve-stream-butunlugu.md), [62](62-rubocop-sifir-uyari-temizligi-davranis-koruyucu-kademeli-strateji.md) |
| 64 | [Overlay Yükleme Bütünlük Kapısı ve eval Güvenliği](64-overlay-yukleme-butunluk-kapisi-ve-eval-guvenligi.md) | ✅ **Tamamlandı** | Orta | Dış Değerlendirme (Overlay `eval` Yük Yolu) | 5 | [21](21-llm-komut-sentezi-ve-calistirma.md), [24](24-kendi-kendine-evrilen-arac-sentezi-ve-calisma-zamani-denetimi.md), [59](59-cekirdek-guvenligi-sentez-sandbox-bare-rescue-ve-moduler-testler.md), [60](60-kritik-yol-guvenligi-sandbox-timeout-ve-kod-sagligi.md), [63](63-dis-degerlendirme-tavsiye-triyaji-ve-davranis-koruyucu-iyilestirmeler.md) |
| 65 | [Plugin ↔ Runtime Fiber Köprüsü ve Alias Sağlamlaştırma](65-plugin-runtime-fiber-koprusu-ve-alias-saglamlastirma.md) | ✅ **Tamamlandı** | Orta–Zor | Dış Değerlendirme (Plugin Sistemi & Alias) | 5 | [14](14-eklenti-sistemi.md), [20](20-spatiotemporal-composability-eklenti-dongusu.md), [33](33-spatiotemporal-coeffect-inverses-ve-runtime-gorsellestirme.md), [63](63-dis-degerlendirme-tavsiye-triyaji-ve-davranis-koruyucu-iyilestirmeler.md) |
| 66 | [Config Modülerleştirme: Davranış-Koruyucu Sorumluluk Ayırımı](66-config-modulerlestirme-davranis-koruyucu-ayrisim.md) | ✅ **Tamamlandı** | Orta | Dış Değerlendirme (Config Karmaşıklığı) | 5 | [01](01-proje-iskeleti-ve-konfigurasyon.md), [25](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md), [62](62-rubocop-sifir-uyari-temizligi-davranis-koruyucu-kademeli-strateji.md), [63](63-dis-degerlendirme-tavsiye-triyaji-ve-davranis-koruyucu-iyilestirmeler.md) |
| 67 | [Tanı Geri-Besleme Hattı: ExecutionFailure'ın Ajan Döngüsüne Akışı](67-tani-geri-besleme-hatti-executionfailure-ajan-dongusu.md) | ✅ **Tamamlandı** | Kolay–Orta | Dış Değerlendirme (DiagnosticEngine & Test Runner) | 5 | [08](08-hata-ayristirma-teshis.md), [11](11-kendi-kendine-onarim.md), [22](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md), [57](57-sistem-saglamligi-birlesik-tanilama-fuzyonu-e2e-ve-thread-safety.md), [63](63-dis-degerlendirme-tavsiye-triyaji-ve-davranis-koruyucu-iyilestirmeler.md) |
| 68 | [Sıfır-Kurulum Kullanıcı Eklenti Mimarisi: Drop-in Dizinler, Reaktif Fiber Yaşam Döngüsü ve !plugin Yönetim Hattı](68-sifir-kurulum-kullanici-eklenti-mimarisi-dropin-dizinler-ve-yonetim-hatti.md) | ✅ **Tamamlandı** | Orta–Zor | Dış Değerlendirme (Zero-Install Plugin System) | 5 | [14](14-eklenti-sistemi.md), [20](20-spatiotemporal-composability-eklenti-dongusu.md), [24](24-kendi-kendini-gelistiren-arac-sentezi.md), [33](33-spatiotemporal-coeffect-inverses-ve-runtime-gorsellestirme.md), [64](64-overlay-yukleme-butunluk-kapisi-ve-eval-guvenligi.md), [65](65-plugin-runtime-fiber-koprusu-ve-alias-saglamlastirma.md) |
| 69 | [Kapsamlı Dokümantasyon Mimarisi: 20 Çekirdek Domain, Standart Ajan Araçları Kataloğu ve LLM Otonom Öz-Evrim Rehberi](69-kapsamli-dokumantasyon-mimarisi-domainler-araclar-ve-llm-oz-evrim-rehberi.md) | ✅ **Tamamlandı** | Orta | Dokümantasyon & LLM Öz-Evrim | 6 | [24](24-kendi-kendine-evrilen-arac-sentezi-ve-calisma-zamani-denetimi.md), [51](51-display-tui-ve-cikis-bicimlendirme-katmani.md), [54](54-built-in-araclar-ve-orkestrasyon-altyapisi-temizligi.md), [56](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md), [63](63-repl-kabuk-mimarisi-ayrisimi-composition-build.md), [68](68-sifir-kurulum-kullanici-eklenti-mimarisi-dropin-dizinler-ve-yonetim-hatti.md) |
| 70 | [WriteFileTool Çöp Yol Koruması: 0-Byte Garbage Dosyalarının Önlenmesi](70-write-file-garbage-path-korumasi.md) | ✅ **Tamamlandı** | Kolay–Orta | Tools / Buffer Safety | 5 | [03](03-dosya-tamponu-snapshot-undo.md), [48](48-harici-erisim-izinli-dizinler-ve-sifir-ast-sandbox-guvenlik-kapisi.md), [56](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md), [60](60-kritik-yol-guvenligi-sandbox-timeout-ve-kod-sagligi.md) |
| 71 | [Çalışma Zamanı Sağlamlaştırma: LSP Devre Kesici, Buffer Thread-Safety, Sentez Guard Hardening ve İzole Runtime Testleri](71-calisma-zamani-saglamlastirma-lsp-devre-kesici-buffer-thread-safety-ve-izole-testler.md) | ✅ **Tamamlandı** | Orta–Zor | Dış Değerlendirme (Runtime & Thread Safety) | 5 | [20](20-spatiotemporal-composability-eklenti-dongusu.md), [29](29-lsp-derin-entegrasyonu-tanilama-ve-reaktif-geri-bildirim.md), [03](03-dosya-tamponu-snapshot-undo.md), [64](64-overlay-yukleme-butunluk-kapisi-ve-eval-guvenligi.md), [69](69-kapsamli-dokumantasyon-mimarisi-domainler-araclar-ve-llm-oz-evrim-rehberi.md), [70](70-write-file-garbage-path-korumasi.md) |
| 72 | [Overlay Bootstrap Güven Kapısı, Yükleme Hata Görünürlüğü ve kill_tree Sıkılaştırma](72-overlay-bootstrap-guven-kapisi-yukleme-hata-gorunurlugu-ve-kill-tree-saglamlastirma.md) | ✅ **Tamamlandı** | Orta | Dış Değerlendirme (Overlay Trust & Hardening) | 4 | [63](63-dis-degerlendirme-tavsiye-triyaji-ve-davranis-koruyucu-iyilestirmeler.md), [64](64-overlay-yukleme-butunluk-kapisi-ve-eval-guvenligi.md), [68](68-sifir-kurulum-kullanici-eklenti-mimarisi-dropin-dizinler-ve-yonetim-hatti.md), [71](71-calisma-zamani-saglamlastirma-lsp-devre-kesici-buffer-thread-safety-ve-izole-testler.md) |
| 73 | [Araç Katmanı Sertleştirme, Kapsülleme İyileştirmeleri ve Deterministik Hata Ayrıştırma](73-arac-katmani-sertlestirme-kapsulleme-ve-hata-ayristirma.md) | ✅ **Tamamlandı** | Kolay–Orta | Ajan Ergonomisi & Kod Sağlığı | 6 | [10](10-tool-calling-orkestrasyon.md), [17](17-yerel-arac-cagrilari-ve-router.md), [20](20-spatiotemporal-runtime-context-ve-fiber-yasam-dongusu.md), [24](24-kendi-kendine-evrilen-arac-sentezi-ve-calisma-zamani-denetimi.md), [54](54-kod-sagligi-ve-modulerlik-dis-degerlendirme-bulgulari.md), [56](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md), [58](58-elm-tarzi-sistem-hatalari-utf8-bagisikligi-ve-hata-toleransli-tarama.md) |
| 74 | [Endüstri Standardı SSE Streaming Ayrıştırması, Düşünce Akışı (Reasoning) Entegrasyonu, Kesilme Teşhisi ve Özelleştirilebilir İletişim Hattı](74-endustri-standardi-sse-stream-reasoning-ve-iletisim-hatti.md) | ✅ **Tamamlandı** | Orta | İletişim Sağlamlığı & Ergonomi | 6 | [09](09-llm-saglayici-soyutlamasi.md), [17](17-yerel-arac-cagrilari-ve-router.md), [22](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md), [30](30-dinamik-llm-saglayicilari-ozel-endpointler-ve-baglam-limiti.md), [42](42-orchestrator-loop-dekompozisyonu-ve-llm-formatlayici.md), [61](61-llm-baglam-surekliligi-hata-turlerinde-kayit-ve-stream-butunlugu.md), [73](73-arac-katmani-sertlestirme-kapsulleme-ve-hata-ayristirma.md) |
| 75 | [Reaktif Yapılandırma Gözlemcisi, Sistem Geneli Değişken/Knob Kablolaması ve Sıfır Kesintili Canlı Rekonfigürasyon](75-reaktif-yapilandirma-gozlemcisi-sistem-geneli-knob-kablolamasi-ve-canli-rekonfigurasyon.md) | 🟢 **Tamamlandı** | Orta | Reaktivite & Çalışma Zamanı Sağlamlığı | 6 | [01](01-proje-iskeleti-ve-konfigurasyon.md), [13](13-sandbox-izolasyon.md), [20](20-spatiotemporal-composability-eklenti-dongusu.md), [25](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md), [28](28-olay-gudumlu-reaktif-baglam-ast-ve-akilli-calisma-alani-agaci.md), [47](47-orchestrator-loopun-reaktif-sistem-fiberina-donusturulmesi.md), [74](74-endustri-standardi-sse-stream-reasoning-ve-iletisim-hatti.md) |
| 76 | [LSP Tam Zamanında (JIT) Buffer Senkronizasyonu, Oturum Araç Kütüğü, Modern Web Adaptörü (Node/TS/Vue) ve Halüsinasyon Kırıcı Teşhis Hattı](76-lsp-buffer-jit-senkronizasyonu-oturum-arac-kaydi-ve-modern-web-adaptoru.md) | 🟢 **Tamamlandı** | İleri | Ajan Ergonomisi & Çok Dilli Destek | 6 | [13](13-sandbox-izolasyon.md), [29](29-lsp-derin-entegrasyonu-tanilama-ve-reaktif-geri-bildirim.md), [34](34-spatiotemporal-oturum-kaliciligi-ve-aninda-hafiza-yukleme.md), [48](48-harici-erisim-izinli-dizinler-ve-sifir-ast-sandbox-guvenlik-kapisi.md), [56](56-lsp-arka-plan-yonetimi-ve-reaktif-tanilama.md), [58](58-elm-tarzi-sistem-hatalari-utf8-bagisikligi-ve-hata-toleransli-tarama.md), [73](73-arac-katmani-sertlestirme-kapsulleme-ve-hata-ayristirma.md), [75](75-reaktif-yapilandirma-gozlemcisi-sistem-geneli-knob-kablolamasi-ve-canli-rekonfigurasyon.md) |
| 77 | [Tampon Çakışma Tespiti (`@original_hashes` Canlandırması), Gerçek Unified Diff ve Genel Audit Tamirleri](77-tampon-cekisme-tespiti-gercek-unified-diff-ve-genel-audit-tamiri.md) | 🟢 **Tamamlandı** | Orta–İleri | Tampon Bütünlüğü & Genel Sağlamlık | 6 | [03](03-dosya-tamponu-snapshot-undo.md), [70](70-write-file-garbage-path-korumasi.md), [71](71-calisma-zamani-saglamlastirma-lsp-devre-kesici-buffer-thread-safety-ve-izole-testler.md), [73](73-arac-katmani-sertlestirme-kapsulleme-ve-hata-ayristirma.md), [75](75-reaktif-yapilandirma-gozlemcisi-sistem-geneli-knob-kablolamasi-ve-canli-rekonfigurasyon.md), [76](76-lsp-buffer-jit-senkronizasyonu-oturum-arac-kaydi-ve-modern-web-adaptoru.md) |
| 78 | [Çalışma Zamanı Thread-Safety, Arka Plan AST Teşhis Kalkanı, LSP Kapsülleme Tamiri ve Sandbox Ağ Sertleştirmesi](78-calisma-zamani-thread-safety-ast-teshis-ve-kapsulleme-tamiri.md) | 🟢 **Tamamlandı** | Kolay–Orta | Concurrency & Kapsülleme | 6 | [20](20-spatiotemporal-composability-eklenti-dongusu.md), [71](71-calisma-zamani-saglamlastirma-lsp-devre-kesici-buffer-thread-safety-ve-izole-testler.md), [73](73-arac-katmani-sertlestirme-kapsulleme-ve-hata-ayristirma.md), [76](76-lsp-buffer-jit-senkronizasyonu-oturum-arac-kaydi-ve-modern-web-adaptoru.md), [77](77-tampon-cekisme-tespiti-gercek-unified-diff-ve-genel-audit-tamiri.md) |
| 79 | [Güvenlik Başlatma İzolasyonu (Lazy-Init Guard), Sandbox İzolasyon Şeffaflığı, REPL !sh Entegrasyonu ve Kod Tabanı Kozmetik Sertleştirmesi](79-guvenlik-baslatma-izolasyonu-sandbox-seffafligi-ve-repl-sh-tamiri.md) | 🟢 **Tamamlandı** | Kolay–Orta | Güvenlik & Şeffaflık | 6 | [12](12-guvenlik-diff-onay.md), [13](13-sandbox-izolasyon.md), [19](19-container-ve-wasm-sandbox-izolasyonu.md), [71](71-calisma-zamani-saglamlastirma-lsp-devre-kesici-buffer-thread-safety-ve-izole-testler.md), [78](78-calisma-zamani-thread-safety-ast-teshis-ve-kapsulleme-tamiri.md) |

---

## 🕸️ Güncel Bağımlılık Grafı (DAG)

```text
                  ┌── 02 (REPL) ─── 04 (Session/Replay) ──┬── 21 (LLM REPL Exec & Synthesize) ─── 22 (Situational Awareness) ──► 23 (XML Context & Stream)
                  │                                        │                                                                             │
                  ├── 03 (Buffer) ─┬─ 12 (Security) ─── 19 (Docker/Wasm Sandbox) ✅                                                      ▼
                  │                └─ 04 (Session)                                                                          24 (Self-Evolving Tool Synthesis)
01 (Skeleton) ────┼── 05 (Index) ──── 06 (AST Graph) ── 18 (Tree-sitter & LSP) ✅                                                         │
                  │                       │                                                                                              ▼
                  ├── 07 (Adapters) ─┬─── 08 (Diagnostics) ─── 11 (Self-Repair)                                            25 (Persistent Config & Auto-Save)
                  │                  └─── 13 (Process Sandbox)                                                                           │
                  │                                                                                                                      ▼
                  └── 09 (LLM) ────── 10 (Tool-Calling) ──┬── 16 (Expanded Tools, !plan & !goal) ✅                           26 (Workspace Session & -c Resume)
                                           │              ├── 17 (Native Tool-Calling & Router) ✅                                       │
                                           │              └── 20 (Spatiotemporal Runtime) ──┘ ✅                                        ▼
                                           └── 14 (Plugins) ─┘                                                      27 (Dirty Buffer Reminder & Auto-Apply) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             28 (Reactive Context, AST & Smart File Tree) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             29 (LSP Deep Integration & Live Diagnostics) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             30 (Dynamic LLM Providers & Context Budget) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             31 (Agentic Step Budget & Dynamic Extension) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             32 (Structured Tool I/O & Context Truncation) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             33 (Spatiotemporal Coeffects & Inverses) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             34 (Zero-Token Session Hydration & Continuity) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             35 (Context Compactor & Dynamic Token Budget) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             36 (REPL Command vs Native Tool Guardrail) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             37 (Graduated Verbosity & Live Step Formatter) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             38 (YAML::Store Transactional Config) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             39 (Async & Persistent AST Indexing) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             40 (Multi-Workspace & Additional Roots) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             41 (REPL Command Decoupling) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             42 (Loop Decomposition & LLM Formatter) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             43 (REPL Commands Standardization & Wiring) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             44 (Canonical Tool Naming & Grep Aliasing) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             45 (Self-Evolving Runtime & Dynamic Adapters) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             46 (AST & Index Reactive Coeffects) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             47 (Agent Loop Reactive Fiber) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             48 (External Allowed Dirs & Zero-AST Sandbox) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                              49 (Cross-Platform & Windows Architecture) ✅
                                                                                                                                   │
                                                                                                                                   ▼
                                                                                                                50 (Default LLM Stream & Live Token Flow) ✅
                                                                                                                                   │
                                                                                                                                   ▼
                                                                                                                51 (Hybrid TUI Display Layer) ✅
                                                                                                                                   │
                                                                                                                                   ▼
                                                                                                                52 (Native Tool Offload & Lazy Hash) ✅
                                                                                                                                   │
                                                                                                                                   ▼
                                                                                                                53 (Agent Surface Contract & Audience-Classified Commands) ✅
                                                                                                                                   │
                                                                                                                                   ▼
                                                                                                                54 (Code Health & Modularity — External Review) ✅
                                                                                                                                   │
                                                                                                                                   ▼
                                                                                                                 55 (Platform-Gated Shell Selection) ✅
                                                                                                                                   │
                                                                                                                                   ▼
                                                                                                            56 (Frontier Tool Contracts & Elm Diagnostics) ✅
                                                                                                                              │
                                                                                                                              ▼
                                                                                                        57 (System Robustness & Diagnostic Fusion) ✅
                                                                                                                              │
                                                                                                                              ▼
                                                                                                          58 (Elm System Diagnostics & UTF-8 Resilience) ✅
                                                                                                                               │
                                                                                                                               ▼
                                                                                                          59 (Synthesis Security & Modular Tests) ✅
                                                                                                                               │
                                                                                                                               ▼
                                                                                                          60 (Critical Write Guard & Sandbox Timeout) ✅
                                                                                                                               │
                                                                                                                               ▼
                                                                                             61 (LLM Context Continuity & Stream Integrity) ✅
                                                                                                                               │
                                                                                                                               ▼
                                                                                             62 (RuboCop Zero-Warning Cleanup) ✅
                                                                                                                               │
                                                                                                                               ▼
                                                                                             63 (External Review Triage & Hardening) ✅
                                                                                                                               │
                  ┌──────────────────────────────┬─────────────────────────┴───────┬────────────────────────────┐
                  ▼                              ▼                                 ▼                            ▼
64 (Overlay Integrity Gate) ✅   65 (Plugin–Runtime Fiber Bridge) ✅   66 (Config Split) ✅   67 (Diagnostic Feedback Loop) ✅
                  │                              │                                 │                            │
                  └──────────────────────────────┴────────────────┬────────────────┘                            │
| 71 | [Çalışma Zamanı Sağlamlaştırma: LSP Devre Kesici, Buffer Thread-Safety, Sentez Guard Hardening ve İzole Runtime Testleri](71-calisma-zamani-saglamlastirma-lsp-devre-kesici-buffer-thread-safety-ve-izole-testler.md) | ⏳ **Planlandı** | Orta–Zor | Dış Değerlendirme (Runtime & Thread Safety) | 5 | [20](20-spatiotemporal-composability-eklenti-dongusu.md), [29](29-lsp-derin-entegrasyonu-tanilama-ve-reaktif-geri-bildirim.md), [03](03-dosya-tamponu-snapshot-undo.md), [64](64-overlay-yukleme-butunluk-kapisi-ve-eval-guvenligi.md), [69](69-kapsamli-dokumantasyon-mimarisi-domainler-araclar-ve-llm-oz-evrim-rehberi.md), [70](70-write-file-garbage-path-korumasi.md) |

---

## 🕸️ Güncel Bağımlılık Grafı (DAG)

```text
                  ┌── 02 (REPL) ─── 04 (Session/Replay) ──┬── 21 (LLM REPL Exec & Synthesize) ─── 22 (Situational Awareness) ──► 23 (XML Context & Stream)
                  │                                        │                                                                             │
                  ├── 03 (Buffer) ─┬─ 12 (Security) ─── 19 (Docker/Wasm Sandbox) ✅                                                      ▼
                  │                └─ 04 (Session)                                                                          24 (Self-Evolving Tool Synthesis)
01 (Skeleton) ────┼── 05 (Index) ──── 06 (AST Graph) ── 18 (Tree-sitter & LSP) ✅                                                         │
                  │                       │                                                                                              ▼
                  ├── 07 (Adapters) ─┬─── 08 (Diagnostics) ─── 11 (Self-Repair)                                            25 (Persistent Config & Auto-Save)
                  │                  └─── 13 (Process Sandbox)                                                                           │
                  │                                                                                                                      ▼
                  └── 09 (LLM) ────── 10 (Tool-Calling) ──┬── 16 (Expanded Tools, !plan & !goal) ✅                           26 (Workspace Session & -c Resume)
                                           │              ├── 17 (Native Tool-Calling & Router) ✅                                       │
                                           │              └── 20 (Spatiotemporal Runtime) ──┘ ✅                                        ▼
                                           └── 14 (Plugins) ─┘                                                      27 (Dirty Buffer Reminder & Auto-Apply) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             28 (Reactive Context, AST & Smart File Tree) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             29 (LSP Deep Integration & Live Diagnostics) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             30 (Dynamic LLM Providers & Context Budget) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             31 (Agentic Step Budget & Dynamic Extension) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             32 (Structured Tool I/O & Context Truncation) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             33 (Spatiotemporal Coeffects & Inverses) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             34 (Zero-Token Session Hydration & Continuity) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             35 (Context Compactor & Dynamic Token Budget) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             36 (REPL Command vs Native Tool Guardrail) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             37 (Graduated Verbosity & Live Step Formatter) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             38 (YAML::Store Transactional Config) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             39 (Async & Persistent AST Indexing) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             40 (Multi-Workspace & Additional Roots) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             41 (REPL Command Decoupling) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             42 (Loop Decomposition & LLM Formatter) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             43 (REPL Commands Standardization & Wiring) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             44 (Canonical Tool Naming & Grep Aliasing) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             45 (Self-Evolving Runtime & Dynamic Adapters) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             46 (AST & Index Reactive Coeffects) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             47 (Agent Loop Reactive Fiber) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                             48 (External Allowed Dirs & Zero-AST Sandbox) ✅
                                                                                                                                  │
                                                                                                                                  ▼
                                                                                                              49 (Cross-Platform & Windows Architecture) ✅
                                                                                                                                   │
                                                                                                                                   ▼
                                                                                                                50 (Default LLM Stream & Live Token Flow) ✅
                                                                                                                                   │
                                                                                                                                   ▼
                                                                                                                51 (Hybrid TUI Display Layer) ✅
                                                                                                                                   │
                                                                                                                                   ▼
                                                                                                                52 (Native Tool Offload & Lazy Hash) ✅
                                                                                                                                   │
                                                                                                                                   ▼
                                                                                                                53 (Agent Surface Contract & Audience-Classified Commands) ✅
                                                                                                                                   │
                                                                                                                                   ▼
                                                                                                                54 (Code Health & Modularity — External Review) ✅
                                                                                                                                   │
                                                                                                                                   ▼
                                                                                                                 55 (Platform-Gated Shell Selection) ✅
                                                                                                                                   │
                                                                                                                                   ▼
                                                                                                            56 (Frontier Tool Contracts & Elm Diagnostics) ✅
                                                                                                                              │
                                                                                                                              ▼
                                                                                                        57 (System Robustness & Diagnostic Fusion) ✅
                                                                                                                              │
                                                                                                                              ▼
                                                                                                          58 (Elm System Diagnostics & UTF-8 Resilience) ✅
                                                                                                                               │
                                                                                                                               ▼
                                                                                                          59 (Synthesis Security & Modular Tests) ✅
                                                                                                                               │
                                                                                                                               ▼
                                                                                                          60 (Critical Write Guard & Sandbox Timeout) ✅
                                                                                                                               │
                                                                                                                               ▼
                                                                                             61 (LLM Context Continuity & Stream Integrity) ✅
                                                                                                                               │
                                                                                                                               ▼
                                                                                             62 (RuboCop Zero-Warning Cleanup) ✅
                                                                                                                               │
                                                                                                                               ▼
                                                                                             63 (External Review Triage & Hardening) ✅
                                                                                                                               │
                  ┌──────────────────────────────┬─────────────────────────┴───────┬────────────────────────────┐
                  ▼                              ▼                                 ▼                            ▼
64 (Overlay Integrity Gate) ✅   65 (Plugin–Runtime Fiber Bridge) ✅   66 (Config Split) ✅   67 (Diagnostic Feedback Loop) ✅
                  │                              │                                 │                            │
                  └──────────────────────────────┴────────────────┬────────────────┘                            │
                                                                  ▼                                             │
                                                68 (Drop-in Plugin Architecture) ✅ ────────────────────────────┘
                                                                  │
                                                                  ▼
                                                69 (Comprehensive Documentation & Self-Evolution Architecture) ✅
                                                                  │
                                                                  ▼
                                                 70 (WriteFileTool Garbage Path Protection) ✅
                                                                  │
                                                                  ▼
                                                 71 (Runtime Hardening, LSP Circuit Breaker, Buffer Thread-Safety & Isolated Tests) ✅
                                                                  │
                                                                  ▼
                                                  72 (Overlay Bootstrap Trust Gate, Load Error Visibility & kill_tree) ✅
                                                                   │
                                                                   ▼
                                                   73 (Tool Layer Hardening & Encapsulation Refactor) ✅
                                                                    │
                                                                    ▼
                                                    74 (W3C SSE Streaming, Reasoning & Resilient Bus) ✅
                                                                     │
                                                                     ▼
                                                     75 (Reactive Config Observer & System-wide Knob Wiring) ✅
                                                                      │
                                                                      ▼
                                                      76 (LSP JIT Buffer Sync, Session Recorder Toolbelt & Web Adapter) ✅
                                                                       │
                                                                       ▼
                                                        77 (Buffer Conflict Gate, Real Unified Diff & Audit Fixes) ✅
                                                                        │
                                                                        ▼
                                                        78 (Runtime Thread-Safety, AST Shield & Encapsulation) ✅
                                                                        │
                                                                        ▼
                                                        79 (Lazy Guard Init, Sandbox Transparency & REPL !sh) ✅

15 (Benchmark & Acceptance) ──► Tüm planları doğrular.
```
