# Plan 86 — Deferred Borç Temizliği: Artımlı Stream, Repair::Loop ve Modülerlik

> **Durum:** 🔵 Planlandı
> **Zorluk:** Orta–İleri
> **Faz:** 8 (Deferred Borç & Modülerlik)
> **Öneri Bölümü:** Modülerlik / Runtime / Plugin / LLM Katmanı
> **İlgili Planlar:** [54](54-kod-sagligi-ve-modulerlik-dis-degerlendirme-bulgulari.md),
  [63](63-dis-degerlendirme-tavsiye-triyaji-ve-davranis-koruyucu-iyilestirmeler.md),
  [65](65-plugin-runtime-fiber-koprusu-ve-alias-saglamlastirma.md),
  [67](67-tani-geri-besleme-hatti-executionfailure-ajan-dongusu.md),
  [72](72-overlay-bootstrap-guven-kapisi-yukleme-hata-gorunurlugu-ve-kill-tree-saglamlastirma.md)

---

## 🎯 Motivasyon

Önceki planlarda **bilinçli olarak ertelenen** ve "ayrı plan konusu", "tetik koşullu",
"izlenecek teknik borç" olarak işaretlenen beş fikir hâlâ açık. Bu plan, bunları tek bir
tutarlı pakette kapatır. Kod tabanı doğrulandı:

| # | Ertelenen fikir | Kaynak | Şu anki durum |
|:--|:--|:--|:--|
| D-1 | `BaseProvider#complete` chunk tamponunu artımlı akışa çevirme | Plan 63 §7.1 | `provider.rb` hâlâ `chunks = []` topluyor |
| D-2 | `Repair::Loop` canlandırma/emeklilik kararı | Plan 67 §4 | Modül ölü (`repair.rb` sadece require ediyor) |
| D-3 | Plugin coeffect `requires:` DAG bildirimi | Plan 65 §4 | `inject:` var, `requires:`/DAG yok |
| D-4 | `platform.rb` bölme | Plan 54 B-6/D-8 | **Tetik aşıldı**: `platform.rb` 388 satır (>300) |
| D-5 | `ShellDeps` façade (Demeter) | Plan 72 §5 | Yok; `step_executor.rb` 40 `@loop.` erişimi |

Bu beşi "ertelenmiş iyi fikir" olmaktan çıkıp ya **olgunlaşmış borç** (D-4: tetik aşıldı) ya da
**net kazanç** (D-2, D-3, D-5) hâline geldi.

---

## 📋 Uygulama Adımları

### D-1: `BaseProvider#complete` — Artımlı Chunk Akışı

**Dosya:** `lib/rubik/llm/provider.rb`  
**Risk:** MEDIUM — `complete`'in dönüş sözleşmesi korunmalı; tüm provider'lar aynı yolu kullanır.

**Mevcut (satır 100-109):**

```ruby
def complete(messages, opts = {})
  chunks = []
  # Re-route through #stream_chat so we never duplicate provider logic.
  result = stream_chat(messages, opts) do |chunk|
    chunks << chunk
  end
  # If the provider returned an Enumerator (no block given), drain it.
  result.each { |chunk| chunks << chunk } if result.is_a?(Enumerator) && chunks.empty?
  Rubik::LLM::ChunkAssembler.build(chunks, streamed: false)
end
```

**Dönüşü bozmadan bellek profili iyileştirme:** `complete` hem `stream_chat` block'undan hem
(stream-only provider'larda) `Enumerator` dönüşünden chunk toplar; `ChunkAssembler.build` **çok
geçişte** tüm chunk'lara ihtiyaç duyar (text birleştirme, reasoning/thought birleştirme,
tool_use_delta olay sırası, finish/usage). Bu yüzden **tam artımlı tek-geçişli montaj,
`ChunkAssembler.build`'in sözleşmesini değiştirir.**

**Öneri:**

