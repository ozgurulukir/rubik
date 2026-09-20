# 🛠️ Yerleşik Ajan Araçları Kataloğu (Built-in Tools Reference)

> **Protokol:** [`AGENTS.md`](AGENTS.md) — Spatiotemporal Composability & Tooling  
> **İlgili Kılavuzlar:** [`SELF_EVOLUTION.md`](SELF_EVOLUTION.md) · [`ARCHITECTURE.md`](ARCHITECTURE.md) · [`COMMANDS.md`](COMMANDS.md)

---

## 📖 Genel Bakış

Rubik, otonom kodlama ajanının ihtiyaç duyduğu dosya yönetimi, semantik kod analizi, derleyici/LSP teşhisleri, test/kabuk yürütümü, arka plan süreçleri, alt ajan orkestrasyonu ve çalışma zamanı öz-evrimi için **29 yerleşik araç** sağlar.

Her araç açık bir risk seviyesine (`:read`, `:write`, `:execute`) ve Elm-tarzı yapılandırılmış hata bildirim formatına sahiptir.

---

## 📊 29 Araç Özet Tablosu

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
| **`run_command`** | `cmd`, `sh`, `bash` | `:execute` | Güvenli sandbox içinde kabuk komutu çalıştırır (`background: true` ile asenkron desteği). |
| **`manage_task`** | `task`, `tasks`, `bg_task` | `:execute` | Asenkron arka plan süreçlerini (sunucular, derleyiciler, watch modları) yönetir (`start`, `list`, `status`, `logs`, `send_input`, `kill`). |
| **`exec_repl_command`** | `bang_command` | `:execute` | Ajan erişimine izin verilen oturum-güvenli `!` REPL komutlarını çalıştırır. |
| **`synthesize_tool`** | `create_tool`, `add_tool` | `:write` | Çalışma zamanında canlı native fonksiyon çağırma aracı üretir. |
| **`synthesize_command`** | `create_command`, `add_command` | `:write` | Çalışma zamanında yeni REPL bang komutu sentezler. |
| **`unsynthesize`** | `remove_tool`, `delete_tool` | `:write` | Önceden sentezlenmiş dinamik bir aracı veya komutu geri alır / kaldırır. |
| **`inspect_runtime`** | `runtime_status` | `:read` | Spatiotemporal fiberler, context ve coeffect durumunu inceler. |
| **`provide_service`** | `inject_service` | `:execute` | Çalışma zamanı bağlamına yeni bir servis sağlar. |
| **`apply_buffer`** | `commit_buffer`, `save_all` | `:write` | Bellek içi sanal tampon değişikliklerini diske uygular. |
| **`repair_runtime_service`**| `fix_runtime` | `:execute` | Hatalı veya bekleyen bir fiberi yeniden başlatır / tamir eder. |
| **`ask_question`** | `ask`, `question` | `:read` | İnsan operatöre tekli veya çoklu seçimli yapılandırılmış sorular sorar. |
| **`invoke_subagent`** | `spawn_subagent`, `subagent` | `:execute` | İzole alt bağlam ve kısıtlı araç setiyle asenkron alt ajan başlatır. |
| **`manage_subagents`** | `subagents`, `list_subagents` | `:read` | Aktif alt ajanları yönetir, bekler (`wait`), inceler (`status`/`transcript`), bütçe uzatır (`extend_budget`) veya sonlandırır (`kill`/`kill_all`). |
| **`send_message`** | `message_subagent`, `msg_agent` | `:execute` | Çalışan veya beklemedeki bir alt ajanın gelen kutusuna (`inbox`) yönlendirme mesajı gönderir. |
| **`define_subagent`** | `register_subagent_type` | `:write` | Özel sistem istemi, araç izinleri ve rolleriyle dinamik alt ajan arketipi tanımlar. |
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
- **Savunmacı Güvenlik ve Tavanlar:** Tekil satır eşleşmeleri en fazla 500 karakter ile sınırlandırılır (`[line truncated]`). Toplam çıktı 30 KB tavanına ulaştığında otomatik sonlandırılarak bağlam şişmesi engellenir. `.ua`, `.trash*`, `.turbo`, `.sst`, `.next`, `.nuxt` gibi geçici ve çöp dizinler otomatik olarak arama dışı bırakılır.

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
  - `language` *(string, optional)*: Test çalıştırıcısı dili (ruby, python, rust, go, zig, c, crystal, node/typescript).
  - `path` *(string, optional)*: Belirli bir test dosyası veya dizin yolu (hedefe yönelik hızlı test).
  - `timeout` *(integer, optional)*: Maksimum çalışma süresi saniye (varsayılan: 30s).

