# 🛠️ Yerleşik Ajan Araçları Kataloğu (Built-in Tools Reference)

> **Protokol:** [`AGENTS.md`](AGENTS.md) — Spatiotemporal Composability & Tooling  
> **İlgili Kılavuzlar:** [`SELF_EVOLUTION.md`](SELF_EVOLUTION.md) · [`ARCHITECTURE.md`](ARCHITECTURE.md) · [`COMMANDS.md`](COMMANDS.md)

---

## 📖 Genel Bakış

Rubik, otonom kodlama ajanının ihtiyaç duyduğu dosya yönetimi, semantik kod analizi, derleyici/LSP teşhisleri, test/kabuk yürütümü ve çalışma zamanı öz-evrimi için **22 yerleşik araç** sağlar.

Her araç açık bir risk seviyesine (`:read`, `:write`, `:execute`) ve Elm-tarzı yapılandırılmış hata bildirim formatına sahiptir.

---

## 📊 22 Araç Özet Tablosu

| Araç Adı (`name`) | Takma Adlar (`aliases`) | Risk | Açıklama |
| :--- | :--- | :---: | :--- |
| **`read_file`** | `view_file`, `read` | `:read` | Dosya içeriğini 1-tabanlı satır numaralarıyla okur (sayfalama destekli). |
| **`write_file`** | `create_file`, `write` | `:write` | Yeni dosya oluşturur veya mevcut dosyayı sanal tamponda tamamen yeniden yazar. |
| **`list_files`** | `ls`, `dir_list` | `:read` | Dizin içeriğini özyinelemeli veya filtrelenmiş olarak listeler. |
| **`replace_file_content`** | `edit_file`, `patch_file` | `:write` | Dosya içinde hedef metin bloğunu tam eşleşmeyle değiştirir (hedefli düzenleme). |
| **`grep_search`** | `grep`, `search_code` | `:read` | Dosya veya dizinlerde regex veya düz metin araması yapar. |
| **`search_symbols`** | `find_symbols`, `symbols` | `:read` | AST sembol grafında fonksiyon, sınıf veya modül araması yapar. |
| **`get_outline`** | `file_outline`, `outline` | `:read` | Bir dosyanın sınıf, metot ve yapısal özet iskeletini çıkarır. |
| **`find_references`** | `references`, `callers` | `:read` | Bir sembolün tüm çağrı ve kullanım referanslarını listeler. |
| **`get_symbol`** | `symbol_definition` | `:read` | Belirli bir sembolün tam kaynak kodunu ve imzasını getirir. |
| **`lsp_diagnostics`** | `diagnostics`, `lint_errors`| `:read` | Canlı LSP derleyici/tip/sözdizim hata ve uyarılarını alır. |
| **`lsp_hover`** | `hover_info`, `type_info` | `:read` | Bir sembolün LSP tip ve dokümantasyon bilgisini getirir. |
| **`lsp_definition`** | `goto_definition` | `:read` | Bir sembolün kaynak koddaki kesin tanım konumuna gider. |
| **`run_tests`** | `test`, `exec_tests` | `:execute` | Projenin test paketini çalıştırır ve teşhis raporlar. |
| **`run_command`** | `cmd`, `sh` | `:execute` | Güvenli sandbox içinde kabuk komutu çalıştırır. |
| **`exec_repl_command`** | `bang_command` | `:execute` | Ajan erişimine izin verilen oturum-güvenli `!` REPL komutlarını çalıştırır. |
| **`synthesize_tool`** | `create_tool`, `add_tool` | `:write` | Çalışma zamanında canlı native fonksiyon çağırma aracı üretir. |
| **`synthesize_command`**| `create_command` | `:write` | Çalışma zamanında yeni REPL bang komutu sentezler. |
| **`inspect_runtime`** | `runtime_status` | `:read` | Spatiotemporal fiberler, context ve coeffect durumunu inceler. |
| **`provide_service`** | `inject_service` | `:execute` | Çalışma zamanı bağlamına yeni bir servis sağlar. |
| **`apply_buffer`** | `commit_buffer`, `save_all` | `:write` | Bellek içi sanal tampon değişikliklerini diske uygular. |
| **`repair_runtime_service`**| `fix_runtime` | `:execute` | Hatalı veya bekleyen bir fiberi yeniden başlatır / tamir eder. |
| **`finish`** | `complete_task`, `done` | `:read` | Görevin başarıyla tamamlandığını bildirir ve özet sunar. |

---

## 🔍 Detaylı Parametre ve Şema Referansı

### 1. Dosya ve Düzenleme Araçları

#### `read_file`
- **Parametreler:**
  - `path` *(string, required)*: Okunacak dosya yolu.
  - `offset` *(integer, optional)*: Başlangıç satır numarası (1-tabanlı).
  - `limit` *(integer, optional)*: Okunacak maksimum satır sayısı.
  - `reload` *(boolean, optional)*: Harici çakışma durumunda bellek içi tamponu temizleyip dosyayı diskten zorla yeniden yükler.
