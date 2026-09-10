# Plan 87 — ShellDeps Façade ve Artımlı Chunk Montajı (Plan 86 Ertelenenleri: D-5, D-1)

> **Durum:** ✅ Tamamlandı
> **Zorluk:** Orta–İleri
> **Faz:** 8 (Deferred Borç Devamı)
> **Öneri Bölümü:** Modülerlik / LLM Katmanı
> **İlgili Planlar:** [63](63-dis-degerlendirme-tavsiye-triyaji-ve-davranis-koruyucu-iyilestirmeler.md),
  [72](72-overlay-bootstrap-guven-kapisi-yukleme-hata-gorunurlugu-ve-kill-tree-saglamlastirma.md),
  [86](86-deferred-borc-temizligi-artimli-stream-repair-loop-ve-modulerlik.md)

---

## Motivasyon

Plan 86, beş deferred borçtan üçünü kapattı (D-2 karar, D-3 `requires:` DAG, D-4 platform split) ve
ikisini ayrı plana devretti:

- **D-5 → E-1:** `ShellDeps` façade — Plan 72'nin tetik koşulu ("shell yüzeyi genişlemeye devam
  ederse") dolu: üç orchestrator tüketicisinde **94 `@loop.` erişimi** (satır bazlı ölçüm:
  `step_executor` 40, `stream_manager` 31, `budget_manager` 23).
- **D-1 → E-2:** `BaseProvider#complete` chunk tamponunun artımlı akışa çevrilmesi —
  `ChunkAssembler.build`'in çok geçişli sözleşmesi nedeniyle Plan 86'da riskli bulunup ertelendi.

Sıralama Plan 86'daki değerlendirmeyi izler: mekanik ve düşük riskli olan **E-1 önce**,
sözleşme-duyarlı ve en riskli olan **E-2 sona** bırakılır.

---

## E-1: `ShellDeps` Façade (Demeter İhlalinin Kapatılması)

**Dosyalar:** `lib/rubik/orchestrator/loop.rb` (façade üretimi),
`step_executor.rb`, `stream_manager.rb`, `budget_manager.rb` (tüketici göçü)
**Risk:** DÜŞÜK–ORTA — davranış değişikliği yok; salt erişim listeleme.

### Mevcut durum (ölçüm, Plan 87 yazımı itibarıyla)

Üç tüketicinin `@loop.` erişim yüzeyi — sembol bazlı sayım:

| Sembol | step_executor | stream_manager | budget_manager | Tür |
|:---|:---:|:---:|:---:|:---|
| `step_count` | 8 | 7 | 6 | okuma |
| `buffer_manager` | 8 | — | — | okuma |
| `on_step` | 5 | 7 | 2 | okuma (callback) |
| `max_steps` | 5 | 7 | 5 | okuma |
| `shell` | 6 | — | — | okuma |
| `config` / `safe_config(...)` | — | 6+2 | 2 | okuma (yöntem) |
| `history` | 2 | 1 | 5 | okuma |
| `respond_to?(...)` | 4 | 4 | — | yetenek sorgusu |
| `lsp_manager` | 4 | — | — | okuma |
| `tool_registry` | 3 | — | — | okuma |
| `provider` | — | 3 | — | okuma |
| `total_tokens` | 3 | — | 2 | okuma + hash mutasyonu |
| `invalid_tool_count` | 3 | — | — | **yazma** (reset/++/karşılaştırma) |
| `last_turn_streamed` | 2 | 1 | — | **yazma** |
| `context_warning_emitted` | — | — | 2 | **yazma** |
| `activity` | 2 | — | — | okuma |
| `logger` | 1 | — | — | okuma |
| `budget_manager` | — | 1 | — | okuma (Demeter² — loop üzerinden) |
| `emergency_compact_and_notify` | — | 1 | — | yöntem çağrısı |

Önemli bulgu: yüzey salt-okunur değil — üç **yazma** sembolü var (`invalid_tool_count`,
`last_turn_streamed`, `context_warning_emitted`) ve `total_tokens` hash'i yerinde
mutasyona uğratılıyor. `loop.rb`'de bu semboller `attr_accessor` ile açılmış durumda.
Bu nedenle façade bir salt-okunur struct olamaz; dar bir **komut yüzeyi** de taşımalı.

### Öneri

`loop.rb`'de dar bir `ShellDeps` façade'ı üretilir ve üç tüketiciye inject edilir:

