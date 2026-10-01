# 🛠️ Yerleşik Ajan Araçları Kataloğu (Built-in Tools Reference)

> **Protokol:** [`AGENTS.md`](AGENTS.md) — Spatiotemporal Composability & Tooling  
> **İlgili Kılavuzlar:** [`SELF_EVOLUTION.md`](SELF_EVOLUTION.md) · [`ARCHITECTURE.md`](ARCHITECTURE.md) · [`COMMANDS.md`](COMMANDS.md)

---

## 📖 Genel Bakış

Rubik, otonom kodlama ajanının ihtiyaç duyduğu dosya yönetimi, semantik kod analizi, derleyici/LSP teşhisleri, test/kabuk yürütümü, arka plan süreçleri, alt ajan orkestrasyonu ve çalışma zamanı öz-evrimi için **32 yerleşik araç** sağlar.

Her araç açık bir risk seviyesine (`:read`, `:write`, `:execute`) ve Elm-tarzı yapılandırılmış hata bildirim formatına sahiptir.

> **Maestro erişim politikası (kullanıcı kararı 2026-10-01):** init-0 her modda saf orkestratördür — kök ajanda `write_file`, `replace_file_content`, `run_command`, `run_tests` ve `manage_task` (yalnız `start` aksiyonu) YÜRÜTÜLMEDEN reddedilir ve hata sonucu subagent'a yönlendirir (`subagents.maestro_gate` config'i, default açık; subagent'lar StepRunner üzerinden dispatch olur ve bu kapıyı asla görmez). Salt-okunur keşif araçları, `storage`/`show_file`, `ask_question`, `apply_buffer` (coder branch birleşiminin manuel-mod floşu) ve `finish` doğrudan kalır.

---

## 📊 Araç Özet Tablosu (32 yerleşik + dinamik `skill`)