#### `run_command`
- **Parametreler:**
  - `command` *(string, required)*: Çalıştırılacak kabuk komutu.
  - `timeout` *(integer, optional)*: Maksimum çalışma süresi saniye (varsayılan: 30s).
  - `background` *(boolean, optional)*: `true` verildiğinde komutu senkron beklemek yerine arka plan görevi olarak başlatır ve `manage_task` üzerinden takip edilmesini sağlar.

#### `manage_task`
- **Parametreler:**
  - `action` *(string, required, enum: `["start", "list", "status", "logs", "send_input", "kill"]`)*: Yürütülecek işlem:
    - `start`: `command` parametresini alarak yeni bir arka plan görevi başlatır.
    - `list`: Çalışan ve tamamlanan tüm arka plan görevlerinin durumunu, PID ve çalışma süresini listeler.
    - `status`: `task_id` ile belirtilen görevin anlık canlılık, PID ve çıkış kodunu döner.
    - `logs`: `task_id` ile belirtilen görevin halka tamponundaki (`RingBuffer`, son 500 satır) en son `tail` satırını döner.
    - `send_input`: `task_id` ile çalışan sürecin `stdin` akışına `input` metnini iletir.
    - `kill`: `task_id` ile belirtilen süreci ve tüm çocuk süreç ağacını (`Platform.kill_tree`) temiz bir şekilde sonlandırır.
  - `task_id` *(string, optional)*: İşlem yapılacak görev kimliği (örn. `task-1`). `status`, `logs`, `send_input`, `kill` için zorunludur.
  - `command` *(string, optional)*: `start` eylemi için çalıştırılacak komut dizesi.
  - `input` *(string, optional)*: `send_input` eylemi için `stdin`'e yazılacak girdi metni.
  - `tail` *(integer, optional)*: `logs` eylemi için dökülecek son satır sayısı (varsayılan: 50).
- **Spatiotemporal Bağlam & Zombi Koruması:**
  - Görev başlatıldığında, `Platform.kill_tree` ters işlemi bağlamın LIFO akümülatörüne ($\Omega$) kaydedilir. Oturum kapandığında veya bağlam sonlandığında tüm çocuk süreçler otomatik olarak öldürülür.
  - Bağımsız okuyucu iş parçacıkları (`collector threads`) stdout/stderr borularını kesintisiz tüketerek 64 KB OS boru hattı kilitlenmelerini (pipe deadlock) engeller.

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
    Verildiğinde kod izole bir alt süreçte çalıştırılır ve 5 saniyelik zarfı dolan kaçan kod süreçle
    birlikte öldürülür; alt süreç açılamazsa in-process `Timeout` ile doğrulanır.

#### `synthesize_command`
- **Parametreler:**
  - `name` *(string, required)*: Yeni komutun `!` öneki olmadan adı (örn. `doc_toc`). Ad küçük harfe indirilir;
    yerleşik (özel olmayan) komutların üzerine yazılamaz.
  - `code` *(string, required)*: Çağrılabilir bir Proc/lambda olarak değerlenen Ruby kodu:
    `->(args, out, shell) { ... }`. Kayıttan önce sözdizimi denetimi ve güvenlik duvarı (`Security::Guard`)
    çalışır; süreç başlatma (`system`, backtick, `IO.popen`, `Open3`) engellenir.
  - `description` *(string, optional, varsayılan "Custom dynamic command")*:
    `!help` çıktısında gösterilen açıklama.
  - `scope` *(string, optional, varsayılan `session`)*: `session` (yalnızca bellek), `project` (`.rubik/commands/`),
    `global` (`~/.rubik/commands/`). `project`/`global` kalıcıdır ve SHA-256 manifest doğrulamasına tabidir.
  - `test_args` *(object, optional)*: Ön-doğrulama için örnek argümanlar (önerilir; JSON'a çevrilebilir
    olmalıdır). Verildiğinde handler izole bir alt süreçte koşturulur ve 5 saniyelik zarfı dolan kaçan kod
    süreçle birlikte öldürülür; alt süreç açılamazsa in-process `Timeout` ile doğrulanır. Doğrulama
    çıktısı çocuğun kullandığı atılabilir StringIO'a gider; kullanıcının terminaline asla yazılmaz.
