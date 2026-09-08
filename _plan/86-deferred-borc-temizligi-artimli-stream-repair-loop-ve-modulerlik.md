# Plan 86 — Deferred Borç Temizliği: Artımlı Stream, Repair::Loop ve Modülerlik

> **Durum:** 🔵 Planlandı
> **Zorluk:** Orta–İleri
> **Faz:** 8 (Deferred Borç & Modülerlik)
> **Öneri Bölümü:** Modülerlik / Runtime / Plugin / LLM Katmanı
> **İlgili Planlar:** [54](54-kod-sagligi-ve-modulerlik-dis-degerlendirme-bulgulari.md), [63](63-dis-degerlendirme-tavsiye-triyaji-ve-davranis-koruyucu-iyilestirmeler.md), [65](65-plugin-runtime-fiber-koprusu-ve-alias-saglamlastirma.md), [67](67-tani-geri-besleme-hatti-executionfailure-ajan-dongusu.md), [72](72-overlay-bootstrap-guven-kapisi-yukleme-hata-gorunurlugu-ve-kill-tree-saglamlastirma.md)

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
| D-4 | `platform.rb` bölme | Plan 54 B-6/D-8 | **Tetik aşıldı**: `platform.rb` 378 satır (>300) |
| D-5 | `ShellDeps` façade (Demeter) | Plan 72 §5 | Yok; `step_executor.rb` 40 `@loop.` erişimi |

Bu beşi "ertelenmiş iyi fikir" olmaktan çıkıp ya **olgunlaşmış borç** (D-4: tetik aşıldı) ya da
**net kazanç** (D-2, D-3, D-5) hâline geldi.

---

## 📋 Uygulama Adımları

### D-1: `BaseProvider#complete` — Artımlı Chunk Akışı

**Dosya:** `lib/rubik/llm/provider.rb`  
**Risk:** MEDIUM — `complete`'in dönüş sözleşmesi korunmalı; tüm provider'lar aynı yolu kullanır.

**Mevcut (satır ~100):**
```ruby
def complete(messages, opts = {})
  chunks = []
  result = stream_chat(messages, opts) do |chunk|
    chunks << chunk
  end
  result.each { |chunk| chunks << chunk } if result.is_a?(Enumerator) && chunks.empty?
  build_response(chunks)
end
```

**Dönüşü bozmadan bellek profili iyileştirme:** `complete` hem `stream_chat` block'undan hem
(stream-only provider'larda) `Enumerator` dönüşünden chunk toplar; `ChunkAssembler.build` **üç
geçişte** tüm chunk'lara ihtiyaç duyar (text, tool_use_delta olay sırası, finish/usage). Bu
yüzden **tam artımlı tek-geçişli montaj, `ChunkAssembler.build`'in sözleşmesini değiştirir.**

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

**Dosya:** `lib/rubik/platform.rb` (378 satır)  
**Risk:** LOW–MEDIUM — saf taşıma; davranış korunmalı (tüm çağrı noktaları `Rubik::Platform::*`).

**Tetik aşıldı:** Plan 54 B-6'nın >300 satır koşulu gerçekleşti (378). Şimdi alan-öbekli bölme:

**Öneri (Plan 54 D-3 örüntüsü):**
- `Rubik::Platform::Path` — yol normalizasyonu, glob güvenliği
- `Rubik::Platform::Process` — süreç/ortam yönetimi (yeni sorumluluk ailesi)
- `Rubik::Platform::FileSystem` — dosya işlemleri, izinler
- `Rubik::Platform` — ortak sabitler + `extend`/delegasyon (çağrı noktaları kırılmasın)

**Kabul:** `Rubik::Platform::*` alt sabitleri mevcut çağrı noktalarını korur; `platform_spec.rb`
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

**Not:** Bu, Plan 72'de "fayda/maliyet düşük" denmişti; ancak D-4 (platform bölme) ile birlikte
yüzey genişlediği için artık değerli. Dar kapsamda tutulur — yalnızca erişim listeleme, davranış
değişikliği yok.

**Kabul:** Üç tüketici `@loop.` erişimini bırakır; testler `ShellDeps` üzerinden stub'lanır;
`loop.rb`'nin dış yüzeyi daralır.

---

## 🧪 Kırmızı Çizgiler (Bozulmamalı)

| Kural | Kontrol Noktası |
|:---|:---|
| `complete` dönüş sözleşmesi değişmez | D-1 sonrası tüm stream/complete testleri birebir |
| `Rubik::Platform::*` alt sabitleri mevcut çağrı noktalarını korur | D-4 sonrası `rake test` + `rubocop` |
| Eklenti DSL geriye uyumlu | D-3 sonrası `requires: []` mevcut eklentileri bozmaz |
| `@loop.` erişimi yalnızca `ShellDeps` üzerinden | D-5 sonrası üç tüketicide grep temiz |
| `rake test` %100 yeşil, `rubocop` 0 offense | Tüm D'ler sonrası |

---

## 🔄 Uygulama Sırası

```
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
| `lib/rubik/platform.rb` → `platform/{path,process,filesystem}.rb` | D-4: bölme |
| `lib/rubik/orchestrator/{step_executor,stream_manager,budget_manager,loop}.rb` | D-5: `ShellDeps` façade |