1. **Okuma yüzeyi:** gerçekten erişilen semboller tek nesnede toplanır — `history`,
   `activity`, `config`, `shell`, `buffer_manager`, `lsp_manager`, `tool_registry`,
   `provider`, `budget_manager`, `on_step`, `logger`, `step_count`, `max_steps`,
   `total_tokens` (hash referansı; içerik mutasyonu aynı nesne üzerinden kalır),
   `safe_config(...)`.
2. **Komut yüzeyi:** yazma erişimleri açık adlandırılmış yöntemlere dönüşür —
   `reset_invalid_tools!`, `record_invalid_tool!`, `mark_last_turn_streamed(text)`,
   `flag_context_warning!`, `emergency_compact_and_notify(...)`.
3. **Yetenek sorgusu:** `@loop.respond_to?(...)` çağrıları için façade `respond_to_missing?`
   üzerinden loop'u iletir (veya plandan çıkmadan önce kullanım noktaları tek tek
   incelenip sabit yetenek bayraklarına indirgenir — uygulama sırasında karar).
4. **Göç sırası:** üç tüketici tek tek göç ettirilir; her adımdan sonra tam suite yeşil
   doğrulanır (önerilen sıra: `budget_manager` → `stream_manager` → `step_executor` —
   en küçük yüzeyden en büyüğe).

### Kırmızı çizgi

- E-1 sonrası üç tüketicide `@loop.` **sıfır** (`grep -c "@loop\\."` temiz).
- Davranış değişikliği yok: `test_orchestrator_loop`, `test_tool_layer_hardening`,
  `test_tools_elm_diagnostics`, `test_stream_manager`, `test_budget_manager` birebir yeşil.

### Testler

- Yeni `test_shell_deps.rb`: sembol yüzeyi (okuma + komut yöntemleri), inject/stub davranışı,
  `respond_to_missing?` iletimi.
- Üç tüketicinin mevcut test dosyaları façade stub'ları üzerinden yeşil kalmalı.

### Uygulama Günlüğü ✅

**Durum:** ✅ Uygulandı — üç tüketici göçtü, `@loop.` erişimi sıfırlandı, davranış korundu.

- `lib/rubik/orchestrator/shell_deps.rb` (yeni) — `ShellDeps` façade. **Sapma 1:** sınıf loop.rb
  yerine ayrı dosyada; `Loop` üretip inject ediyor (loop.rb zaten 369 satır — hijyen eşiği aşılı
  durumdayken sınıf gömmek yerine ayrı dosya, planın "loop.rb'de üretilir" niyetini korur).
- **Sapma 2 (planın 3. maddesinin tercih edilen kolu):** okuma yüzeyi açık erişimci yerine
  `SURFACE` sabiti + `respond_to_missing?`/`method_missing` iletimi. Gerekçe: minimal test
  double'ları (`test_reasoning_stream_and_finish_diagnostics.rb`'deki Struct `fake_loop`'un
  `safe_config`'i yok) — açık erişimci `respond_to?`'u her zaman true yapacak ve yetenek
  sorgularını çözecekti; iletim mevcut semantiği birebir korur (test ile doğrulandı).
- **Sapma 3:** üç tüketicinin `initialize`'ı sarmalayıcı shim: ham loop kabul edilip
  `ShellDeps.new(...)` ile sarılır — mevcut test double'ları hiç değişmeden yeşil kalır.
- **Ölçüm düzeltmesi:** plan tablosunda `history` "okuma" işaretliydi; ölçümden kaçan
  `budget_manager.rb:44` yeniden ataması (`@loop.history = compact_history(...)`) komut yüzeyine
  `replace_history!` olarak eklendi.