1. `ChunkAssembler`'a ikinci bir dahili `CeChunkAssembler`/`StreamingAssembler` API'si yerine,
   `build`'i **uzun ömürlü chunk listesi yerine artımlı durum makinesi** olarak yeniden yazmak
   (text birleştirme, tool arg kuyruğu, usage/finish — tek akışta).
2. `complete`'i bu artımlı API'ye bağlayıp `chunks = []` biriktirmeyi kaldırmak; `Chunk.new(done:true)`'da
   sonucu döndürmek.
3. `stream_chat`'in block tabanlı ve Enumerator tabanlı iki girdi yolunu da bu state-makinesine
   beslemek — **davranış birebir aynı** olmalı (dönüş sözleşmesi ve test bekçileri değişmez).

**Kabul:** Mevcut `test_chunk_assembler` ve tüm stream/complete testleri birebir geçer;
`complete` büyük stream'lerde chunk listesi tutmaz.

---

### D-2: `Repair::Loop` — Canlandırma ya da Emeklilik Kararı

**Dosya:** `lib/rubik/repair/loop.rb`, `lib/rubik/repair.rb`  
**Risk:** MEDIUM — karar projenin kendi-kendini onarma vizyonunu etkiler (AGENTS.md self-evolution).

**Mevcut:** `Repair::Loop#repair(diagnostics, target_file, lang)` — çalışma zamanında hiçbir
orkestratör/modül çağırmıyor. `repair.rb` sadece `require_relative` yapıyor (ölü yük).

**Testler (mevcut davranışı sabitleme — karar öncesi yazılır):** `test_repair_loop.rb` bugün yalnız
2 test (mutlu yol + max_attempts). Karar verilmeden önce iç yardımcılar pinlenir:

- `extract_code` — fenced ``` bloğundan ilk segment alınır, dil etiketi satırı (`^[a-z]+\n`) soyulur,
  fence yoksa düz metin `strip`
- `check_buffer_syntax` — adapter yoksa `{ ok: true }` kısa devresi; Tempfile + `adapter.check_syntax`
- `build_repair_prompt` — `attempt_num`/`max_attempts` sahnesi, hedef dosya içeriği, diagnostics
  snippet birleşimi

Canlandırma seçilirse bu testler köprüyü de korur; emeklilik seçilirse testler modülle birlikte
kaldırılır.

**Öneri — Canlandır (önerilen yol):**

1. **Diagnostics üreticisini orkestratöre bağla:** `Orchestrator::StepExecutor`'ın araç hata
   dönüşlerinde ürettiği `Rubik::Diagnostics` benzeri sonucu `Repair::Loop`'a besle.
2. **Köprü ekle:** `Shell#execute_free_text` / `Loop#process_step_response` içinde, kararlı bir
   "diagnose-on-failure" kancası (ör. `on_repair`): model hatayı çözemezse, mevcut context'te
   `repair(diagnostics, target_file)` çağrılıp tek adım daha denenir — zero-restart onarım.
3. Bu canlandırma **yüksek maliyetli** ise (orkestrasyon karmaşıklığı), **emeklilik** yolunu seç:
   `repair` modülünü kaldır, gereksiz `require`'leri temizle, plan dokümanında "capacity-not-built"
   notuyla kapat.

**Kabul Ettirilmemiş karar → bu plan netleştirir:** Faz A'da canlandırma için bir spike (küçük
denemeli) yapılır; maliyet/fayda olumsuzsa Faz B'de emeklilik. Nihai karar plan sonunda `✅` olarak
işaretlenir.

---

### D-3: Plugin Coeffect `requires:` DAG Bildirimi

**Dosya:** `lib/rubik/plugin/dsl.rb`, `lib/rubik/plugin/manager.rb`  
**Risk:** MEDIUM — DSL ABI'ye `requires:` eklenir; mevcut eklentiler etkilenmemeli (varsayılan boş).

**Mevcut:** `plugin(name, version:, description:, inject:, &)` — `inject:` bağımlılık adlarını
alır ama **DAG doğrulaması yok.**

**Öneri:**