| Araç Adı (`name`) | Takma Adlar (`aliases`) | Risk | Açıklama |
| :--- | :--- | :---: | :--- |
| **`read_file`** | `view_file`, `read` | `:read` | Dosya içeriğini 1-tabanlı satır numaralarıyla okur (sayfalama destekli); sanal `rubik://` URI'ları da çözer (storage, goal state, subagent transcript). |
| **`write_file`** | `create_file`, `save_file`, `overwrite_file` | `:write` | Yeni dosya oluşturur veya mevcut dosyayı sanal tamponda tamamen yeniden yazar. |
| **`list_files`** | `list_directory`, `list_dir`, `ls` | `:read` | Dizin içeriğini özyinelemeli veya filtrelenmiş olarak listeler. |
| **`replace_file_content`** | `edit_file`, `edit_chunk`, `str_replace`, `patch_file` | `:write` | Dosya içinde hedef metin bloğunu tam eşleşmeyle değiştirir (hedefli düzenleme). |
| **`grep_search`** | `search_code`, `grep`, `search_files` | `:read` | Dosya veya dizinlerde regex veya düz metin araması yapar. |
| **`search_symbols`** | `find_symbols`, `symbols` | `:read` | AST sembol grafında fonksiyon, sınıf veya modül araması yapar. |
| **`get_outline`** | `file_outline`, `outline` | `:read` | Bir dosyanın sınıf, metot ve yapısal özet iskeletini çıkarır. |
| **`find_references`** | `references`, `get_callers` | `:read` | Bir sembolün tüm çağrı ve kullanım referanslarını listeler. |
| **`get_symbol`** | `get_definition`, `symbol_info` | `:read` | Belirli bir sembolün tam kaynak kodunu ve imzasını getirir. |
| **`lsp_diagnostics`** | `get_diagnostics`, `diagnostics` | `:read` | Canlı LSP derleyici/tip/sözdizim hata ve uyarılarını alır. |
| **`lsp_hover`** | `get_hover`, `hover` | `:read` | Bir sembolün LSP tip ve dokümantasyon bilgisini getirir. |
| **`lsp_definition`** | `goto_definition`, `definition` | `:read` | Bir sembolün kaynak koddaki kesin tanım konumuna gider. |
| **`run_tests`** | `test`, `run_test_suite` | `:execute` | Projenin test paketini çalıştırır ve teşhis raporlar. |
| **`run_command`** | `bash`, `sh`, `execute_command`, `cmd` | `:execute` | Güvenli sandbox içinde kabuk komutu çalıştırır (`background: true` ile asenkron desteği). |
| **`manage_task`** | `task`, `tasks`, `background_task`, `bg_task` | `:execute` | Asenkron arka plan süreçlerini (sunucular, derleyiciler, watch modları) yönetir (`start`, `list`, `status`, `logs`, `send_input`, `kill`). |
| **`exec_repl_command`** | `repl_command`, `exec_repl`, `repl` | `:execute` | Ajan erişimine izin verilen oturum-güvenli `!` REPL komutlarını çalıştırır. |
| **`synthesize_tool`** | `create_tool`, `add_tool` | `:write` | Çalışma zamanında canlı native fonksiyon çağırma aracı üretir. |
| **`synthesize_command`** | `create_command`, `add_command` | `:write` | Çalışma zamanında yeni REPL bang komutu sentezler. |
| **`unsynthesize`** | `delete_tool`, `delete_command`, `remove_tool`, `remove_command` | `:write` | Önceden sentezlenmiş dinamik bir aracı veya komutu geri alır / kaldırır. |
| **`inspect_runtime`** | `runtime_status`, `inspect_fibers` | `:read` | Spatiotemporal fiberler, context ve coeffect durumunu inceler. |
| **`provide_service`** | `register_service`, `add_service` | `:execute` | Çalışma zamanı bağlamına yeni bir servis sağlar. |
| **`apply_buffer`** | `save_buffer`, `commit_changes`, `save` | `:write` | Bellek içi sanal tampon değişikliklerini diske uygular. |
| **`repair_runtime_service`** | `fix_service`, `repair_lsp`, `repair_runner`, `repair_runtime` | `:execute` | Hatalı veya bekleyen bir fiberi yeniden başlatır / tamir eder. |
| **`ask_question`** | `ask`, `question` | `:read` | Yapılandırılmış seçimli soru sorar: ana ajanda insan operatöre TTY kartı, alt ajanda init-0 süpervizörüne (cevap gelene kadar bloklar). |
| **`invoke_subagent`** | `spawn_subagent`, `start_subagent` | `:execute` | İzole alt bağlam ve kısıtlı araç setiyle asenkron alt ajan başlatır. |
| **`manage_subagents`** | `subagents_status`, `subagent_list` | `:read` | Aktif alt ajanları yönetir, bekler (`wait`), inceler (`status`/`transcript`), bütçe uzatır (`extend_budget`), bağlam-koruyucu yeniden görevlendirir (`redeploy`), tasfiye eder (`reap`) veya sonlandırır (`kill`/`kill_all`). |
| **`send_message`** | `msg_agent`, `tell_subagent` | `:execute` | Çalışan veya beklemedeki bir alt ajanın gelen kutusuna (`inbox`) yönlendirme mesajı gönderir. |
| **`define_subagent`** | `register_subagent_type`, `create_subagent_type` | `:execute` | Özel sistem istemi, araç izinleri ve rolleriyle dinamik alt ajan arketipi tanımlar. |
| **`dmesg`** | `kernel_log`, `kernel_dmesg` | `:read` | Çekirdek monotonik olay halkasını (telemetri, alt ajan bildirimleri, teşhis, hatalar) okur ve filtreler. |
| **`storage`** | `rubik_storage` | `:write` | Merkezi `rubik://storage` FS-DB'sini yazar/okur: goal, plan, memory, wiki, transcript, review, note varlıkları (`put`/`get`/`list`/`search`/`set_ref`/`delete`). |
| **`show_file`** | `show` | `:read` | Kalıcı depo varlığını okur (yalnız `rubik://storage` URI'leri). Kök ajanda tam içerik DOĞRUDAN kullanıcının terminaline basılır — model yalnız tek satırlık stub alır; subagent düzleminde içerik ajanın kendi bağlamına yüklenir (`read_file` gibi). |
| **`finish`** | `complete`, `done`, `task_complete`, `exit` | `:execute` | Görevin başarıyla tamamlandığını bildirir ve özet sunar. |
| **`skill`** | — | `:read` | [Dinamik] Bir ajan becerisinin tam SKILL.md talimatını adıyla yükler. Yerleşik `build_default` dışında: kayıt `Skills::Manager` epoch'unda kendi ctx ters-inverse'i ile yapılır; REQUIRES memnuniyetsizken reklam edilmez. |

---

## 🔍 Detaylı Parametre ve Şema Referansı

### 1. Dosya ve Düzenleme Araçları

#### `read_file`
- **Parametreler:**
  - `path` *(string, required)*: Okunacak dosya yolu — veya sanal `rubik://` URI'sı (aşağıya bakın).
  - `offset` *(integer, optional)*: Başlangıç satır numarası (1-tabanlı).
  - `limit` *(integer, optional)*: Okunacak maksimum satır sayısı.
  - `reload` *(boolean, optional)*: Harici çakışma durumunda bellek içi tamponu temizleyip dosyayı diskten zorla yeniden yükler.
- **Sanal `rubik://` URI'ları** (buffer manager'a uğramadan çözülür):
  - `rubik://storage/index` — merkezi depo indeksi; `rubik://storage/<project>/<type>` tip listesi; `rubik://storage/<project>/<type>/<id>` varlık (`id` = tam id, `plan.3`, satır `3`, karma öneki veya alias); `rubik://storage/<project>/refs/<alias>`; `rubik://storage/<type>/...` varsayılan proje kısa formu. Sonek `.json` ham JSON döndürür.
  - `rubik://goal/state` — canlı `!goal` anlık görüntüsü (XML).
  - `rubik://subagent/<storage-id>/transcript` — subagent transcript dosyası (absorbe yol önce, eski `.rubik/` sonra).
