# 🗺️ Rubik Implementasyon Planları — Ana İndeks

> **Kaynak:** `_proposal/rubik-codingAgent-mainProposal.md` (v1.2)  
> **Protokol:** [`AGENTS.md`](../AGENTS.md) — *Protocol for Spatiotemporal Composability & Self-Evolving Runtimes*  
> **Son Güncelleme:** 24 Ağustos 2026

Planlar **semantik birimlere** ayrılmıştır; 39 planın tümü tamamlanmıştır.

---

## 📊 Plan Listesi ve Uygulama Durumu (39/39 TAMAMLANDI 🚀)

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
| 24 | [Kendi Kendine Evrilen Araç Sentezi ve Çalışma Zamanı Denetimi](24-kendi-kendine-evrilen-arac-sentezi-ve-calisma-zamani-denetimi.md) | ✅ **Tamamlandı** | Zor | `AGENTS.md` (§1–§6) | 5 | [20](20-spatiotemporal-composability-eklenti-dongusu.md), [21](21-llm-komut-sentezi-ve-calistirma.md), [23](23-xml-yapilandirilmis-baglam-ve-agents-protokol-entegrasyonu.md) |
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

15 (Benchmark & Acceptance) ──► Tüm planları doğrular.
```