- **Handler Sözleşmesi (arity'ye göre):**
  - `->(args)` — `args`, `!komut argümanları` metninin `Shellwords.split` ile bölündüğü String dizisidir.
  - `->(args, out)` — `out`, REPL çıktı IO'sudur.
  - `->(args, out, shell)` — tam REPL erişimi (örn. `shell.execute_input`). Ön-doğrulama alt sürecinde
    arity-3 handler `shell: nil` alır; gerçek shell yalnızca canlı çalıştırmada verilir.
  - Argümansız (`->() { ... }`) katı lambda desteklenmez: 3 argümanla çağrıldığında `ArgumentError` üretir;
    handler en az bir parametre almalıdır.
- **Sıcak Güncelleme ve Sağlam Geri Alma:**
  - Aynı adla yeniden sentez, komutu sıfır yeniden başlatmayla canlı değiştirir; dispose anında önceki handler
    LIFO ters etkisiyle geri yüklenir. Başarı yanıtı: `Successfully synthesized and registered !<ad> [scope: ...]`.

#### `apply_buffer`
- **Parametreler:**
  - `reason` *(string, optional)*: Tamponun diske uygulanma gerekçesi (örn. 'test öncesi senkronizasyon').
- **Çakışma Güvenliği (`[CONFLICT]` Kapısı):**
  - Dosya ilk okunduktan sonra diski harici bir süreç (kullanıcı editörü, git checkout vb.) değiştirmişse, Rubik veri kaybını önlemek için ilgili dosyayı atlar (`[CONFLICT]`) ve diske yazmaz.
  - Model veya kullanıcı, `read_file(path: "...", reload: true)` çağırarak diskteki güncel içeriği yükleyip değişiklikleri uzlaştırabilir.

### 5. Etkileşim ve İnsan Geri Bildirimi Araçları

#### `ask_question`
- **Parametreler:**
  - `questions` *(array of objects, required)*: Operatöre sorulacak soru nesneleri listesi:
    - `question` *(string, required)*: Ekranda gösterilecek açık soru metni.
    - `options` *(array of strings, required, min 2)*: Seçilebilir seçenekler (en az 2 benzersiz seçenek). Tavsiye edilen seçenek `(Recommended)` ön eki ile belirtilebilir.
    - `is_multi_select` *(boolean, optional)*: Birden çok seçeneğin aynı anda seçilmesine izin verir (varsayılan: false).
- **Kullanıcı Deneyimi ve TUI:**
  - İnteraktif terminalde `TTY::Prompt` tabanlı şık ANSI/VT100 kartı açılır. Tekli seçimde ok tuşlarıyla gezinilir veya `"Other (write-in response)"` ile serbest metin yazılabilir. Çoklu seçimde Space ile işaretlenip Enter ile onaylanır.
  - Non-interactive / CI / piped oturumlarda kilitlenmeyi önlemek için otomatik olarak `(Recommended)` seçeneği (veya ilk seçenek) seçilir ve modele bildirim düşülür.
  - Kullanıcı Ctrl+C ile işlemi iptal ettiğinde terminal durumu sıfırlanır, ardışık sorular erken sonlandırılır ve modele iptal durumu güvenle raporlanır.

### 6. Alt Ajan ve Çoklu-Ajan Orkestrasyon Araçları (Subagent Hierarchy)

#### `invoke_subagent`
- **Parametreler:**
  - `subagents` *(array of objects, required)*: Başlatılacak alt ajanların listesi. Her nesne şu alanları içerir:
    - `type_name` *(string, required)*: Kullanılacak alt ajan tipi/arketipi (`"research"`, `"self"`, `"coder"` veya dinamik tanımlanmış tip).
    - `role` *(string, required)*: Alt ajanın kısa unvanı/rolü (örn. `"Codebase Researcher"`, `"Security Auditor"`).
    - `prompt` *(string, required)*: Alt ajana delege edilen net ve eyleme dökülebilir görev talimatı.
    - `system_prompt` *(string, optional)*: Alt ajana özel ek sistem yönergesi (varsayılan: arketipin şablonu).
    - `workspace` *(string, optional)*: Çalışma alanı modu (`"inherit"`: doğrudan ana tampon, `"branch"`: sanal izole tampon; varsayılan: `"inherit"`).
    - `model` *(string, optional)*: Alt ajanın kullanacağı model modu (`"inherit"`, `"flash"`, `"flash_lite"`, `"pro"`; varsayılan: `"inherit"`).
    - `max_steps` *(integer, optional)*: Alt ajanın yürütebileceği maksimum adım bütçesi (varsayılan: `subagents.default_max_steps` veya 25).
- **Asenkron Çalışma:** Çağrı anında arka plan iş parçacığını (`Thread`) başlatır ve subagent kimliğini (`conversation_id`), durumunu (`state: "running"`) ve log URI'sini döner. Ebeveyn ajan bloklanmaz.

#### `manage_subagents`
- **Parametreler:**
  - `action` *(string, required)*: Gerçekleştirilecek yönetim eylemi:
    - `"list"`: Aktif ve son tamamlanan doğrudan çocuk alt ajanları canlı durumları (`running`, `waiting_budget`, `completed`, `failed`, `disposed`), roller ve log URI'leriyle döner.
    - `"status"`: Belirtilen alt ajanın detaylı JSON durumunu, adım bütçesini ve rehberlik kılavuzunu döner (`timeout` verilirse ve ajan çalışıyorsa tamamlanana kadar bloke bekler; döngüsel polling yerine reaktif bekleme tavsiye edilir).
    - `"wait"`: Belirtilen veya tüm aktif alt ajanlar tamamlanana ya da bütçe nedeniyle duraklayana kadar bekler (`timeout` saniye sınırı ile).
    - `"transcript"`: Alt ajanın tam çalışma/diyalog transkriptini markdown formatında döner.
    - `"extend_budget"`: Adım bütçesi dolup duraklayan alt ajana ek adım tahsis ederek devam ettirir (`steps` parametresi ile).
    - `"kill"`: Belirtilen `conversation_ids` dizisindeki alt ajanları ve onların tüm alt soylarını (`cascading cleanup`) güvenle durdurur.
    - `"kill_all"`: Süpervizör altındaki tüm alt ajanları topluca sonlandırır (`init 0` LIFO tasfiyesi).
  - `conversation_ids` *(array of strings, optional)*: Hedef alt ajan kimlikleri listesi (`"wait"`, `"kill"`).
  - `conversation_id` *(string, optional)*: Tekil hedef alt ajan kimliği (`"status"`, `"wait"`, `"transcript"`, `"extend_budget"`).
  - `timeout` *(integer, optional)*: `"wait"` veya `"status"` eylemi için maksimum bekleme saniyesi (varsayılan: 30 for wait).
  - `steps` *(integer, optional)*: `"extend_budget"` eylemi için eklenecek adım miktarı (varsayılan: 10).

#### `send_message`
- **Parametreler:**
  - `recipient` *(string, required)*: Mesajın gönderileceği hedef alt ajanın `conversation_id` kimliği.
  - `message` *(string, required)*: Alt ajanın gelen kutusuna (`inbox`) iletilecek yeni talimat veya geri bildirim içeriği.
  - `steps` *(integer, optional)*: Mesajla birlikte alt ajanın adım bütçesini artırma miktarı.

#### `define_subagent`
- **Parametreler:**
  - `name` *(string, required)*: Tanımlanacak arketip ismi (örn. `"security_auditor"`).
  - `description` *(string, required)*: Arketipin amacı ve kullanım alanı açıklaması.
  - `system_prompt` *(string, required)*: Arketipin temel sistem yönergesi ve persona kuralları.
  - `enable_write_tools` *(boolean, optional)*: Dosya yazma/düzenleme araçlarının yetkilendirilmesi (varsayılan: false).
  - `enable_subagent_tools` *(boolean, optional)*: Alt ajan başlatma araçlarının yetkilendirilmesi (varsayılan: false, yaprak ajanlar için false tutulur).
  - `enable_mcp_tools` *(boolean, optional)*: MCP araçlarının aktarılması (varsayılan: false).

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