- **Örnek:** `read_file(path: "lib/rubik/config.rb", offset: 1, limit: 50)` · `read_file(path: "rubik://storage/plan/3")`

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
  - `test_args` *(object, optional)*: Çalışma zamanı ön-doğrulaması (`pre-flight`) için örnek parametreler (JSON'a çevrilebilir olmalıdır).
    Araç sentezinde çalışma zamanı ön-doğrulaması **zorunludur**; `test_args` verilmediğinde varsayılan `{}` argümanları ile izole alt süreçte
    (`PreflightRunner`) koşturulur. 5 saniyelik zarfı aşan veya hata fırlatan kod toolbelt'e eklenmez ve reddedilir.

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
  - `force` *(boolean, optional)*: Harici çakışma (`[CONFLICT]`) durumunda dahi tampon içeriğini zorla diske yazar.
- **Alt Ajan ve Otonom Orkestrasyon Entegrasyonu:**
  - `coder` arketipi bu araca doğrudan sahiptir. Dosya düzenlemelerinden sonra (`write_file` / `replace_file_content`), testler veya sonlandırma öncesinde tamponu diske dökmek için kullanılır.
  - `subagents.auto_apply_buffer: true` ayarı aktifken, alt ajan test koştururken (`run_tests`) veya başarıyla tamamlandığında (`finish` / `:completed`) bellek içi kirli tampon otomatik olarak diske senkronize edilir.
- **Çakışma Güvenliği (`[CONFLICT]` Kapısı):**
  - Dosya ilk okunduktan sonra diski harici bir süreç (kullanıcı editörü, git checkout vb.) değiştirmişse, Rubik veri kaybını önlemek için ilgili dosyayı atlar (`[CONFLICT]`) ve diske yazmaz.
  - Model veya kullanıcı, `read_file(path: "...", reload: true)` çağırarak diskteki güncel içeriği yükleyip değişiklikleri uzlaştırabilir veya `apply_buffer(force: true)` ile üzerine yazabilir.

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
- **Alt Ajan Düzlemi (subagent → init-0):** Bir alt ajan bağlamında (`research`, `coder`, `self` ve özel tipler) araç aynı şemayla çağrılır ama soru insan yerine **init-0 süpervizörüne** yönlendirilir: alt ajan `waiting_input` durumuna geçer, soru `❓ [Question from <id>]` bildirimi olarak init-0'ın inbox'ına düşer (boştaysa reactive wakeup ile uyandırılır) ve alt ajan **cevap gelene kadar bloklar**. init-0 `send_message(recipient: '<id>', message: '<cevap>')` ile yanıtlar; cevap araç sonucu olarak alt ajanın history'sine girer. `subagents.question_timeout` (varsayılan 300s) içinde cevap gelmezse araç "en iyi takdirinle devam et" rehberiyle döner — alt ajan ölmez, kaldığı adımdan sürer. Çoklu sorular tek seferde numaralandırılarak birleştirilir ve TEK bloklama yapılır.

### 6. Alt Ajan ve Çoklu-Ajan Orkestrasyon Araçları (Subagent Hierarchy)

#### `invoke_subagent`
- **Parametreler:**
  - `subagents` *(array of objects, required)*: Başlatılacak alt ajanların listesi. Her nesne şu alanları içerir:
    - `type_name` *(string, required)*: Kullanılacak alt ajan tipi/arketipi:
      - `"research"` *(varsayılan)*: Salt-okunur arketip. Dosya okuma, sembol arama, mimari analiz içindir. Dosya düzenleme (`write_file`, `replace_file_content`, `apply_buffer`) ve test koşturma araçlarına SAHİP DEĞİLDİR.
      - `"coder"`: Kod düzenleme ve doğrulama arketipi. Dosyaları düzenler, tamponda aşamalandırır, `apply_buffer` ile diske yazar ve `run_tests` koşturur. Kod değişiklikleri gerektiren görevlerde ZORUNLUDUR.
      - `"self"`: Ebeveyn ajanın tüm araç ve yetkilerini devralan tam klon (iç içe subagent açma hariç).
    - `role` *(string, required)*: Alt ajanın kısa unvanı/rolü (örn. `"Codebase Researcher"`, `"Security Auditor"`).
    - `prompt` *(string, required)*: Alt ajana delege edilen net ve eyleme dökülebilir görev talimatı.
    - `system_prompt` *(string, optional)*: Alt ajana özel ek sistem yönergesi (varsayılan: arketipin şablonu).
    - `workspace` *(string, optional)*: Çalışma alanı modu (`"inherit"`: doğrudan ana tampon, `"branch"`: sanal izole tampon; varsayılan: `"inherit"`).
    - `model` *(string, optional)*: Alt ajanın kullanacağı model modu (`"inherit"`, `"flash"`, `"flash_lite"`, `"pro"`; varsayılan: `"inherit"`).
    - `max_steps` *(integer, optional)*: Alt ajanın yürütebileceği maksimum adım bütçesi (varsayılan: `subagents.default_max_steps` veya 25).
    - `depends_on` *(array, optional)*: PM tarzı dispatch kısıtları — `["subagent-1"]` (FS/finish-to-start: öncül tamamlanınca otomatik başlatılır) veya `[{"id": "subagent-1", "type": "SS"}]` (start-to-start: öncül ilk kez çalışmaya başlayınca). Bağımlı spec kuyruğa girer: slot ve maliyet yoktur, `list`/`status` QUEUED gösterir, `wait` kuyruk id'lerini kabul eder (zincir bitene dek bloklar). Failed/killed öncül bağımlıları İPTAL eder (yeniden dispatch edin); budget-paused öncül onları kuyrukta tutar (extend edin).
- **Asenkron Çalışma & Bekleme Kuralı:** Çağrı anında arka plan iş parçacığını (`Thread`) başlatır ve subagent kimliğini (`conversation_id`), durumunu (`state: "running"`) döner. Ebeveyn ajan döngüsel `status` polling YAPMAMALIDIR; sonuçları toplamak için hemen ardından `manage_subagents(action: "wait", conversation_ids: [...], timeout: 30)` çağrılmalıdır. Ayrıca çalışan ana döngüye (`Loop`) tamamlanan alt ajan bildirimleri her adım başında otomatik olarak dökülür (`drain_subagent_notices_into_history!`).

#### `manage_subagents`
- **Parametreler:**
  - `action` *(string, required)*: Gerçekleştirilecek yönetim eylemi:
    - `"list"`: Aktif ve son tamamlanan doğrudan çocuk alt ajanları canlı durumları (`running`, `waiting_input`, `waiting_budget`, `completed`, `failed`, `disposed`), roller ve log URI'leriyle döner.
    - `"status"`: Belirtilen alt ajanın detaylı JSON durumunu, adım bütçesini ve rehberlik kılavuzunu döner (`timeout` verilirse ve ajan çalışıyorsa tamamlanana kadar bloke bekler; döngüsel polling yerine `"wait"` tavsiye edilir).
    - `"wait"`: Belirtilen veya tüm aktif alt ajanlar tamamlanana ya da bütçe nedeniyle duraklayana kadar deterministik olarak bekler (`timeout` saniye sınırı ile; varsayılan: 30s). Tamamlanan ajanların esas sonuç bulgularını doğrudan (1500 karaktere kadar, daha uzunsa `transcript` yönlendirmesiyle) döner.
    - `"transcript"`: Alt ajanın tam çalışma/diyalog transkriptini markdown formatında döner.
    - `"extend_budget"`: Adım bütçesi dolup duraklayan alt ajana ek adım tahsis ederek devam ettirir (`steps` parametresi ile).
    - `"redeploy"`: Bitmiş (completed/failed) bir alt ajana, birikmiş bağlamını (LLM history) KORUYARAK yeni görev verir — takım içi takip işleri için taze spawn + yeniden açıklama maliyeti yok. `conversation_id` + `prompt` (yeni görev) + isteğe bağlı `steps` (taze bütçe) parametreleri alır. Reap edilmiş (arşivlenmiş) alt ajan redeploy edilemez; yenisi spawn edilmelidir.
    - `"reap"`: Bitmiş tüm alt ajanları hemen tasfiye eder — bellekteki history serbest bırakılır, dayanıklı transkript ve `rubik://storage` indeksi kalır, mezar taşı sorgulanabilir kalır.
    - `"kill"`: Belirtilen `conversation_ids` dizisindeki alt ajanları ve onların tüm alt soylarını (`cascading cleanup`) güvenle durdurur.
    - `"kill_all"`: Süpervizör altındaki tüm alt ajanları topluca sonlandırır (`init 0` LIFO tasfiyesi).
  - `conversation_ids` *(array of strings, optional)*: Hedef alt ajan kimlikleri listesi (`"wait"`, `"kill"`).
  - `conversation_id` *(string, optional)*: Tekil hedef alt ajan kimliği (`"status"`, `"wait"`, `"transcript"`, `"extend_budget"`, `"redeploy"`).
  - `prompt` *(string, optional)*: `"redeploy"` eylemi için yeni görev metni.
  - `timeout` *(integer, optional)*: `"wait"` veya `"status"` eylemi için maksimum bekleme saniyesi (varsayılan: 30 for wait).
  - `steps` *(integer, optional)*: `"extend_budget"` için eklenecek adım miktarı (varsayılan: 10) veya `"redeploy"` için taze bütçe.

#### `send_message`
- **Parametreler:**
  - `recipient` *(string, required)*: Mesajın gönderileceği hedef alt ajanın `conversation_id` kimliği.
  - `message` *(string, required)*: Alt ajanın gelen kutusuna (`inbox`) iletilecek yeni talimat veya geri bildirim içeriği.
  - `steps` *(integer, optional)*: Mesajla birlikte alt ajanın adım bütçesini artırma miktarı.
- **Soru Yanıt Düzlemi:** `ask_question` ile soru soran (`waiting_input` durumundaki) bir alt ajana bekleme **sırasında** gönderilen ilk mesaj sorunun **cevabı** olarak araç sonucuna iletilir ve alt ajanın bloklaması kaldırılır. Soru anında gelen kutusunda bekleyen eski mesajlar ise cevap sanılmaz — history'ye süpervizör mesajı olarak işlenir.

#### `define_subagent`
- **Parametreler:**
  - `name` *(string, required)*: Tanımlanacak arketip ismi (örn. `"security_auditor"`).
  - `description` *(string, required)*: Arketipin amacı ve kullanım alanı açıklaması.
  - `system_prompt` *(string, required)*: Arketipin temel sistem yönergesi ve persona kuralları.
  - `enable_write_tools` *(boolean, optional)*: Dosya yazma/düzenleme araçlarının yetkilendirilmesi (varsayılan: false).
  - `enable_subagent_tools` *(boolean, optional)*: Alt ajan başlatma araçlarının yetkilendirilmesi (varsayılan: false, yaprak ajanlar için false tutulur).
  - `enable_mcp_tools` *(boolean, optional)*: MCP araçlarının aktarılması (varsayılan: false).

### 7. Çekirdek Telemetri ve Olay Halkası Araçları

#### `dmesg`
- **Açıklama:** Çekirdek monotonik olay halkasındaki (ring buffer) telemetri, alt ajan bildirimleri, HTTP/LLM bağlantı hataları ve teşhis kayıtlarını okur. Sabit boyutlu dairesel tampon mimarisiyle sıfır bellek büyümesi (zero leak) garantilidir.
- **Risk Seviyesi:** `:read`
- **Parametreler:**
  - `limit` *(integer, optional)*: Döndürülecek maksimum son olay sayısı (varsayılan: 30).
  - `level` *(string, optional)*: Önem derecesine göre filtreleme (`"emerg"`, `"alert"`, `"crit"`, `"err"`, `"warn"`, `"notice"`, `"info"`, `"debug"`).
  - `subsystem` *(string, optional)*: Alt sistem/tesise göre filtreleme (`"init"`, `"subagent"`, `"llm"`, `"net"`, `"buffer"`, `"tool"`, `"sandbox"`, `"kernel"`).
  - `since_seq` *(integer, optional)*: Yalnızca belirtilen sıra numarasından kesinlikle sonraki olayları getirir.
- **Örnek Çağrı:**
  ```json
  {
    "subsystem": "subagent",
    "level": "warn",
    "limit": 10
  }
  ```
- **Örnek Çıktı Formatı:**
  ```text
  [  +12.450123] [subagent/subagent-1] WARN: Reached step budget (88) and paused.
  [  +14.120500] [subagent/subagent-1] ERR: Transient connection timeout.
  ```

---

### 8. Merkezi Storage Aracı (`storage`)

#### `storage`
- **Açıklama:** Merkezi `rubik://storage` sanal FS-DB'sinin yazma düzlemi — ajan iş dosyalarını (hedefler, planlar, bellek notları, wiki, incelemeler) worktree'ye dosya saçmadan merkezi depoda tutar. Okuma düzlemi `read_file` URI rotalarıdır (bkz. `read_file` sanal URI'ları); bu nedenle 'research' arketipi gibi salt-okunur ajanlar depoyu okuyabilir ama yazamaz. Subagent transcriptları tamamlandığında otomatik olarak `transcript` varlığı olarak indekslenir (`subagent-<storage-id>` alias'ı ile).
- **Risk Seviyesi:** `:write`
- **Varlık Tipleri:** `goal`, `plan`, `memory`, `wiki`, `transcript`, `review`, `note`
- **Kimlik:** `tip.satır.karma16` (örn. `plan.3.9f86d081884c7d21`) — satır numaraları tip içinde tektir ve asla yeniden kullanılmaz; güncelleme id'yi korur (`version` artar). Çözüm formları: tam id · `plan.3` · satır `3` · karma öneki · alias.
- **Parametreler:**
  - `action` *(string, optional)*: İşlem: `put`, `get`, `list` (varsayılan), `search`, `set_ref`, `delete`.
  - `type` *(string, optional)*: Varlık tipi (yukarıdaki yedi değerden biri).
  - `title` *(string, `put` için gerekli)*: Varlık başlığı.
  - `body` *(string, optional)*: Gövde metni (markdown).
  - `tags` *(array veya virgüllü string, optional)*: Etiketler.
  - `links` *(object, optional)*: Çapraz referanslar, örn. `{"goal": "goal.1.<hash16>"}`.
  - `status` *(string, optional)*: Yaşam döngüsü durumu (varsayılan `active`).
  - `id` *(string, optional)*: Güncelleme/get/delete için varlık kimliği (çözüm formlarından biri).
  - `ref` *(string, optional)*: Varlığa bağlanan okunabilir alias (upsert semantiği).
  - `query` *(string, `search` için gerekli)*: Başlık/gövde/etiket üzerinde büyük-küçük harf duyarsız arama.
  - `format` *(string, optional)*: `markdown` (varsayılan) veya `json`.
- **Örnek Çağrı:**
  ```json
  { "action": "put", "type": "plan", "title": "Auth refactor", "body": "1. ... 2. ...", "tags": ["auth", "q3"], "ref": "current-plan" }
  ```
- **Örnek Çıktı:**
  ```text
  Stored: plan.1.9f86d081884c7d21 (version 1)
  URI: rubik://storage/myproj/plan/plan.1.9f86d081884c7d21
  Read back: read_file(path: 'rubik://storage/myproj/plan/plan.1.9f86d081884c7d21')
  ```
- **Erişim Politikası:** Yalnızca `coder` arketipi (ve `self`); `REQUIRES` koeksekti karşılanmadığında araç şemalardan gizlenir (`storage.enabled: false`).

---

### 9. Depo Okuma / Ekrana-Bas Aracı (`show_file`)

#### `show_file`
- **Diğer Adları:** `show`
- **Açıklama (iki düzlem):** Kalıcı bir depo varlığını (inceleme raporu, plan, hedef anlık görüntüsü, not...) okur. **Kök ajanda** tam içerik kullanıcının terminaline DOĞRUDAN basılır — kök model yalnız tek satırlık stub alır ("Rendered N lines to the user's terminal: ..."); "göster/show" isteklerinde `read_file` + yeniden yazma iki-hop maliyetini ortadan kaldırır, maestro doktriniyle uyumludur (yönetici bağlamı lean kalır). **Subagent düzleminde** tam içerik ajanın KENDİ bağlamına yüklenir (`read_file` gibi) — subagent'ların depo bilgilerini kendi bağlamlarına yüklemesi ve çalışmalarında kullanması engellenmez; terminal basımı kök ajana aittir.
- **Risk Seviyesi:** `:read`
- **Parametreler:**
  - `path` *(string, gerekli)*: Yalnız `rubik://storage/<proje>/<tip>/<id>` veya refs formu `rubik://storage/<proje>/refs/<alias>`; gerçek FS yolları reddedilir (onlar `read_file`ın işi). Gezinme: `rubik://storage/index`.
- **Sınırlar:** Büyük varlıklar inline basılmaz (kapılar: 400 satır / 64 KB) — dürüst hata, `read_file` offset/limit yönlendirmesi döner. Hatalar (varlık yok) display değildir, modelin düzeltme döngüsüne gider. `ui.verbosity=quiet` ve `debug` dahil her ayrıntı seviyesinde basılır — bu çıktı süsleme değil, kullanıcıya adresli teslimattır; `:user_output` event havuzu bağlanmamışsa içerik düşürülür ve stderr'e warn yazılır.
- **Örnek Çağrı:**
  ```json
  { "path": "rubik://storage/js-tangram/refs/tangram-review" }
  ```
- **Erişim Politikası:** `REQUIRES` koeksekti karşılanmadığında şemalardan gizlenir (`storage.enabled: false`). Kök ajan + `self`/özel tipler yayındadır; `research`/`coder` allowlist'leri önceden tasarlanmış en-yetke ilkesiyle bu aracı içermez — depo içeriğine `read_file` ile erişirler.

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
