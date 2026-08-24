# 📋 Plan 44: LLM Eğitim Verileriyle Uyumlu Kanonik Araç İsimlendirmesi, Grep Arama Aracı ve Zero-Cost Tool Aliasing

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** Kolay–Orta · **Faz:** 5 (LLM Ajan Ergonomisi & Tool Calling Doğruluğu)  
> **İlgili Planlar:** [10](10-ajan-dongusu-ve-arac-entegrasyonu.md), [16](16-genisletilmis-arac-seti-ve-planlama.md), [17](17-yerel-arac-cagrilari-ve-router.md), [32](32-agentic-tool-cagrilari-yapilandirilmis-io-ve-akilli-baglam-kirpma.md), [36](36-repl-komut-ve-yerel-arac-ayrimi-ve-ajan-yonlendirme-guardrail.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

### Mevcut Durum
1. **Model Eğitim Verisi ve Alışkanlıkları (LLM Priors):**
   - Büyük dil modelleri (Claude 3.5 Sonnet, GPT-4o, DeepSeek-V3, Gemini Pro), SWE-bench, OpenAI Tool-Use, Claude Computer Use ve açık kaynak kodlama ajanları (Aider, Cursor, Cline, Roo Code) veri setleriyle eğitilmiştir.
   - Bu modeller `read_file`, `write_file`, `run_command`, `grep_search`, `list_files`, `find_references` gibi standart araç isimlerine ve parametre şemalarına (`path`, `content`, `command`, `query`) yüksek olasılıksal yatkınlığa (high probability prior) sahiptir.
2. **Eksik Temel Araç: `grep_search`:**
   - Mevcut durumda dosya içi metin veya regex araması yapan yerel bir araç bulunmamakta; model `search_symbols` (yalnızca AST sembolleri) veya `run_command("grep -rn ...")` çağırmaya zorlanmaktadır.
3. **Katı İsim Eşleşmesi ve "Tool Not Found" Riski:**
   - Eğer model eğitim alışkanlığıyla `view_file`, `bash`, `execute_command`, `search_code`, `get_diagnostics` gibi eşanlamlı bir isim çağırırsa, `ToolRegistry` aracı bulamamakta ve geçersiz araç hatası üretmektedir.

---

## 🏛️ 2. Mimari Tasarım ve Çözüm

```
                     ┌─────────────────────────────────────────────────────────┐
                     │            LLM Function Call / Tool Invocation          │
                     │  (e.g., 'read_file', 'view_file', 'bash', 'grep_search')│
                     └────────────────────────────┬────────────────────────────┘
                                                  │
                                                  ▼
                     ┌─────────────────────────────────────────────────────────┐
                     │          Rubik::Tools::Registry with Aliasing           │
                     │   • Canonical Name Match (O(1))                         │
                     │   • Zero-Cost Alias Forwarding (e.g. bash -> run_cmd)   │
                     │   • Fuzzy / Fallback Normalization                      │
                     └────────────────────────────┬────────────────────────────┘
                                                  │
         ┌──────────────────┬─────────────────────┼─────────────────────┬──────────────────┐
         ▼                  ▼                     ▼                     ▼                  ▼
  ┌──────────────┐   ┌──────────────┐      ┌──────────────┐      ┌──────────────┐   ┌──────────────┐
  │  read_file   │   │  write_file  │      │ grep_search  │      │ run_command  │   │    finish    │
  │ (view_file)  │   │ (create_file)│      │(search_code) │      │(bash/sh/exec)│   │ (done/exit)  │
  └──────────────┘   └──────────────┘      └──────────────┘      └──────────────┘   └──────────────┘
```

---

## ⚙️ 3. Planlanan İyileştirmeler

### 3.1 Yeni Yerel Araç: `Rubik::Tools::GrepSearchTool` ([`builtins.rb`](../lib/rubik/tools/builtins.rb))
- **İsim:** `grep_search` (Alias: `search_code`, `grep`)
- **Açıklama:** `"Search for exact string or regular expression across project files with line numbers and matched content"`
- **Parametreler:**
  - `query` (string, required): Aranacak metin veya regex ifadesi.
  - `path` (string, optional): Belirli bir alt dizin veya dosya yolu filtresi.
  - `extension` (string, optional): Dosya uzantısı filtresi (örn: `.rb`, `.go`).
  - `case_sensitive` (boolean, optional, default: false).
  - `max_results` (integer, optional, default: 50).
- **Uygulama:** Tampon (`@buffer_manager`) ve disk dosyalarını hızlıca tarar, satır numarası ve içeriğiyle birlikte yapılandırılmış sonuç üretir.

### 3.2 Kanonik Araç İsimleri ve Parametre Standardizasyonu

| Araç Adı (Canonical) | Tanınan Eşanlamlılar (Aliases) | Parametreler | Sorumluluk |
| :--- | :--- | :--- | :--- |
| **`read_file`** | `view_file`, `read` | `path` | Dosya içeriğini okuma |
| **`write_file`** | `create_file`, `edit_file`, `save_file` | `path`, `content` | Tampona kod yazma |
| **`list_files`** | `list_directory`, `list_dir`, `ls` | `path`, `extension` | Dosya ve dizin listeleme |
| **`grep_search`** | `search_code`, `grep`, `search_files` | `query`, `path`, `extension` | Metin/Regex arama |
| **`run_command`** | `bash`, `sh`, `execute_command`, `cmd` | `command`, `timeout` | Güvenli terminal komutu |
| **`run_tests`** | `test`, `run_test_suite` | `language` | Test süitini çalıştırma |
| **`search_symbols`** | `find_symbols`, `symbols` | `query`, `smart_context` | AST sembol araması |
| **`get_outline`** | `file_outline`, `outline` | `file_path` | Dosya semantik anahattı |
| **`find_references`** | `references`, `get_callers` | `symbol_name` | Sembol çağrı yerleri |
| **`get_symbol`** | `get_definition`, `symbol_info` | `symbol_name` | İzole sembol gövdesi |
| **`lsp_diagnostics`** | `get_diagnostics`, `diagnostics` | `file_path` | LSP derleyici hataları |
| **`lsp_hover`** | `get_hover`, `hover` | `file_path`, `line`, `character` | Tip imzası ve docstring |
| **`lsp_definition`** | `goto_definition`, `definition` | `file_path`, `line`, `character` | Tanıma atlama |
| **`apply_buffer`** | `save_buffer`, `commit_changes` | `reason` | Tamponu diske yazma |
| **`finish`** | `complete`, `done`, `task_complete` | `message` | Görevi tamamlama |

### 3.3 `Rubik::Tools::Registry` Sıfır Maliyetli Eşanlamlı Yönlendirme (Zero-Cost Tool Aliasing)
- `Registry#register(tool, aliases: [])`: Araç kaydedilirken hem kanonik adı hem de aliasları eşleme tablosuna eklenir.
- `Registry#get(name)`:
  1. Doğrudan kanonik eşleşmeye bakar.
  2. Yoksa alias tablosundan (`@aliases[name.to_s.downcase]`) çözümler.
  3. LLM schema listesinde (`Registry#schemas`) yalnızca kanonik adları yayınlar (böylece token israfı olmaz), fakat model geçmiş eğitiminden dolayı bir alias çağırırsa sıfır hatayla doğrudan kanonik araca yönlendirilir.

---

## 🔍 4. Uçtan Uca Wiring & Test Doğrulaması

1. **`test/unit/test_grep_search_tool.rb`:**
   - Düz metin ve regex araması.
   - Uzantı ve yol filtreleme.
   - Tampon içi (dirty) ve disk dosyaları üzerinde eşzamanlı arama.
2. **`test/unit/test_tool_aliasing_and_naming.rb`:**
   - `bash`, `view_file`, `create_file`, `grep`, `diagnostics` çağrılarının ilgili araçlara yönlendirilmesi.
   - Şema boyutunun temiz kalması (sadece kanonik isimlerin LLM'e gönderilmesi).
3. **Mevcut Test Süiti:** Tüm 264+ testin %100 yeşil kalması.

---

## 🚀 5. Uygulama ve Onay Akışı

1. **Aşama 1 (Hazırlık):** Kullanıcı planı inceler ve onay verir.
2. **Aşama 2 (Çoklu Ajan İcrası):** Reviewer $\rightarrow$ Executor $\rightarrow$ Auditor adımları sırayla uygulanır.
3. **Aşama 3 (Onay & Push):** Red-team denetiminden geçirilip kullanıcı onayıyla pushlanır.