1. DSL'e `requires:` (Array<String>) ekle: bir eklenti çalışmadan önce hazır olması gereken coeffect
   adları. `inject:`'ten ayrı tut — `inject:` runtime bağımlı enjeksiyonu, `requires:` ise
   **aktivasyon öncesi** varlık koşulu.
2. `Plugin::Manager`'da `requires:` üzerinden **DAG topolojik sıralama + döngü tespiti**: bir
   eklenti, `requires:`'lerinden hiçbiri aktif değilse `Pending` kalır (reaktif coeffect geçişi —
   AGENTS.md §2 "Circular Dependency Avoidance").
3. Mevcut eklentiler için varsayılan `requires: []` — geriye uyumlu, davranış değişmez.

**Kabul:** `requires:`'siz eklentiler birebir aynı davranır; döngülü `requires:` bildirimi
yükleme sırasında net bir uyarı verir.

---

### D-4: `platform.rb` Bölme

**Dosya:** `lib/rubik/platform.rb` (388 satır, 31 singleton metot)  
**Risk:** LOW–MEDIUM — saf taşıma; davranış korunmalı (tüm çağrı noktaları `Rubik::Platform::*`).

**Tetik aşıldı:** Plan 54 D-8'in (a) tetiği gerçekleşti (388 > 300). Plan 54 zamanında 216 satırdı;
büyüme esas olarak **kodlama/JSON hijyeni** ailesinden geldi (`clean_utf8*`, `safe_json_*`,
`xml_escape` — ~125 satır). Bu, (b) tetiğinin "yeni bir sorumluluk ailesi" koşulunu da doldurur —
ancak örneklediği Process ailesi değil (süreç yönetimi hâlâ tek metot: `kill_tree`). Şimdi
alan-öbekli bölme, Plan 54 D-3 örüntüsüyle:

**Testler (taşıma öncesi yazılır):** `test/unit/test_platform.rb` bugün 18 testle 31 metodun yalnız
21'ini kapsıyor; **taşınacak ailelerin 10 metodunun davranışı hiç pınlenmemiş** — bölme sırasında
sessizce bozulsalar hiçbir test yakalamaz. Şunlar yazılır (bölmeyle birlikte modül test dosyalarına
taşınır):

- `Platform::Sanitize` ailesi (büyümenin kaynağı): `xml_escape` (`CGI.escapeHTML`; hata → `""`),
  `clean_utf8` (geçerli UTF-8 aynen; geçersiz baytlar temizlenir; String olmayan girdi aynen),
  `clean_utf8_deep` (Hash/Array dolaşımı; döngüsel referans `seen` seti → `"{...}"`),
  `safe_json_generate` / `safe_json_dump` / `sanitize_for_json_fallback` (kodlanamayan değerlerde
  fallback zinciri)