- **Örnek:** `read_file(path: "lib/rubik/config.rb", offset: 1, limit: 50)`

#### `replace_file_content`
- **Parametreler:**
  - `path` *(string, required)*: Hedef dosya yolu.
  - `target_content` *(string, required)*: Değiştirilecek tam metin bloğu (birebir eşleşmeli).
  - `replacement_content` *(string, required)*: Yeni metin içeriği.
  - `start_line` *(integer, optional)*: Arama başlangıç satırı.
  - `end_line` *(integer, optional)*: Arama bitiş satırı.
- **Örnek:** `replace_file_content(path: "lib/version.rb", target_content: "VERSION = '0.1.0'", replacement_content: "VERSION = '0.2.0'")`

#### `write_file`
- **Parametreler:**
  - `path` *(string, required)*: Yazılacak dosya yolu.
  - `content` *(string, required)*: Dosyanın tam içeriği.
- **Örnek:** `write_file(path: "lib/helper.rb", content: "# frozen_string_literal: true\n\nmodule Helper\nend\n")`

#### `grep_search`
- **Parametreler:**
  - `query` *(string, required)*: Aranacak metin veya regex.
  - `path` *(string, optional)*: Arama yapılacak dizin veya dosya.
  - `case_sensitive` *(boolean, optional)*: Büyük/küçük harf duyarlılığı.
  - `includes` *(array of string, optional)*: Dosya desen filtreleri (örn: `["*.rb"]`).

---

### 2. Kod Zekası ve LSP Araçları

#### `search_symbols`
- **Parametreler:**
  - `query` *(string, required)*: Sembol adı veya deseni.
  - `kind` *(string, optional)*: Sembol türü (`method`, `class`, `module`, `function`).

#### `lsp_diagnostics`
- **Parametreler:**
  - `path` *(string, optional)*: Teşhis istenen dosya yolu (boş bırakılırsa tüm tamponlar).
  - `severity` *(string, optional)*: Minimum önem seviyesi (`error`, `warning`, `info`).

---

### 3. Test ve Kabuk Yürütümü

#### `run_tests`
- **Parametreler:**
  - `test_path` *(string, optional)*: Belirli bir test dosyası yolu.
  - `framework` *(string, optional)*: Test çerçevesi adı.

#### `run_command`
- **Parametreler:**
  - `command` *(string, required)*: Çalıştırılacak kabuk komutu.
  - `timeout` *(integer, optional)*: Maksimum çalışma süresi saniye (varsayılan: 30s).

---

### 4. Çalışma Zamanı ve Öz-Evrim

#### `synthesize_tool`
- **Parametreler:**
  - `name` *(string, required)*: Yeni aracın adı.
  - `description` *(string, required)*: Modelin aracı seçmesini sağlayan açıklama.
  - `code` *(string, required)*: `->(args) { ... }` biçiminde Ruby kodu.
  - `params_schema` *(object, optional)*: JSON Schema parametre tanımı.
  - `scope` *(string, optional)*: `session`, `project` veya `global`.
  - `risk` *(string, optional)*: `read`, `write` veya `execute`.
  - `test_args` *(object, optional)*: Ön-doğrulama için örnek parametreler (JSON'a çevrilebilir olmalıdır).
    Verildiğinde kod izole bir alt süreçte çalıştırılır ve 5 saniyelik zarfı dolan kaçan kod süreçle birlikte
    öldürülür; alt süreç açılamazsa in-process `Timeout` ile doğrulanır.

#### `apply_buffer`
- **Parametreler:**
  - `reason` *(string, optional)*: Tamponun diske uygulanma gerekçesi (örn. 'test öncesi senkronizasyon').
- **Çakışma Güvenliği (`[CONFLICT]` Kapısı):**
  - Dosya ilk okunduktan sonra diski harici bir süreç (kullanıcı editörü, git checkout vb.) değiştirmişse, Rubik veri kaybını önlemek için ilgili dosyayı atlar (`[CONFLICT]`) ve diske yazmaz.
  - Model veya kullanıcı, `read_file(path: "...", reload: true)` çağırarak diskteki güncel içeriği yükleyip değişiklikleri uzlaştırabilir.

---

## 🚨 Elm-Tarzı Yapılandırılmış Hata Formatı

Hata oluştuğunda tüm araçlar modelin kendini tek adımda düzeltmesini sağlayan şu formatı üretir:

```text
=== Runtime Execution Diagnostic ===
Category: File Not Found
Details: The target file 'lib/missing.rb' does not exist.
Suggestion: Use `list_files(path: 'lib')` to see available files or `write_file` to create it.
====================================
```
