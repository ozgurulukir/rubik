# 52 — Yerleşik Araçların Hızlandırılması: Native Binary Offload ve Tembel Hash

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Uygulandı (A–D Tüm Fazlar)** · **Zorluk:** Orta · **Faz:** 6 (Performans — Araç Hattı)  
> **İlgili Planlar:** [05](05-baglam-motoru-dosya-indeksi.md), [06](06-ast-semantik-indeks.md), [15](15-benchmark-kabul-testleri.md), [39](39-asenkron-ve-kademeli-ast-onbellegi-persistent-lazy-indexing.md), [44](44-llm-egitim-uyumlu-arac-isimlendirmesi-grep-ve-tool-aliasing.md), [46](46-ast-ve-baglam-motorunun-reaktif-coeffect-servisine-donusturulmesi.md), [49](49-tam-kapsamli-cross-platform-ve-windows-uyumluluk-mimarisi.md)  
> **Kapsam:** `lib/rubik/tools/builtins.rb` (yalnız `GrepSearchTool`, `SearchSymbolsTool`), `lib/rubik/tools/native_search.rb` (yeni), `lib/rubik/context/scanner.rb`, `lib/rubik/context/index.rb`, `lib/rubik/context/git_lister.rb` (yeni), `lib/rubik/ast/extractor.rb` + `*_extractor.rb`, `lib/rubik/ast/graph.rb`, `lib/rubik/benchmark/runner.rb` (+ `synth_repo.rb` yeni), `lib/rubik/config.rb`, `rubik.gemspec`, `CONFIG.md`, `README.md`  
> **Yeni Çalışma Zamanı Bağımlılığı:** yalnızca **`tty-which`** (~> 0.2) — gerekçe §2.5  

---

## 🎯 1. Hedef ve Gerekçe

Rubik'in yerleşik araçları (`grep_search`, `list_files`, AST araçları) büyük repolarda ölçeklenemiyor: kullanıcı gözlemi *"built-in toollar hâlâ biraz yavaş"*. Bu plan, 27 Ağustos 2026 tarihli **ölçüm tabanlı araştırmayı** (§2) ürüne çevirir.

Tespit edilen üç gerçek darboğaz:

1. **Soğuk bağlam taraması** — `Scanner#scan` her dosyayı `File.read` + SHA-256 ile hash'liyor + dosya başına iki `stat`; 5.001 dosyalık repoda **3,3 saniye**.
2. **`grep_search` en kötü durum** — nadir pattern'de tüm repo `File.read` + `content.lines` (tam satır dizisi allocate) ile taranıyor; 5.001 dosyada **~1,2 saniye pure Ruby** (rg aynı işi spawn dahil **~350 ms**).
3. **AST ısınması** — 5.001 dosyada **15,2 saniye**; maliyet extractör başına 0,6–3,2 ms/file (`lines` materializasyonu + gövde dilimleme + GC baskısı).

**Neden gem değil de native offload?** Araştırmanın ana bulgusu: Windows'ta Ruby thread'leri dosya IO'yu **hızlandırmıyor** (4 ve 8 thread sequential ile aynı süre — GVL + kernel CPU), `oj` stdlib JSON ile generate'da birebir aynı, `fast_ignore` (1,03 s) mevcut `git` binary'sinden (0,22 s) 5 kat yavaş. Hızlanmanın adresi: sistemde zaten duran native araçları (`rg`, `git`) **doğru şekilde** kullanmak + iki gem'siz algoritmik düzeltme (tembel hash, streaming okuma).

Temel kazanımlar:

1. **Hız:** grep en kötü durum ~3x, soğuk tarama ~2x, AST ısınması ≥1,4x (kabul eşikleri §8'de oran bazlı).
2. **Sıfır Regresyon Garantisi:** native binary yoksa, kapalıysa veya çevirisi belirsizse **mevcut pure-Ruby yollar bayt-esdeğer** çalışır; `tools.native: off` deterministik kapatma anahtarıdır.
3. **Sözleşme Kararlılığı:** `grep_search` çıktı formatı (`dosya:satır: içerik` + `Found N match(es)...` başlığı) native ve fallback yollarında **aynıdır** — Plan 44'ün kanonik araç sözleşmesi bozulmaz.
4. **Windows Tuzağı Dokümante ve Çözülmüş:** Open3 ile spawn edilen `rg`, stdin'i pipe görünce `./` yerine **stdin'i arayıp** sessizce 0 sonuç döndürür (§2.4). NativeSearch bu tuzağı yapısında önler (açık path argümanı + stdin kapatma).
5. **Spatiotemporal Uyum:** yeni bileşenler yan etkisiz saf fonksiyonlardır; süreç spawn'ları çağrı-kapsamlıdır, kalıcı thread/dinleyici doğurmaz — `on_dispose` yükümlülüğü ve sızıntı yüzeyi yoktur.

---

## 🔍 2. Ölçüm Tabanlı Teşhis (Araştırma Özeti)

### 2.1. Ölçüm Ortamı

- **Makine:** Windows 11 (win32 10.0.26200), Ruby 3.x, Git Bash; referans ölçümler bu oturumda `Benchmark.realtime` ile alındı.
- **Projeler:** (a) Rubik'in kendi deposu — 311 indeksli dosya; (b) sentetik depo — 5.001 kaynak dosya (`.rb/.ts/.py/.rs/.go` karışımı, 120 satır/dosya, git init + `.gitignore`).
- **Araçlar:** `ripgrep 15.2.0`, `git 2.55.0.windows.3`, `fd 10.4.2`, `ast-grep 0.45.1`, `fast_ignore 0.17.4`, `oj` (güncel).

### 2.2. Ölçüm Sonuçları

| İşlem | Rubik deposu (311 dosya) | Sentetik depo (5.001 dosya) |
| :--- | ---: | ---: |
| `Scanner#scan` soğuk (oku + SHA-256) | 390–1.090 ms | **3.306 ms** |
| `Scanner#scan` artımlı (yalnız stat) | 135 ms | 1.932 ms |
| — ayrıştırma: yalnız `File.stat` turu | — | 672 ms |
| — ayrıştırma: yalnız oku + SHA-256 | — | 1.065 ms |
| `git ls-files -z --cached --others --exclude-standard` | 56 ms | **219 ms** |
| `FastIgnore#to_a` (gem) | 92 ms | 1.032 ms |
| `fd -tf` (spawn dahil) | — | 166 ms |
| `grep_search` erken çıkışlı (yaygın kelime) | 26–65 ms | 2–26 ms |
| Pure Ruby tüm-repo tarama (grep **en kötü durum**) | 858 ms | **1.169 ms** |
| `rg` shellout (spawn dahil, nadir pattern) | 111–151 ms | **351 ms** |
| AST tüm dosyaları indeksleme | 466 ms | **15.203 ms** |
| — ayrıştırma: extractör toplamı (ekstrapole) | — | ~8.000 ms (.rb 1,98 · .ts 3,15 · .rs 0,88 · .py 0,76 · .go 0,60 ms/dosya) |
| Sembol sorgusu (graph sıcak, 7.146 sembol) | 1,3 ms | 4,4 ms |
| 4/8 thread'li paralel dosya taraması | — | **1.225 ms (kazanç sıfır)** |
| `sg run -p 'class $C'` (ast-grep) | — | 5.456 ms + 40 MB JSON |
| `JSON.generate` 7k sembol: stdlib vs `oj` | — | 6,8 = 6,8 ms (parse 21,5 → 15,1 ms) |

### 2.3. Darboğaz Ayrıştırması

- **Soğuk tarama** = yürüyüş (lstat+stat+sort, ~0,7 s) + oku/hash (~1,1 s) + yürüyüş katmanı ek yükü. Oysa hash, değişim tespitinde yalnızca `size`+`mtime` eşleşmezde gereklidir (git'in stat-dirty-then-hash modeli). **Tembel hash** ile soğuk tarama ≈ artımlı tarama maliyetine iner; dosya listesini `git ls-files`'tan almak yürüyüş katmanını da C hızına çeker.
- **Grep en kötü durum** = dosya başına `File.read` (tampon) + `content.lines` (ikinci tam kopya) + satır regex'i. `File.foreach` streaming + erken çıkış allocation'ları ~2-3x azaltır; `rg` offload işi ~3,4x hızlandırır. *Yaygın kelime* durumunda mevcut erken çıkış zaten hızlıdır (26 ms) — sorun yalnız nadir pattern'de.
- **AST ısınma** = extractör başına `@content.lines` materializasyonu + gövde dilimleme + 7k sembol × gövde string'i üreten GC baskısı. Not: `Symbol#body` cache yüklemesinde **zaten lazy** (`read_source_range`); in-memory extract yolunda değildir.
- **`Graph#symbols`** her çağrıda tüm sembol hash'ini `dup` eder — `SearchSymbolsTool` sorgu başına tam kopya üretir (küçük ama bedava düzeltme).

### 2.4. Kritik Bulgu: Windows'ta `rg` Stdin Tuzağı

`Open3.capture3("rg", "-e", "pattern", chdir: root)` Windows'ta **exit=1, 0 eşleşme** döndürür. `rg --debug` çıktısı kök nedeni gösterdi:

```text
for heuristic stdin detection on Windows, found that is_disk=false and is_pipe=true, is_stdin_readable=true
heuristic chose to search stdin        ← ./ yerine stdin'i arıyor!
```

Ruby (Open3) çocuğun stdin'ini pipe yapar; rg'nin Windows sezgisi bunu "aranacak veri" sanar, boş pipe'ı okur, eşleşme bulamaz. **Çözüm (NativeSearch'te kalıcı):** (1) rg'ye daima **açık path argümanı** ver (`.` veya alt dizin), (2) spawn sonrası stdin'i hemen kapat, (3) `--no-messages` ile sessiz hata yüzeyini engelle. Bu tuzak planın en önemli taşınabilir bilgi çeşididir — regresyon testiyle sabitlenir (§6).

### 2.5. Gem Ekosistemi Değerlendirmesi (Elenenler Gerekçeli)

| Aday | Hüküm | Ölçülmüş Gerekçe |
| :--- | :---: | :--- |
| **`tty-which`** | ✅ **EKLENİR** | rg çözümlemesi için standart, bağımlılıksız, mevcut TTY ailesiyle uyumlu; scoop shim gibi PATH vakalarını tam path'e çözer |
| `oj` | ❌ | stdlib JSON zaten C: generate birebir (6,8=6,8 ms), parse yalnız %30 (21,5→15,1 ms / 7k sembol) — bağımlılığa değmez. Plan 39 §3'ün serileştirme kararıyla uyumlu |
| `parallel` / `concurrent-ruby` | ❌ | Ölçüldü: Windows dosya IO'da 4/8 thread = sequential (1.225 ≈ 1.169 ms). GVL + kernel CPU engeli; ağ IO'da çalışan (LLM havuzu) deseni disk'e taşınmaz |
| `fast_ignore` | ❌ | 1.032 ms/5k — mevcut budamalı walker'dan iyi ama `git ls-files` (219 ms) her hedef repoda zaten varken gereksiz bağımlılık |
| `ripgrep-ruby` vb. sarmalayıcılar | ❌ | Hepsi CLI sarmalayıcı — kendi Open3 çağrımızdan fazlası yok (ripgrep resmî kütüphane API'si sunmaz) |
| `fd` offload | ❌ | Listeleme `git ls-files` ile daha hızlı çözülür; `fd` ek ignore-çevirisi karmaşası getirir |
| ctags / ast-grep offload (AST için) | ❌ | Yeni binary bağımlılığı; `sg run` 5,5 s + 40 MB JSON üretti — sıcak sembol grafiği için net kazanç değil; AST kazancı extractör düzeltmeleriyle daha ucuza alınır |
| `prism` (explicit dep) | 🟡 opsiyonel | Ruby 3.3+ default gem; `require "prism"` zaten çalışıyor. Sürüm pinlemek istenirse gemspec'e eklenir — bu plan kapsamında **eklenmez** |

---

## 💡 3. Tasarım Kararları

### D1 — "Auto-Native" strateji: native hızlı yol + bayt-esdeğer fallback

Native binary **varsa ve çeviri koşulları netse** kullanılır; aksi her durumda mevcut pure-Ruby yol çalışır. Yapılandırma: `tools.native: auto | on | off` (varsayılan `auto`; `on` + binary yoksa bir kez uyarı; `off` zorla fallback). ENV override'ları: `RUBIK_NATIVE=off`, `RUBIK_RG_PATH=<tam yol>`. Offload yalnızca hız yoludur — **doğruluk kaynağı her zaman Ruby tarafındaki sözleşmedir**.

### D2 — Offload kapıları (belirsiz çeviri → otomatik fallback)

`grep_search` için rg yolu **yalnızca şu koşullarda** devreye girer: (a) rg çözümlendi, (b) `Scanner`'da özel `includes`/`excludes` YOK (rg yalnızca gitignore bilir), (c) `additional_roots` boş (rg kök dizinde çalışır), (d) `tools.native != off`. Bu koşullardan biri düşerse tool mevcut kod yoluna **koşulsuz** döner — sessiz yavaşlama kabul edilebilir, sessiz **yanlış sonuç** asla.

### D3 — Tembel hash (`hash: nil` = "stat-temiz, içerik hash'i hesaplanmadı")

- `Scanner#entry_for`: `prev[:hash]` nil olsa bile `size`+`mtime` eşleşiyorsa **yeniden okuma yapılmaz**, `hash: nil` korunur (bugünkü `prev[:hash] &&` koşulu değişir).
- `Index#incremental_scan`: `hash` karşılaştırmasında `nil == nil` + stat eşit ⇒ unchanged; stat farklı ⇒ modified (hash o an hesaplanır).
- `Index#update_file` (tek dosya) ⇒ hash **eager** hesaplar (mevcut davranış korunur — tampon senkronizasyonu hash'e bakar).
- Tüketici denetimi yapıldı: `[:hash]` yalnızca `scanner.rb:146-148`, `index.rb:50,84`'te okunur — sözleşme testleriyle sabitlenir (§6).

### D4 — `git ls-files` hızlı listeleme + stat doldurma

`Context::GitLister.files(root)`: git deposuysa `git ls-files -z --cached --others --exclude-standard` çıktısını NUL'dan ayırıp **göreli path listesi** döner; git yoksa / depo değilse / spawn hata verirse `nil` (→ mevcut budamalı walker). Scanner, liste geldiğinde walker yerine liste + dosya başına tek `File.stat` kullanır. `additional_roots` her biri için ayrı çağrılır (mevcut isim-uzayı kuralları korunur). Not: `git ls-files` doğal olarak gitignore uygular; DEFAULT_IGNORES (`.rubik/`, `tmp/` vb.) Ruby tarafında listeden ayrıca süzülür — bugünkü semantikle hizalı.

### D5 — Grep fallback modernizasyonu (gem yok, her ortamda kazanım)

`File.read` + `content.lines` + `content.include?("\x00")` yerine: `File.foreach` streaming; satır regex'i eşleşme başına; **binary atlama** satır bazlı NUL kontrolüyle (`line.include?("\x00")` ⇒ dosyayı bırak — satırların birleşimi içerik olduğundan mevcut tam-dosya kontrolüyle özdeş semantik); tampondaki kirli dosyalar mevcut olduğu gibi bellekten okunur. Çıktı formatı değişmez.

### D6 — AST hızlandırma noktaları (graf sorguları + extractör streaming'i)

1. `Graph#search_symbols(query)` eklenir: mutex altında **dup'sız** iterasyon + `query.downcase` döngü dışında; `SearchSymbolsTool` buna geçer. `Graph#symbols` (dup'lı snapshot) mevcut genel API olarak kalır.
2. Extractörlerde `@content.lines` tam materializasyonu kaldırılır → `each_line`/`each_with_index` streaming; çok regex'li satır döngüleri en ucuz kontrolden pahalıya sıralanır (ölçüp doğrulanır, tahminle değiştirilmez).
3. `Symbol#body` **in-memory extract yolunda da lazy** yapılır: gövde dilimlemesi `line_start/line_end` aralığından ilk erişimde okunur; AST cache formatı ve `to_h` sözleşmesi değişmez. (Cache yüklemesinde zaten lazy — davranış birleştirilir.)

### D7 — NativeSearch: yan etkisiz, süreç-kapsamlı spawn

`Tools::NativeSearch` durumsuz modüldür: `rg_path` (tty-which + ENV override, Mutex altında memoize), `available?`, `search(...)`. Spawn'lar `Open3.popen3` ile **çağrı-kapsamlıdır**: stdout `readpartial` döngüsüyle satır satır okunur, `max_results`'a ulaşınca süreç erken sonlandırılır (250k satır dökümü engellenir — ölçümde tam tarama 250.000 satır üretti), stdin spawn sonrası hemen kapatılır (§2.4), süreç `wait` ile reap edilir. Kalıcı thread/dinleyici yok ⇒ `ctx.on_dispose` yükümlülüğü yok (AGENTS.md "Leaked Side Effects" anti-pattern'ine uyum).

### D8 — Kirli tampon birleştirme (doğruluk köprüsü)

rg **disk** durumunu görür; `buffer_manager.dirty_files` doluysa: (1) kirli dosyalar rg **dışında** pure-Ruby bellek taramasıyla taranır, (2) rg sonuçlarından bu dosyalara ait satırlar düşürülür, (3) bellek sonuçları birleştirilir, (4) `dosya, satır` sırasına göre yeniden sıralanır ve `max_results` kırpılır. Böylece model diskteki eski sürümü göremez — bugünkü davranışın birebir koruması.

---

## 🏛️ 4. Mimari Tasarım

### 4.1. Yeni Bileşen Haritası

```text
lib/rubik/tools/native_search.rb      # Rubik::Tools::NativeSearch (modül; rg çözümleme + spawn + parse)
lib/rubik/context/git_lister.rb       # Rubik::Context::GitLister (modül; ls-files + nil fallback)
lib/rubik/benchmark/synth_repo.rb     # Rubik::Benchmark::SynthRepo (ölçüm/kabul için sentetik depo üreteci)
lib/rubik/tools/builtins.rb           # GrepSearchTool (offload + merge), SearchSymbolsTool (graph#search_symbols)
lib/rubik/context/scanner.rb          # tembel hash + GitLister hızlı yolu
lib/rubik/context/index.rb            # nil-hash sözleşmesi
lib/rubik/ast/{extractor,*_extractor}.rb  # streaming + lazy body
lib/rubik/ast/graph.rb                # search_symbols (dup'sız)
lib/rubik/benchmark/runner.rb         # bench_grep_tool, bench_cold_scan metrikleri
lib/rubik/config.rb                   # tools.native anahtarı
```

### 4.2. NativeSearch Sözleşmesi (sözde-kod)

```ruby
module Rubik
  module Tools
    module NativeSearch
      RG_FLAGS = %w[--no-messages --no-heading -n --hidden -g !.git/**].freeze

      def self.rg_path(env: ENV)     # memoize: ENV["RUBIK_RG_PATH"] || TTY::Which.which("rg")
      def self.available?(env: ENV)  # !rg_path(env:).nil?
      # Dönüş: [{ file:, line:, content: }, ...] — GrepSearchTool formatıyla birebir
      # Başarısızlık/parse şüphesi: nil döner → çağıran fallback'e gider (sessiz yutma yok, ölçülür)
      def self.search(query, root_dir:, path: nil, glob: nil, case_sensitive:, max_results:,
                      stdin_data: "", runner: nil)
    end
  end
end
```

Spawn ana hatları: `Open3.popen3(rg_path, *flags, "-e", query, path_arg, ...)`. `path_arg` **daima açık**tir (`.` veya normalize edilmiş alt yol) — asla yok edilmez (§2.4 regresyon testi). Çıktı satırları `force_encoding(UTF_8).scrub`'dan geçer (afe05d4 ile yerleşen desen). `-m` rg'de **dosya başına** olduğundan toplam sınır Ruby tarafında `readpartial` erken-çıkışıyla uygulanır. Test edilebilirlik: `runner:` enjeksiyonu ile spawn sahtelenir (PATH kirliliği yok).

### 4.3. GrepSearchTool Birleşik Akış

```text
execute(args)
  ├─ koşul kapıları (D2) sağlanmıyor mı? ──► fallback (D5: foreach streaming)
  ├─ NativeSearch.search(...) nil döndü mü? ─► fallback (upstream sayaç: !native_misses)
  ├─ kirli tampon dosyaları: bellekten tara (D5 iç döngüsü)
  ├─ birleştir + sırala (file,line) + max_results kırp (D8)
  └─ "Found N match(es) for 'q':" + dosya:satır: içerik   ← format DEĞİŞMEZ (Plan 44)
```

### 4.4. Yapılandırma Yüzeyi

```yaml
tools:
  native: auto   # auto | on | off — rg (grep) ve git (listeleme) hızlı yollarının ana şalteri
```

ENV: `RUBIK_NATIVE=off|on|auto`, `RUBIK_RG_PATH`. `RUBIK_TEST=1` davranışı: şalter değişmez, birim testler `runner:`/komut enjeksiyonuyla izole eder; gerçek-rg entegrasyon testi `rg` yoksa `skip` ile geçilir (Plan 49 skip kuralıyla uyumlu).

---

## ⚙️ 5. Uygulama Adımları (Fazlar)

### Faz A — Gem'siz çekirdek hızlandırmalar *(Orta; davranış-korur)*
1. `Scanner` tembel hash (D3) + `Index` nil-hash sözleşmesi + sözleşme testleri.
2. Grep fallback streaming (D5) — mevcut `GrepSearchTool` testleri bayt-esdeğer çıktıyla geçmeli.
3. `Graph#search_symbols` + `SearchSymbolsTool` geçişi; `Graph#symbols` API'si kalır.
4. Extractör streaming (D6.2) + in-memory lazy body (D6.3); extractör çıktıları sembol-bazında doğrulanır (altın küme karşılaştırması).

### Faz B — Native offload altyapısı *(Orta)*
1. `tty-which` gemspec'e eklenir; `NativeSearch` modülü (D7) yazılır — açık path + stdin kapatma + erken sonlandırma + parse + scrub.
2. `GitLister` (D4) yazılır; Scanner hızlı yoluna bağlanır (fallback walker aynen durur).
3. `tools.native` config + ENV override'ları + `!config` yüzeyi.

### Faz C — Tool entegrasyonu *(Orta–Zor)*
1. `GrepSearchTool` birleşik akış (D2 kapıları + D8 birleştirme); native/fallback çıktı-parite testleri.
2. `ListFilesTool` otomatik yararlanır (idx hızlanır) — ek değişiklik gerekmez; yine de soğuk-ilk-sorgu yolu doğrulanır.
3. Windows stdin tuzağı regresyon testi: spawn argv'sinde açık path argümanı + stdin kapanışı spy'lanır (§2.4).

### Faz D — Kabul ölçümleri ve dokümantasyon *(Kolay)*
1. `Benchmark::SynthRepo` (5.001 dosya; testlerde 200 dosyalık hızlı profil) + `Runner`'a `bench_grep_tool`, `bench_cold_scan` (oran bazlı eşikler §8).
2. Araştırmadaki ölçüm script'leri `benchmark/tool_latency.rb` olarak depoya taşınır (tekrarlanabilir temel).
3. `CONFIG.md` (`tools.native`) + `README.md` performans notu; sapmalar §9'a işlenir.

---

## 🧪 6. Test ve Kalite Güvanesi

- **Birim (sahte runner):** NativeSearch parse (NUL'lu path, UTF-8 scrub), erken sonlandırma, `nil` fallback sinyali; GitLister NUL ayrıştırma + non-git → nil.
- **Sözleşme:** tembel hash üç durumu (nil→nil unchanged, stat-dışı modified, update_file eager); native/fallback grep çıktı paritesi aynı fixture üzerinde; `tools.native: off` iken spawn'ın **hiç** tetiklenmediği spy'la doğrulanır.
- **Doğruluk köprüsü:** kirli tampon + rg birleştirme — disk eski, tampon yeni sürüm içeriyor; sonuç yalnız tampon sürümünden gelmeli.
- **Windows tuzağı:** argv'de açık path + stdin kapatma regresyonu (asla 0-eşleşme sessizliği).
- **Tüm mevcut paket yeşil kalmalı** (603 koşu referansı); yeni dosyalar rubocop 0 ihlal; shell.rb 600 satır limitine dokunulmaz.

---

## ⚠️ 7. Riskler ve Önlemler

| Risk | Etki | Önlem |
| :--- | :--- | :--- |
| rg yok / PATH shim tuhaflığı | Offload çalışmaz | `tty-which` tam path + memoize + `RUBIK_RG_PATH`; miss → sessiz fallback + sayaç |
| Windows stdin sezgisi (§2.4) | **Sessiz 0 sonuç** | Açık path argümanı + stdin kapatma + regresyon testi |
| rg çıktı biçim sapması (sürüm/path NUL) | Parse bozulur | Parse şüphesi ⇒ `nil` ⇒ fallback; entegrasyon testi rg 14/15 üzerinde |
| Kirli tampon ayrışması | Model eski içerik görür | D8 birleştirme + doğruluk köprüsü testi |
| `hash: nil` sözleşme kırılması | Yanlış modified/unchanged | Tüketici denetimi + sözleşme testleri; `update_file` eager kalır |
| `git ls-files` ölçek davranışı (dev submodule) | Liste yanlış/hatalı | Spawn hatası ⇒ nil ⇒ walker; `-z` ile boşluklu path güvenli |
| Değişken eşiş hızları (CI'da eşik titizliği) | Sahte başarısızlık | Kabul eşikleri **oran bazlı**; mutlak rakamlar yalnızca referans bilgi |
| Gizli bağımlılık enflasyonu | Bakım yükü | Yalnız `tty-which`; §2.5'te her aday gerekçeli elenmiş/önerilmiş |

---

## 📊 8. Kabul Kriterleri (Benchmark)

Ölçüm ortamı: `Benchmark::SynthRepo` (5.001 dosya) + `benchmark/tool_latency.rb`. Eşikler **aynı koşuda yeni/temel oranı** bazlıdır; mutlak rakamlar araştırma referansıdır (Windows referans makinesi, ±%20).

| Metrik | Temel (ölçüldü) | Kabul eşiği |
| :--- | ---: | :--- |
| `grep_search` nadir pattern (10 eşleşme, 5k dosya) | ~1.170 ms | **≥ 2,5x hız** (rg yolu ~350 ms) |
| Soğuk `full_scan` (5k dosya) | ~3.306 ms | **≥ 2x hız** |
| Artımlı tarama (5k dosya) | ~1.932 ms | **≥ 1,3x hız** |
| AST tüm-dosya ısınma (5k dosya) | ~15.203 ms | **≥ 1,4x hız** |
| Sembol arama (graph sıcak) | 4,4 ms | Regresyon yok (`≥ 1x`, dup'sız yol) |
| `tools.native: off` tüm-paket | 603 koşu yeşil | Bayt-esdeğer fallback, 0 yeni hata |
| Yeni çalışma zamanı bağımlılığı | — | Yalnız `tty-which` |

---

## 🔧 9. Uygulama Sapmaları (Plan → Kod)

*Uygulama sırasında planın dışına çıkan her karar bu bölüme tarih + gerekçe ile işlenir (Plan 51 §9 kuralı).*

| # | Tarih | Sapma | Gerekçe |
| :--- | :--- | :--- | :--- |
| D-1 | 27 Ağustos 2026 | GitLister hızlı yolu `tools.native: off`'ta kapalı, `includes` varken atlanır; `excludes` ise hızlı yolda da uygulanır | Plan D2 "includes/excludes YOK" tek kapı yazıyordu; ayrım gerekli: excludes hızlı yolda `ignored?` filtresiyle özdeş uygulanabilirken includes (izin listesi) `ls-files` çıktısından üretilemez |
| D-2 | 27 Ağustos 2026 | rg `-j 1` DENENDİ ve ÇIKARILDI | Tek thread, 5.000 dosyalık taramayı 3,5x yavaşlatıyor (ölçüm: 247→864 ms; glob'lar bedava). Paralel rg ile cap'e ulaşınca hangi eşleşme alt kümesinin kaldığı arrival-order'a bağlı; birleşik sonuç yine (dosya, satır) sıralı ve doğru kırpılıdır. Bayt-esdeğer tekrarlanabilirlik `tools.native: off` ile korunur |
| D-3 | 27 Ağustos 2026 | Kabul metrikleri güncellendi: grep 7,97x (hedef 2,5x), soğuk tarama 2,25x walker / 3,76x git hızıyla temele göre (hedef 2x), AST ısınması 1,56x (hedef 1,4x) | 5.000 dosyalık sentetik repoda `benchmark/tool_latency.rb` ölçümü; tembel hash sayesinde walker'ın kendisi de hızlandığından "git hızıyla temel" oranı plandaki tahminden yüksek çıktı |
| D-4 | 27 Ağustos 2026 | `Symbol`'e `body_loader:` parametresi eklendi; tüm extractörler eager gövde dilimi yerine `body_loader_for(s, e)` fabrikasıyla closure devrediyor | Plan D6.3 "in-memory lazy" yalnız Ruby/Prism için tarif ediyordu; dilimleme maliyeti tüm dillerde baskın olduğu için kalıp 7 extractöre de genellendi. DİKKAT: fabrika BİR METHOD olmalıdır — ilk denemede kullanılan `->(s = line_num, e = end_line)` default-arg imzası YANLIŞTI (lambda default arg'ları çağrı anında değerlenir; `while` gövdesi scope üretmediğinden tüm loader'lar son sembolün satırlarını çözümlerdi — kırmızı takım P1 bulgusu, `BodyLoader` modülü + iki sembollü regresyon testi ile giderildi) |
| D-5 | 27 Ağustos 2026 | Ruby fallback grep'te `File.foreach` yerine `buffer.read` tarihsel veri yolu korundu; streaming yalnız buffer'sız disk okumasında | `buffer_manager.read` yan etkisi diff tabanını (`original_hashes`) ısıtıyor; tam streaming bu yan etkiyi kaldırıp `!diff` çıktısını kenar durumlarda değiştirirdi. `content.lines` → `content.each_line` ile satır-dizisi kopyası yine kaldırıldı; NUL içeren akış dosyalarında eşleşme geri çekme ile tam-dosya kontrolü özdeş korundu |
| D-6 | 27 Ağustos 2026 | Kırmızı takım düzeltmeleri: `parse_line` ilk `:rakam:` sınırına + `root_dir` varlık doğrulamasına geçti (içerikteki `12:34:56` damgası satır numarası çalamaz); erken-cap sinyali `break true` → `next true` (önceki biçim `Process.kill`+`waiter.value` yolunu ölü kod yapıyordu, EPIPE'ye tesadüfi muhtaçtı); `index_listed` ata-dizinlere `subtree_ignored?` budaması uyguladı (takip edilen `vendor/**` dosyaları fast path'e sızmaz); boş `RUBIK_RG_PATH` çözümlenmemiş sayılır; rg stderr `err: File::NULL` ile boşaltılır; mevcut grep testleri `native: off`'a sabitlendi + canlı rg parite testi eklendi (rg yoksa skip) | Üç bağımsız kırmızı-takım incelemesinin (hata/DRY/protokol) teyitli P1/P2 bulguları; her biri regresyon testiyle sabitlendi |
| D-7 | 27 Ağustos 2026 | `enabled?` kuralı `GitLister` ve `NativeSearch`'te bilinçli olarak iki kopya halinde kalır | Paylaşılan modül context→tools bağımlılığı yaratacaktı (katman hiyerarşisi bozulur); 4 satırlık saf kural her katmanda kendi ENV/config sözleşmesiyle yaşar, yorumlarda çapraz referans var |