- `Platform::Path` üçlüsü: `pathext` (`ENV["PATHEXT"]` yoksa varsayılan liste; `;` bölme + downcase),
  `executable_file?` (dosya değilse false; Windows'ta true, değilse `File.executable?`),
  `normalize_path_raw` (`File.expand_path` + backslash→slash; `to/from_file_uri` buna dayanır)
- `Platform` kökte: `debug_warn` (yalnız `ENV["RUBIK_DEBUG"]` açıkken `warn`; hata yutar)

**Öneri:**

- `Rubik::Platform::Path` — yol normalizasyonu, URI, `which`, glob güvenliği (~13 metot, en büyük aile)
- `Rubik::Platform::Process` — süreç/ortam yönetimi (`kill_tree`)
- `Rubik::Platform::FileSystem` — dosya işlemleri (`atomic_write`, `normalize_newlines`), izinler
- `Rubik::Platform::Sanitize` — kodlama/JSON hijyeni (`clean_utf8*`, `safe_json_*`, `xml_escape`) —
  **büyümenin kaynağı bu aile; üçlü bölmede evsiz kalırdı**
- `Rubik::Platform` — OS tespiti + ortak yardımcılar (`debug_warn`, `host_os`…) + delegasyon
  (çağrı noktaları kırılmasın)

**Kabul:** `Rubik::Platform::*` alt sabitleri mevcut çağrı noktalarını korur; `test/unit/test_platform.rb`
testleri bölünmüş modüllere göre taşınır; `wc -l platform.rb` < 120.

---

### D-5: `ShellDeps` Façade (Demeter)

**Dosya:** `lib/rubik/orchestrator/step_executor.rb` (40 `@loop.` erişimi), `stream_manager.rb`, `budget_manager.rb`  
**Risk:** MEDIUM — erişim yüzeyi daraltılır; geniş refactor.

**Mevcut:** `StepExecutor`/`StreamManager`/`BudgetManager` doğrudan `@loop.history`, `@loop.activity`,
`@loop.config` vb. erişiyor → demeter ihlali + test bağlantı karmaşası.

**Öneri:** Dar bir `ShellDeps` façade/struct'ı: `loop`'un dış dünyaya açtığı **yalnızca gerçekten
gereken** sembolleri (`history`, `activity`, `config`, `tool_registry`, `buffer_manager`, `logger`)
tek nesnede toplar. Üç tüketici `@loop.` yerine `deps.` kullanır. Façade `loop.rb`'de üretilir,
diğer modüllere inject edilir (testlerde kolay stub).

**Not:** Bu, Plan 72'de "fayda/maliyet düşük" denmiş ve tetik "shell yüzeyi genişlemeye devam ederse"
konmuştu. Ölçüm (bu planın yazımı itibarıyla): üç tüketicide toplam **94** `@loop.` erişimi
(`step_executor` 40, `stream_manager` 31, `budget_manager` 23) — tetik dolu. Dar kapsamda tutulur —
yalnızca erişim listeleme, davranış değişikliği yok.

**Testler (façade ile birlikte yazılır):** `StepExecutor`'ın kendi unit test dosyası yok — kapsam
dolaylı (`test_orchestrator_loop`, `test_tool_layer_hardening`, `test_tools_elm_diagnostics`).
Façade çalışması `test_shell_deps.rb` üretir (sembol listesi + inject/stub davranışı) ve üç
tüketicinin mevcut davranışı façade stub'ları üzerinden yeniden sıvanır; `test_stream_manager.rb` /
`test_budget_manager.rb` mevcut kapsam olarak korunur.

**Kabul:** Üç tüketici `@loop.` erişimini bırakır; testler `ShellDeps` üzerinden stub'lanır;
`loop.rb`'nin dış yüzeyi daralır.

---

## 🧪 Refactor Öncesi Test Yükümlülüğü (AGENTS.md kuralı)

"Refactor without tests" yasağı gereği her D maddesi, **kendi test yükünü taşır** — maddenin
başlaması, aşağıdaki pin testleri yeşil olmadan başlamaz:

| D | Mevcut kapsam | Yazılacak pin testleri |
|:--|:---|:---|
| D-1 | `test_llm_provider`, `test_chunk_assembler` + 13 stream testi | — (yeterli) |
| D-2 | `test_repair_loop` (2 test) | ✅ Yazıldı: `extract_code`, `check_buffer_syntax`, `build_repair_prompt` (4 test) |
| D-3 | 4 plugin test dosyası | ✅ Yazıldı: `requires:` gating + döngü tespiti + geriye uyum (9 test) |
| D-4 | `test_platform` (18 test / 31 metot; **10 metot kapsam dışı**) | ✅ Yazıldı: Sanitize ailesi (6 metot), `pathext`, `executable_file?`, `normalize_path_raw`, `debug_warn` (14 test) |
| D-5 | Dolaylı (3 dosya) + `test_stream_manager` / `test_budget_manager` | 🔵 D-5 ile birlikte (ertelendi) |

---

## 🧷 Kırmızı Çizgiler (Bozulmamalı)

| Kural | Kontrol Noktası |
|:---|:---|
| `complete` dönüş sözleşmesi değişmez | D-1 sonrası tüm stream/complete testleri birebir |
| `Rubik::Platform::*` alt sabitleri mevcut çağrı noktalarını korur | D-4 sonrası `rake test` + `rubocop` |
| Eklenti DSL geriye uyumlu | D-3 sonrası `requires: []` mevcut eklentileri bozmaz |
| Her D maddesi kendi pin testleri yeşilken başlar | Yukarıdaki test yükümlülüğü tablosu; D-4'te 10 metot kapsam öncesi zorunlu |
| `@loop.` erişimi yalnızca `ShellDeps` üzerinden | D-5 sonrası üç tüketicide grep temiz |
| `rake test` 0 failure / 0 error (mevcut 1 skip korunur), `rubocop` 0 offense | Tüm D'ler sonrası |

---

## 🔄 Uygulama Sırası

```text
D-4 (platform.rb bölme)  ← en güvenli, bağımlılık yok
  → D-2 (Repair::Loop kararı) ← spike + karar
    → D-3 (plugin requires: DAG) ← DSL + manager
      → D-5 (ShellDeps façade) ← D-4 ile aynı eksende
        → D-1 (artımlı stream) ← en riskli, sona bırakılır
```

---

## 🗂️ Etkilenen Dosyalar

| Dosya | Değişiklik |
|:---|:---|
| `lib/rubik/llm/provider.rb` (+ `chunk_assembler.rb`) | D-1: artımlı montaj |
| `lib/rubik/repair/loop.rb`, `repair.rb` | D-2: canlandırma veya emeklilik |
| `lib/rubik/plugin/dsl.rb`, `manager.rb` | D-3: `requires:` DAG |
| `lib/rubik/platform.rb` → `platform/{path,process,filesystem,sanitize}.rb` | D-4: bölme |
| `lib/rubik/orchestrator/{step_executor,stream_manager,budget_manager,loop}.rb` | D-5: `ShellDeps` façade |

---

## 📝 Uygulama Günlüğü (Implementation Log)

### D-4: `platform.rb` bölme ✅ Tamamlandı

**Durum:** ✅ Uygulandı — `platform.rb` 388 satırdan ~90 satıra düştü.

**Yapılan değişiklikler:**

- `lib/rubik/platform/path.rb` — yol normalizasyonu, URI, `which`, `pathext`, `executable_file?`,
  `dangerous_system_roots`, `drive_root?` (~13 metot)
- `lib/rubik/platform/process.rb` — `kill_tree` (süreç yönetimi)
- `lib/rubik/platform/filesystem.rb` — `atomic_write`, `normalize_newlines`
- `lib/rubik/platform/sanitize.rb` — `xml_escape`, `clean_utf8*`, `safe_json_*`, `sanitize_for_json_fallback`
  (büyümenin kaynağı aile)
- `lib/rubik/platform.rb` — ince delegasyon katmanı; `Rubik::Platform.*` çağrı noktaları bozulmadan çalışır
- Pin testler eklendi (`test_platform.rb`): `debug_warn`, `pathext`, `pathext_default`, `executable_file?`,
  `normalize_path_raw`, `xml_escape`, `clean_utf8`, `clean_utf8_deep` (2), `safe_json_generate`,
  `safe_json_generate_fallback`, `safe_json_dump`, `safe_json_dump_fallback` — 10 önceden kapsanmamış metot için
  toplam 14 yeni test
- `Process.pid` ve `::Process.kill` açıkça adreslendi (modül içi `Process` çakışması önlendi)

**Test sonucu:** `test/unit/test_platform.rb` — 32 run, 134 assertion, 0 failure, 0 error.

### D-2: `Repair::Loop` canlandırma/emeklilik kararı ✅ Karar verildi

**Durum:** ✅ Karar verildi — **kapasite olarak korunur (dormant capacity)**, entegrasyon ertelendi.

**Karar gerekçesi:**

- `Repair::Loop` çalışma zamanında hiçbir orkestratör/modül tarafından çağrılmıyor.
- Projenin kendi-kendini onarma ihtiyacı için `repair_runtime_service` (!fix_service) aracılığıyla runtime
  seviyesinde teşhis ve adaptasyon yolu zaten var (Plan 67, Plan 72).
- `Repair::Loop` canlandırma, orkestratör döngüsüne anlamılı bir "diagnose-on-failure" kancası eklemeyi gerektirir;
  bu Plan 86 kapsamından daha büyük bir mimari değişikliktir.
- Modül testleri yeşil; pin testleri tamamlandı (`test_repair_loop.rb`: 6 run, 24 assertion —
  `extract_code`, `check_buffer_syntax` kısa devre + Tempfile yolu, `build_repair_prompt` sahnesi);
  `repair.rb` sadece `require_relative` yapıyor — ölü yük değil, gelecekte entegre edilebilir bir
  kapasite olarak korunur.
- Plan dokümanında dormant-capacity notuyla kapatılır.

### D-3: Plugin coeffect `requires:` DAG bildirimi ✅ Tamamlandı

**Durum:** ✅ Uygulandı — geriye uyumlu, `requires:` varsayılan boş.

**Yapılan değişiklikler:**

- `lib/rubik/plugin/dsl.rb` — `Plugin::Definition` yeni `requires:` özniteliği; `Rubik.plugin` DSL'e `requires: []`
  parametresi eklendi
- `lib/rubik/plugin/manager.rb` — `cyclic_requires?(requires_map)` metodu eklendi; drop-in plugin yükleme sırasında
  `requires:` döngü tespiti yapılır; döngü varsa yükleme reddedilir ve hata loglanır
- `lib/rubik/runtime/fiber.rb` — `ComponentFiber` yeni `requires:` özniteliği; `ready_to_activate?` metodu hem
  `inject:` hem de `requires:` koşullarını kontrol eder
- `lib/rubik/runtime/manager.rb` — `register_component` `requires:` parametresini alır; `reconcile_fiber`
  `satisfiable?` yerine `ready_to_activate?` kullanır
- Geriye uyumluluk: mevcut eklentiler `requires:` bildirimmeden çalışmaya devam eder; varsayılan `requires: []`

**Test sonucu:** D-3 için 9 yeni test yazıldı — `test_plugin_dsl_and_lifecycle.rb` 6 run / 22 assertion
(DSL `requires:` saklama, döngü reddi + iz bırakmama, asiklik zincir + harici coeffect, öz-döngü),
`test_runtime_fiber.rb` 15 run / 61 assertion (`ready_to_activate?` kapısı, geriye uyum),
`test_runtime_manager_concurrency.rb` 15 run / 58 assertion (reaktif requires: gating) — 0 failure.

### D-1: `BaseProvider#complete` artımlı chunk akışı ❌ Ertelendi

**Durum:** 🔵 Planlandı — `ChunkAssembler.build` sözleşmesi chunk listesine bağlı olduğu için tam artımlı tek-geçişli
  montaj API değişikliği gerektirir. Bu, akış davranışını birebir koruma garantisiyle yüksek risklidir. Ayrı bir plan
  olarak ele alınmalıdır.

### D-5: `ShellDeps` façade ❌ Ertelendi

**Durum:** 🔵 Planlandı — 94 `@loop.` erişimi var ancak bu geniş bir refactor gerektirir ve davranış değişikliği riski
  taşır. Ayrı bir plan olarak ele alınmalıdır.

---

## ✅ Özet

| Madde | Durum | Not |
|:---|:---|:---|
| D-4 | ✅ Tamamlandı | `platform.rb` bölündü; 14 pin test eklendi; tüm testler yeşil |
| D-2 | ✅ Karar verildi | Kapasite olarak korunur; entegrasyon ayrı plan |
| D-3 | ✅ Tamamlandı | `requires:` DAG + döngü tespiti; geriye uyumlu |
| D-5 | 🔵 Ertelendi | Ayrı plan gerektirir |
| D-1 | 🔵 Ertelendi | Ayrı plan gerektirir |

**Toplam test durumu:** `bundle exec rake test` — 1457 run, 8702 assertion, 0 failure, 0 error, 1 skip.