- `loop_instance` erişimcisi eklendi: sonuç hash'leri (`res[:loop_instance]`) loop nesnesini
  taşımak zorunda (shell `continue_loop`'u bununla sürdürür) — planın dışında tespit edilen
  sözleşme.
- Göç: `budget_manager` → `stream_manager` → `step_executor` (plan sırası); her adımda ilgili
  test dosyaları + tam suite yeşil.
- Kırmızı çizgi: üç tüketicide `grep -c "@loop\\."` = 0 ✓ (loop.rb'deki 1 ve shell_deps.rb'deki
  8 erişim façade'ın kendisidir).

**Test sonucu:** `test_shell_deps.rb` — 10 run, 21 assertion, 0 failure (yüzey iletimi, yetenek
sorgusu, komut yöntemleri, fail-fast, loop_instance). Mevcut kapsam birebir yeşil.

**Fresh-eye inceleme düzeltmeleri (uygulama sonrası iki eksenli kod incelemesi):**

- **Regresyon:** `step_executor` göçünde `loop_instance: @loop` (çıplak ivar) `@loop\.` grep'i
  tarafından yakılamadı — `@loop` ivar'ı artık olmadığından sonuç hash'leri her zaman
  `nil` taşıyor ve `repl/shell.rb`'deki `res[:loop_instance]&.history` sessizce no-op
  yapıyordu. `@deps.loop_instance` ile düzeltildi; sözleşmeyi sabitleyen yeni test
  (`test_turn_result_hashes_carry_the_loop_instance`) eklendi.
- **Hayalet yüzey:** `:logger` SURFACE'teydi ama `Loop`'ta logger yok — `step_executor`'un
  rescue dalındaki `@deps.logger&.debug` hata yakalayıcının içinden NoMethodError
  fırlatacaktı (önceden var olan gizli hata; `&.` yanıltıcıydı). `:logger` yüzeyden çıkarıldı;
  rescue artık `warn` ile stderr'a yazıyor.
- **DRY:** üç tüketicideki `initialize` sarmalayıcı shim'i `ShellDeps.wrap` olarak tek
  noktaya indirildi.
- **Bildirim tamamlama:** komut yöntemi adları plandakinden sapmaktadır —
  `mark_last_turn_streamed!` (bang + bool) ve `emergency_compact_and_notify!(reason)`;
  SURFACE'teki `context_limit`/`max_output_tokens` plan tablosunda yoktu (tablo eksikti,
  budget_manager'ın 8 önceden var olan okuması). İkisi de burada beyan edilir.
- **Golden sıralama kanıtı:** tek squash commit nedeniyle git geçmişi "golden'lar önce"
  sıralamasını doğrulayamaz; sıralama oturum kaydıyla belgelenir, test dosyası yorumu bunu
  beyan eder.
- `require_relative "provider"` koşulsuz yapıldı (defined? guard'ı spekülatifti; Response
  yüklenmesini de garanti eder; provider chunk_assembler'ı require etmez — döngü yok).
- Eşdeğerlilik testi yorumu düzeltildi: `build` artık Assembler'a delege olduğundan
  karşılaştırma yapısal; mutlak çıktılar golden'lar tarafından bağımsız sabitlenir.

---

## E-2: `BaseProvider#complete` — Artımlı Chunk Montajı

**Dosyalar:** `lib/rubik/llm/chunk_assembler.rb`, `lib/rubik/llm/provider.rb`
**Risk:** ORTA–YÜKSEK — `complete` ve `ChunkAssembler.build` dönüş sözleşmesi korunmalı;
her iki çağrı noktası (`provider.rb:108`, `stream_manager.rb:103`) aynı sınıfı kullanır.

### Mevcut durum

`provider.rb:100-109` — `complete` tüm chunk'ları bellekte biriktirir:

```ruby
def complete(messages, opts = {})
  chunks = []
  result = stream_chat(messages, opts) do |chunk|
    chunks << chunk
  end
  result.each { |chunk| chunks << chunk } if result.is_a?(Enumerator) && chunks.empty?
  Rubik::LLM::ChunkAssembler.build(chunks, streamed: false)
end
```

`ChunkAssembler.build(chunks, ...)` (200 satırlık dosya) **çok geçişli** çalışır:

1. text: `chunks.map(&:text_delta).compact.join`
2. reasoning: `chunks.select { |c| c.reasoning_delta? }.map(&:reasoning_delta).compact.join`
3. tool_use_delta: slot çözümlemeli tek geçiş (Red-team B2 composite-key mantığı:
   `"#{base_idx}:#{d_id}"`; B3 ekleme sırası, B4 id'siz farklı call ayrımı, B5 çakışma notları)
4. finish/usage: `resolve_usage(chunks, text, ...)` + `extract_finish_value(raw)`

Uzun üretimlerde chunk **listesi** ( obje başına overhead) belleği şişirir; metin/argüman
zaten birikmek zorunda, ancak liste + Chunk nesneleri O(chunk) fazladan yer tutar.

### Öneri

1. **Golden snapshot önce:** yeniden yazmadan önce, mevcut `build` çıktıları gerçekçi
   chunk dizileriyle sabitlenir (test_chunk_assembler'a golden testler eklenir): düz metin,
   reasoning karışımı, `tool_use_delta` split, composite-key slot açılması, finish/usage
   varyantları. Bu anlık görüntüler E-2'nin güvenlik ağıdır.
2. **Artımlı montajcı:** `Rubik::LLM::Chunk::Assembler` (örnek tabanlı) — `push(chunk)` her
   chunk'ı O(1) işler: metin bir String tamponuna, reasoning ayrı tampona, tool argümanları
   slot başına JSON string'ine eklenir (aynı `resolve_slot` mantığı), finish/usage
   "son yazan kazanır". `finish(streamed:, estimate_history:, estimate_text:,
   on_malformed_args:)` build ile **aynı sonuç nesnesini** üretir.
3. **SSOT:** mevcut `ChunkAssembler.build`, artımlı montajcıya delege olur (tek mantık
   kaynağı) — imza ve dönüş değeri değişmez; `stream_manager.rb:103` çağrı noktası
   etkilenmez.
4. **`complete` yeniden yönlendirme:** biriktirme yerine akış doğrudan montajcıya bağlanır;
   Enumerator emme yolu (stream-only provider'lar) korunur; `streamed: false` sözleşmesi
   aynı kalır.
5. **Eşdeğerlilik doğrulaması:** aynı chunk dizisi hem golden anlık görüntüyle hem yeni
   artımlı yolla üretilip birebir karşılaştırılır.

### Kırmızı çizgi

- `complete` dönüş sözleşmesi değişmez: 13 stream testi + `test_llm_provider` +
  `test_chunk_assembler` birebir yeşil.
- `ChunkAssembler.build` imzası ve `stream_manager` çağrı noktası değişmez.

### Testler

- Golden snapshot testleri (yeniden yazmadan ÖNCE yazılır ve yeşil doğrulanır).
- Artımlı montajcı birim testleri (`push`/`finish` yaşam döngüsü, slot çözümü, usage).
- Eşdeğerlilik testi (build ↔ artımlı, aynı diziden aynı sonuç).

### Uygulama Günlüğü ✅

**Durum:** ✅ Uygulandı — golden'lar önce sabitlendi, artımlı montajcı birebir eşdeğer çıktı
üretiyor, `complete` biriktirmeyi bıraktı.

- **Golden snapshot'lar önce:** `test_chunk_assembler.rb`'ye 5 paylaşımlı fixture (A: metin +
  reasoning + delta args + usage + finish; B: composite-key split; C: Anthropic raw yolları;
  D: finish promotion; E: malformed + degenerate) ve bunları tüm Response alanları üzerinden
  sabitleyen 5 golden test yazıldı; mevcut `build`'e karşı yeşil doğrulandı (rewrite öncesi).
- **Sapma 1 (isim):** plan `Rubik::LLM::Chunk::Assembler` demişti — aynen uygulandı; ancak
  mevcut `ChunkAssembler` bir **module** olduğu için (module_function) instance API yeni
  `Chunk` iç içe sınıfında; `ChunkAssembler.build` artık ona delege ediyor (SSOT, imza ve
  çağrı noktaları değişmez).
- `push` O(1): metin/reasoning String tamponları, slot başına args_json birikimi (aynı
  `resolve_slot`/B2 mantığı), usage/raw/finish "son yazan kazanır". `finish` parse + degenerate
  fallback + usage + finish promotion'ı build ile birebir aynı sırayla uygular.
- **Bilinen kabul sapması (B3 sınıfı):** build, tool_use_delta geçişini TÜM chunk'larda
  tamamladıktan sonra raw geçişini yapar; `push` her chunk'ta ikisini iç içe uygular. Aynı
  index'e bir raw message ve FARKLI id'li bir delta'nın çapraz gelmesi patolojik durumunda
  slot sırası değişebilir; runtime eşleşme call id üzerindendir, sıra değil (kod yorumunda
  belgelendi).
- `resolve_usage`/`extract_finish_value` module-function'ları kaldırıldı (dış kullanım yoktu —
  grep ile doğrulandı; mantık Assembler'da birebir korundu).
- `complete` (provider.rb): biriktirme yok — akış doğrudan `Assembler#push`'a; Enumerator
  emme yolu `pushed?` ile aynı semantikte korundu; `streamed: false` sözleşmesi aynı.
- Eşdeğerlilik: 5 fixture × 6 alan (text/thought/tool_calls/usage/raw/streamed) build ↔
  artımlı birebir aynı — test yeşil.

**Test sonucu:** `test_chunk_assembler.rb` — 17 run, 91 assertion, 0 failure (5 golden +
eşdeğerlilik + 11 mevcut); `test_llm_provider` 8 run, 13 stream testi birebir yeşil.

---

## Kapsam Dışı Notlar

- **D-2 entegrasyonu (Repair::Loop canlandırma):** Plan 86'da bilinçli karar ile dormant
  kapasite olarak kapatıldı — ertelenen iş değil, kapatılan karardır. Orkestratör döngüsüne
  "diagnose-on-failure" kancası eklemek ayrı bir mimari değişikliktir; talep gelirse
  kendi planında ele alınır.
- **`stream_manager`'ın artımlı montajcıyı benimsemesi:** E-2 sonrası artımlı API mevcut
  olduğundan `stream_manager.rb:103` göçü küçük bir takip işidir; bu planın kapsamı
  dışında tutulur (tek tüketici göçü = sınırlı risk ilkesi).

---

## Uygulama Sırası

1. **E-1** — `ShellDeps` façade: façade + `test_shell_deps.rb` → `budget_manager` göçü →
   `stream_manager` göçü → `step_executor` göçü (her adımda tam suite + grep kırmızı çizgisi).
2. **E-2** — golden snapshot'lar → artımlı montajcı + birim testleri → `build` delegasyonu →
   `complete` yeniden yönlendirme (her adımda tam suite).

## Etkilenen Dosyalar

| Dosya | Kapsam |
|:---|:---|
| `lib/rubik/orchestrator/loop.rb` | E-1: `ShellDeps` façade üretimi + inject |
| `lib/rubik/orchestrator/{step_executor,stream_manager,budget_manager}.rb` | E-1: `@loop.` → `deps.` göçü (94 erişim) |
| `lib/rubik/llm/chunk_assembler.rb` | E-2: artımlı montajcı + `build` delegasyonu |
| `lib/rubik/llm/provider.rb` | E-2: `complete` artımlı yola geçiş |
| `test/unit/test_shell_deps.rb` | E-1: yeni |
| `test/unit/test_chunk_assembler.rb` | E-2: golden snapshot + artımlı + eşdeğerlilik testleri |

## Test Yükümlülüğü

| Madde | Mevcut kapsam | Yazılacak testler |
|:--|:---|:---|
| E-1 | `test_orchestrator_loop`, `test_tool_layer_hardening`, `test_tools_elm_diagnostics`, `test_stream_manager`, `test_budget_manager` | `test_shell_deps.rb` (yüzey + stub davranışı) |
| E-2 | `test_llm_provider`, `test_chunk_assembler`, 13 stream testi | Golden snapshot'lar (önce), artımlı montajcı birim testleri, eşdeğerlilik testi |

## Kabul Kriterleri

- [x] Üç tüketicide `grep -c "@loop\\."` sıfır; façade yüzeyi tablodaki sembollerle sınırlı.
- [x] `complete` ve `ChunkAssembler.build` dönüş sözleşmeleri değişmez; tüm mevcut
      stream/complete testleri birebir yeşil.
- [x] Golden snapshot'lar yeniden yazmadan önce yazılıp yeşil doğrulanmıştır.
- [x] `bundle exec rake test` 0 failure / 0 error (mevcut 1 skip korunur), `rubocop` 0 offense.

## ✅ Özet

| Madde | Durum | Not |
|:---|:---|:---|
| E-1 | ✅ Tamamlandı | `ShellDeps` façade; üç tüketici göçtü; `@loop.` = 0; 10 yeni test |
| E-2 | ✅ Tamamlandı | Artımlı `Chunk::Assembler` + `build` delegasyonu; `complete` biriktirmiyor; 5 golden + eşdeğerlilik testi |

**Toplam test durumu:** `bundle exec rake test` — 1473 run, 8777 assertion, 0 failure, 0 error,
1 skip. Değişen dosyalarda `rubocop` 0 offense (repoda 4 önceden var olan offense korunur).
