# 🗺️ Rubik Implementasyon Planları — Ana İndeks

> **Kaynak:** `_proposal/rubik-codingAgent-mainProposal.md` (v1.2)  
> **Protokol:** [`AGENTS.md`](../AGENTS.md) — *Protocol for Spatiotemporal Composability & Self-Evolving Runtimes*  
> **Son Güncelleme:** 23 Ağustos 2026

Planlar **semantik birimlere** ayrılmıştır; her birim bağımsız test edilebilir ve kendi kabul kriterlerine sahiptir.

---

## 📊 Plan Listesi ve Uygulama Durumu

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
| 18 | [Tree-sitter Çok Dilli Semantik AST ve LSP](18-tree-sitter-ast-ve-lsp-entegrasyonu.md) | 🚀 **Sıradaki** | Zor | §7.2 | 3–4 | [06](06-ast-semantik-indeks.md), [07](07-dil-adaptor-cercevesi.md), [16](16-genisletilmis-arac-seti-ve-planlama.md) |
| 19 | [Container (Docker) ve Wasm Sandbox İzolasyonu](19-container-ve-wasm-sandbox-izolasyonu.md) | 🚀 **Sıradaki** | Zor | §9.1 | 4 | [13](13-sandbox-izolasyon.md), [12](12-guvenlik-diff-onay.md) |
| 20 | [Spatiotemporal Composability & Eklenti Döngüsü](20-spatiotemporal-composability-eklenti-dongusu.md) | 🚀 **Sıradaki** | Zor | `AGENTS.md` | 5 | [14](14-eklenti-sistemi.md), [10](10-tool-calling-orkestrasyon.md), [AGENTS.md](../AGENTS.md) |

---

## 🕸️ Güncel Bağımlılık Grafı (DAG)

```text
                  ┌── 02 (REPL) ─── 04 (Session/Replay)
                  │
                  ├── 03 (Buffer) ─┬─ 12 (Security) ─── 19 (Docker/Wasm Sandbox)
                  │                └─ 04 (Session)
01 (Skeleton) ────┼── 05 (Index) ──── 06 (AST Graph) ── 18 (Tree-sitter & LSP)
                  │                       │
                  ├── 07 (Adapters) ─┬─── 08 (Diagnostics) ─── 11 (Self-Repair)
                  │                  └─── 13 (Process Sandbox)
                  │
                  └── 09 (LLM) ────── 10 (Tool-Calling) ──┬── 16 (Expanded Tools, !plan & !goal) ✅
                                           │              ├── 17 (Native Tool-Calling & Router) ✅
                                           │              └── 20 (Spatiotemporal Runtime)
                                           └── 14 (Plugins) ─┘

15 (Benchmark & Acceptance) ──► Tüm planları doğrular.
```

---

## 🛤️ Geliştirme Hatları ve Yol Haritası

1. **Çekirdek Tamamlama (Faz 1 & MVP):**
   - Plan 01–15 başarıyla birleştirildi (`main` dalında aktif).
2. **Akıllı Otonomi ve Model Yönlendirme (Faz 2–3):**
   - **Plan 16 (Tamamlandı):** `list_files`, `search_symbols`, `run_tests`, `run_command` araçları, SSoT kayıt fabrikası, `!plan` ve `!goal` otonom orkestrasyonu.
   - **Plan 17 (Tamamlandı):** OpenAI/Anthropic/Ollama yerel native tool calling API ve yapılandırılabilir Model Router (`fast`, `advanced`, `default`).
3. **Çok Dilli Derinleşme ve İzolasyon (Faz 3–4):**
   - **Plan 18 (Sıradaki):** Zig, C, Go, Rust için Tree-sitter C/FFI ve LSP entegrasyonu.
   - **Plan 19:** Docker/Podman/Wasm tabanlı tam container kum havuzu.
4. **Kendi Kendini Geliştiren Mimari (Faz 5):**
   - **Plan 20:** `AGENTS.md` spatiotemporal LIFO tersine çevrilebilir efekt ($\Omega$) ve reaktif coeffect runtime.
