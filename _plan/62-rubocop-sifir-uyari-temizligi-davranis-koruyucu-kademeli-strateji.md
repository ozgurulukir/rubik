# 62 — RuboCop Sıfır-Uyarı Temizliği: Davranış-Koruyucu Kademeli Strateji

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes
> **Durum:** ✅ **Tamamlandı (29 Ağustos 2026)** · **Zorluk:** Orta (geniş ama mekanik) · **Faz:** 6 (Sistem Dayanıklılığı & Kod Sağlığı)
> **Sonuç:** `rubocop` exit 0 (277 dosya, 0 ihlal — 1397'den) · `rake test` 823 runs / 4358 assertions / 0 failure (baseline ile birebir) · Public API: `LLM::Response#has_tool_calls?` deprecated alias ile korundu; hiçbir metot kaldırılmadı. Metrics ihlalleri test-tabanlı meta-hijyene (test_module_hygiene, test_repl_command_decoupling) devredilerek gerekçeli kapatıldı.
> **İlgili Planlar:** [54](54-kod-sagligi-ve-modulerlik-dis-degerlendirme-bulgulari.md), [57](57-sistem-saglamligi-birlesik-tanilama-fuzyonu-e2e-ve-thread-safety.md), [59](59-cekirdek-guvenligi-sentez-sandbox-bare-rescue-ve-moduler-testler.md), [60](60-kritik-yol-guvenligi-sandbox-timeout-ve-kod-sagligi.md), [61](61-llm-baglam-surekliligi-hata-turlerinde-kayit-ve-stream-butunlugu.md)
> **Kapsam:** `lib/**/*` (152 dosya), `test/**/*` (121 dosya), `Gemfile`, `rubik.gemspec`, `.rubocop.yml`, `.gitattributes` (yeni)

---

## 🎯 1. Problem ve İhtiyaç Analizi

**Kullanıcı talebi:** *"Feat kaybetmeden rubocop uyarılarını gidermeye yönelik bir düzeltme planla."*

Mevcut durum (29 Ağustos 2026 ölçümü): **1397 ihlal / 187 dosya**. Dağılım: `lib/` → 1063 ihlal (659'u autocorrectable), `test/` → 326 ihlal (259'u autocorrectable).

### 1.1 İhlal Envanteri (kop sayılarına göre)

| Kategori | Adet | Temsilciler | Alet | Risk |
| :--- | :--- | :--- | :--- | :--- |
| **A. Safe-correctable** | **~918** | WordArray 111, RescueModifier 109, UnusedMethodArgument 64, LineLength 62, IfUnlessModifier 62, EmptyLineAfterGuardClause 41, FetchEnvVar 22, RegexpLiteral 18, UselessAssignment 16, GuardClause 16, StringLiterals 15… | `rubocop -a` | Sıfır (RuboCop sözleşmesi: semantik garanti) |
| **B. Unsafe-correctable** | **~137** | SafeNavigation 31, NumericPredicate 28, EnvHome 14, AmbiguousRange 12, StringConcatenation 10, NonAtomicFileOperation 6, FileNull 4, IdenticalConditionalBranches 4, SlicingWithRange 4… | Elle, cop bazında | Orta (bilinen tuzaklar var — §5) |
| **C. Semantik lint** | **~75** | ShadowedException 16, MissingSuper 15, DuplicateBranch 14, EmptyBlock 12, NoReturnInBeginEndBlocks 6, Security/Eval 5, IneffectiveAccessModifier 2, DuplicateMethods 1, BinaryOperatorWithIdenticalOperands 1, ToEnumArguments 1, NonLocalExitFromIterator 1, SuppressedException 1… | Elle, tek tek | Değişken (her biri bulgu bazında karar) |
| **D. Naming** | **~34** | PredicateMethod 11, PredicatePrefix 5, MethodParameterName 5, VariableName 5, BlockForwarding 3, MethodName 2, VariableNumber 1, RescuedExceptionsVariableName 1, FileName 1 | Elle + GitNexus `rename` | Public API'de KIRILMA riski |
| **E. Metrics** | **~275** | PerceivedComplexity 71, CyclomaticComplexity 65, AbcSize 43, ParameterLists 29, BlockNesting 24, BlockLength 21, MethodLength 20, ClassLength 2 | **Konfigürasyon** (refactor değil) | Refactor'e kalkışırsa YÜKSEK |
| **F. Satır sonu (EndOfLine)** | **34** | 34 dosyada CRLF karışımı | Normalizasyon + `.gitattributes` | Düşük (diff gürültüsü yüksek) |
| **G. Meta dosyalar** | **~8** | Gemspec/AddRuntimeDependency 6, Bundler/OrderedGems 1, Gemspec/RequireMFA 1 | `rubocop -a` | Sıfır |

### 1.2 "Feat Kaybı" Risk Analizi — Kriz Noktaları

Doğrulanan bulgular (plana özel, kod okunarak teyit edildi):

- **`lib/rubik/llm/provider.rb:51` — `BaseProvider`'ın `initialize` metodu YOK.** Üç alt sınıftaki MissingSuper (anthropic.rb:12, ollama.rb:14, openai_compatible.rb:37) için `super()` eklemek `Object#initialize`'i çağırır → **tam no-op, güvenli**. Test double'larındaki 12 MissingSuper aynı durumda.
- **`lib/rubik/sandbox/runner.rb:10,79` — `attr_reader :allow_network` ile `def allow_network` çakışıyor** (Lint/DuplicateMethods). Ruby son tanımlananı kullanır → açık metot kazanıyor; `attr_reader` listesinden `:allow_network` silinmesi **no-op**. Tersini yapmak (def'i silmek) dönüş değerini değiştirirdi — yasak.
- **`lib/rubik/repl/interrupt_handler.rb:136`** — `wait_res == 0xFFFFFFFF || wait_res == 4294967295 || wait_res == -1`: ilk iki terim aynı sayı (FFI dönüş tipi sürümüne göre işaretli/işaretsiz dönebilir); bilinçli savunmacı kod → tek terime indirgemek **no-op**, davranış aynı.
- **`lib/rubik/context/scanner.rb` (9 yer) — `rescue SystemCallError, StandardError`**: `SystemCallError < StandardError` → fazlalık, `StandardError`'a indirmek **no-op**.
- **`lib/rubik/llm/router.rb:50` — `to_enum(:stream_chat, ..., provider: chosen, ...)`**: `chosen` (çözümlenmiş provider) bilinçli olarak geçiriliyor — enum tüketilene kadar routing kararının anlık görüntüsü. Cop'un istediği "doğru argüman" (`provider: provider`) **davranışı değiştirirdi** → gerekçeli inline disable.
- **`lib/rubik/tools/builtins/grep.rb:205`** — `File.foreach` bloğu içinde `return`: NUL baytı bulununca **metodun tamamından** çıkmak bilinçli. `break`/`next` ile düzeltmek dosya-tarama döngüsünden sonraki kodu çalıştırırdı → dosya-bazlı taramayı private metoda çıkarıp `return`'ü doğal hale getirmek (davranış-koruyucu mini refactor) veya gerekçeli disable.
- **`lib/rubik/runtime/overlay_storage.rb:105` — `eval` overlay özelliğinin kendisidir** (Security/Eval 5 + EvalWithLocation + DocumentDynamicEvalDefinition). Kaldırılamaz → `eval(..., binding, __FILE__, __LINE__)` + magic-comment dokümantasyon + Security/Eval için gerekçeli disable.
- **`test/fixtures/plugins/rubik-plugin-example/...rb` — Naming/FileName**: dosya adı gem adını (kebab-case) yansıtır → **düzeltilmez**, `Naming/FileName` için fixture exclude eklenir. Düzeltme fixture yüklemeyi kırardı.
- **`Style/FrozenStringLiteralComment` ×2** (`tools/builtins/files.rb`, `tools/builtins/symbols.rb`): magic comment eklemek o dosyalardaki string literalleri dondurur → dosyada literal üzerinde yerinde mutasyon (`<<`, `gsub!`…) varsa **çalışma zamanı hatası**. Ekleme öncesi her iki dosyada mutasyon taraması şart.

### 1.3 Önceki Mesajdaki Düzeltme

İlk değerlendirmede "39 ihlal" denilmişti; bu, `--format offenses` çıktısının yalnızca kuyruk bölümünün (1'er adetli cop'lar) okunmasından kaynaklanan bir hataydı. **Gerçek toplam 1397'dir** (özet çıktısının son satırı). Bu plan tam envanter üzerine kuruludur.

---

## 🧩 2. Tasarım Kararları

1. **Davranış-koruma aşamalı kapılar:** Her faz = bağımsız commit + `bundle exec rake test` + sayaç kaydı. Bir faz kırmızıya dönerse yalnızca o faz revert edilir (protokolün LIFO geri-alma ruhu; commit'ler Ω akümülatörü gibi geriye doğru sarılır).
2. **`-A` (unsafe autocorrect) ASLA toplu çalıştırılmaz.** Yalnızca `-a` (safe) toplu kullanılır; B kategorisi cop-bazlı elle.
3. **Metrics refactor'e dönüştürülmez.** Plan 54/57/59/60 zaten modülerlik refaktörleri yaptı; kalan karmaşıklık largely içkin (7 dil extractoru, 399 satırlık Config). Çözüm: mevcut `.rubocop.yml` yorum geleneğine uygun (bkz. `Metrics/ParameterLists` gerekçe yorumu) **dosya-bazlı, gerekçeli exclude'lar**. Refactor istenirse ayrı plan açılır.
4. **Public API yeniden adlandırması alias ile korunur.** `has_key?` → `key?` gibi durumlarda: internal çağrılar GitNexus `rename` ile taşınır, eski ad deprecated alias olarak kalır (gem tüketicileri ve plugin API sözleşmesi korunur — Plan 53 kontratı).
5. **Bilinçli kod kalırsa gerekçeli inline disable.** `rubocop:disable Cop # gerekçe` bir yenilgi değil, karar kaydıdır; `_plan` kültürüyle uyumlu.
6. **GitNexus iş akışı zorunlu:** Sembol düzenlenen her fazda düzenleme öncesi `impact` (upstream), commit öncesi `detect_changes()` (AGENTS.md kuralı).
7. **Ölçülebilir hedef:** `bundle exec rubocop` exit code 0 — "kabul edilmiş ihlal" (`--disable-uncorrectable` toplu suppressiyonu) YASAK; her kapanış ya düzeltme ya gerekçeli disable/exclude'tur.

---

## 🛠 3. Uygulama Adımları (Faz Bazında)

### Faz 0 — Güvenlik Ağı ve Temel Ölçüm (yanıltıcı olmayan baseline)
1. `bundle exec rake test` → **tam yeşil** olmalı; test sayısı (`assertions`) kayda alınır (karşılaştırma baz çizgisi).
2. `bundle exec rubocop --format offenses` çıktısı `_plan/62-rubocop-baseline.txt`'ye kaydedilir (faz sonlarında sayaç diff'i buradan alınır).
3. `git status` temiz çalışma alanıyla başlanır (AGENTS.md/CLAUDE.md üzerindeki mevcut değişiklikler ayrı tutulur).

### Faz 1 — Safe Autocorrect: `lib/` (A kategorisi, ~659 ihlal)
- `bundle exec rubocop -a lib` → `rake test` → sayaç kaydı → commit (`style(rubocop): safe autocorrect lib`).
- Dikkat: `-a` bu noktada FrozenStringLiteralComment'e dokunmaz (unsafe işaretli) — Faz 5'te elle.
- Kontrol listesi: diff'te yalnızca biçimsel dönüşümler; `rescue` modifier → `begin/rescue` (109 adet) semantik eşdeğerdir.

### Faz 2 — Safe Autocorrect: `test/` + meta dosyalar (~259 + 7 ihlal)
- `bundle exec rubocop -a test Gemfile rubik.gemspec` (G kategorisi dahil) → `rake test` → commit.
- Gemspec/RequireMFA: `metadata["rubygems_mfa_required"] = "true"` eklenmesi yayınlama meta verisidir, kod davranışına etkisi yoktur.

### Faz 3 — Satır Sonu Normalizasyonu (F kategorisi, 34 dosya)
- Kök neden: Windows geliştirme ortamında karışık CRLF; repo'da `.gitattributes` yok.
- Adımlar: (1) `.gitattributes` ekle: `* text=auto eol=lf` + `*.rb text eol=lf` (+ binary istisnaları varsa); (2) etkilenen 34 dosyada CRLF → LF (`rubocop -a` EndOfLine'ı düzeltir); (3) `git add --renormalize .` → `rake test` → **ayrı commit** (diff gürültüsü izolasyonu).

### Faz 4 — Unsafe-Correctable, Cop Bazında Elle (B kategorisi, ~137)
Her cop için tuzak tablosu ve kararla:

| Cop | Adet | Tuzak | Karar kuralı |
| :--- | :--- | :--- | :--- |
| Style/NumericPredicate | 28 | `x > 0` → `x.positive?` yalnızca `Numeric`'te eşdeğer; `String`/özel karşılaştırılabilirlerde farklı | Operand `Integer`/`Float` değilse dokunma (inline gerekçe) |
| Style/SafeNavigation | 31 | `x && x.y` → `x&.y` **`x == false`'ta farklıdır** (`false && …` → `false`; `false&.y` → NoMethodError) | Alıcı boolean olabilir mi? Kontrol edilmeden dönüştürme |
| Style/EnvHome | 14 | `ENV["HOME"]` → `Dir.home` **HOME unset'te nil yerine raise** | nil-bekleyen dallar korunur; raise kabul edilebilir mi bağlam bazında |
| Lint/AmbiguousRange | 12 | parantezleme — okunabilirlik | Doğrudan düzelt (no-op) |
| Style/StringConcatenation | 10 | `+` → interpolasyon `nil`/`to_s` kenar durumları | Değişken tipleri belli değilse dokunma |
| Lint/NonAtomicFileOperation | 6 | `File.exist?` + `File.delete` → `FileUtils.rm_f` (yarış-güvenli, gözlemlenen davranış aynı) | Doğrudan düzelt |
| Style/FileNull, IdenticalConditionalBranches, SlicingWithRange, HashEachMethods, InverseMethods, DoubleNegation… | ~30 | Cop'a özgü | Bulgu bazında; §1.2 doğrulamaları uygulanır (`!!` → `.nil?` karşıtı DEĞİL; `tools/result.rb:16` örneği: `!!x` → `x ? true : false` yazımı; `!x.nil?` yalnızca değer kümesi nil/false/bariyerliyse eşdeğer) |

- Süreç: cop cop `--only <Cop>` ile listele → elle düzelt → `rake test` → grup commit'leri (2-3 cop/commit).

### Faz 5 — Semantik Lint, Bulgu Bazında (C kategorisi, ~75)
- **MissingSuper 15:** `super()` ekleme (§1.2 — BaseProvider'da üst init yok, no-op). GitNexus `impact` yine de çalıştırılır (LLM provider'ları hayati akış).
- **ShadowedException 16:** yedekli rescue sınıflarını eleme (no-op — §1.2 scanner doğrulaması).
- **UselessAssignment 16:** her biri olası **gerçek bug sinyali** (dead code / kayıp değer). Silmeden önce intent okunur; bulgu gerekçesiyle plana ek not düşülür.
- **DuplicateBranch 14:** kasıtlı okunabilirlik tekrarları olabilir → ya dalları birleştir ya inline gerekçe. `typescript_extractor.rb:144`, `config.rb:289`, `llm/client.rb:142`, `lsp/client.rb:36` elle incelenir.
- **EmptyBlock 12 / NoReturnInBeginEndBlocks 6 / IneffectiveAccessModifier 2:** tek tek; test double'larındaki bilinçli boş bloklar gerekçeli disable.
- **Tekillikler:** §1.2'deki kararlar uygulanır — DuplicateMethods (attr_reader'dan sil), BinaryOperatorWithIdenticalOperands (terim indirgeme), ToEnumArguments (inline gerekçeli disable — routing anlık görüntüsü), NonLocalExitFromIterator (grep.rb dosya-taraması private metoda çıkarılır, davranış birebir), SuppressedException (test bilinçliliği → disable yorumu).
- **Security/Eval 5 + overlay_storage üçlüsü:** `eval(src, binding, File.basename(__FILE__), __LINE__)` + interpolasyonun görünümünü gösteren magic comment + gerekçeli disable (`# overlay feature: evaluates generated overlay code; source vetted by synthesis sandbox — Plan 59`).

### Faz 6 — Naming: İç API Yeniden Adlandırma + Public Alias (D kategorisi, ~34)
1. **Yerel/parametre değişkenleri** (MethodParameterName 5, VariableName 5, VariableNumber 1, RescuedExceptionsVariableName 1, BlockForwarding 3): mekanik, etkisiz — otomatik düzeltilebilir kısmı `-a`'ya kalmıştır kalanı elle.
2. **Public metotlar** (PredicateMethod 11 `empty` → `empty?`, PredicatePrefix 5 `has_key?` → `key?`, MethodName 2): her biri için önce GitNexus `context`/`impact` → çağrı noktaları `rename` ile taşınır → eski ad **alias olarak kalır** + `# deprecated:` yorumu. `Buffer::Snapshot#empty`, `AST::Graph#has_key?` bu gruptur.
3. **Naming/FileName (fixture):** düzeltme YOK; `.rubocop.yml`'ye `Naming/FileName: Exclude: ["test/fixtures/plugins/**/*"]` (gerekçe yorumuyla: dosya adı gem adını yansıtır).
4. `rake test` + plugin fixture testleri ayrıca yeşil olmalı (rename'ler eklenti yüklemesine değdiyse).

### Faz 7 — Metrics: Gerekçeli Konfigürasyon (E kategorisi, ~275)
- `.rubocop.yml`'ye, mevcut `Metrics/ParameterLists` gerekçe yorumu geleneğine uygun şekilde dosya/metot bazlı exclude'lar. Bilinen yoğun noktalar (Faz ölçümünden kesinleşir):
  - `lib/rubik/ast/typescript_extractor.rb` — `extract` (145 satır, AbcSize 129, karmaşıklık 34): dil extractoru doğası
  - `lib/rubik/config.rb` — sınıf 399 satır, `save!` karmaşıklık 20
  - `lib/rubik/ast/ruby_extractor.rb` — `walk_node` (karmaşıklık 18)
  - `lib/rubik/ast/cache_store.rb` — `load` (karmaşıklık 17)
  - `lib/rubik/buffer/manager.rb` — `sanitize_path` (karmaşıklık 24)
  - `lib/rubik/ast/symbol.rb` — `from_h` (karmaşıklık 21)
- BlockNesting 24 ve ParameterLists 29 için: test dışındaki kalıntılar ya exclude ya (kolaysa) GuardClause tarzı güvenli sadeleştirme — **asla davranış değiştiren kısayol yok**.
- Commit: `chore(rubocop): justified metrics exclusions` — diff yalnızca `.rubocop.yml`.

### Faz 8 — Kapanış Doğrulaması
1. `bundle exec rubocop` → **exit 0** (`--format offenses` boş).
2. `bundle exec rake test` → baseline assertion sayısıyla aynı veya üstü, sıfır fail.
3. GitNexus `detect_changes()` → yalnızca beklenen mekanik/sembol değişimleri; kayda değer yeni akış yok.
4. Public API alias'ların deprecation notları `CHANGELOG`/README gerektiriyorsa eklenir.
5. Bu plan dosyası durum satırı ✅ Tamamlandı'ya çevrilir; index.md güncellenir.

---

## 🧪 4. Test Planı

| Kontrol | Ne zaman | Geçme kriteri |
| :--- | :--- | :--- |
| `bundle exec rake test` (tam süit) | Her faz sonunda | Sıfır failure; assertion sayısı baseline ≥ |
| `bundle exec rake fast` | Faz 1-4 hızlı döngüde | Sıfır failure |
| `bundle exec rubocop --format offenses` | Her faz sonunda | Sayaç yalnızca azalır; yeni cop türü belirmez |
| Plugin fixture yükleme testleri | Faz 6 sonunda | Yeşil (rename + FileName exclude) |
| `git add --renormalize .` sonrası diff | Faz 3 | Yalnız satır sonu değişimi |
| `grep -rn "<<\|gsub!\|sub!\|concat" lib/rubik/tools/builtins/{files,symbols}.rb` | Faz 5 frozen-comment öncesi | Literal mutasyonu yoksa comment eklenir |
| GitNexus `detect_changes()` | Her commit öncesi (AGENTS.md) | Beklenen semboller dışında değişim yok |

Ek geri dönüş (regression) senaryoları — Faz 4/5'in en riskli üç düzeltmesi için birer unit test eklenebilir: (a) sandbox `allow_network` boolean-string coercion'ı hâlâ `true`/"true" kabul ediyor, (b) scanner `$HOME` benzeri okunamayan dizinlerde boş hash döndürüyor, (c) grep NUL baytlı dosyada sessizce atlanıyor.

---

## ⚠️ 5. Riskler ve Geriye Dönük Uyumluluk

| Risk | Olasılık | Etki | Önlem |
| :--- | :--- | :--- | :--- |
| SafeNavigation dönüşümünde `false` alıcı (31 yer) | Orta | NoMethodError → çökme | Elle dönüşüm + boolean akış analizi; şüphede inline bırak |
| EnvHome → `Dir.home` raise davranışı (14 yer) | Orta | HOME'suz ortamda (cron, service) crash | Bağlam bazında `ENV["HOME"]` kalabilir |
| NumericPredicate non-Numeric operand (28 yer) | Düşük | NoMethodError | Tip teyidi olmayanlar dönüştürülmez |
| FrozenStringLiteralComment mutasyonu kırar (2 dosya) | Düşük | Runtime FrozenError | Faz 5 öncesi mutasyon taraması |
| Public rename plugin/tüketicisi kırar | Orta | API kırılması | Alias + deprecation; Plan 53 kontratı korunur |
| Metrik exclude'ları çürür (kapsam genişler) | Kesin (zamanla) | Kalite erozyonu | Her exclude gerekçe yorumu taşır; gözden geçirme notu plana gömülür |
| Satır sonu normalizasyonu PR diff'ini şişirir | Kesin | Review gürültüsü | Ayrı commit + `.gitattributes` tekrarı önler |
| toplu `-a` beklenmedik biçimde kod bozar | Çok düşük | Kırık dosya | Faz bazlı commit + test kapısı; revert tek komut |

**Geriye dönük uyumluluk sözü:** Bu planın çıktısında hiçbir public metod imzası kaybolmaz (yalnızca alias eklenir), hiçbir davranışsal dal (hata mesajı, dönüş değeri, exception sınıfı) bilinçli değiştirilmez; değişen şeyler bu belgede bulgu numarasıyla sabitlenmiştir.

---

## ✅ 6. Kabul Kriterleri

- [ ] `bundle exec rubocop` **exit code 0** — kalan sıfır ihlal; `--disable-uncorrectable` kullanılmamış.
- [ ] `bundle exec rake test` tam süit yeşil; assertion sayısı Faz 0 baseline'ının altında değil.
- [ ] Public API: kaldırılan metod YOK; yeniden adlandırılan her metod için eski ad `alias` + `# deprecated:` mevcut.
- [ ] Her `rubocop:disable` / exclude tek satırlık gerekçe yorumu taşıyor.
- [ ] `.gitattributes` mevcut ve `git add --renormalize .` idempotent.
- [ ] 8 fazın her biri ayrı commit; her commit kendi fazının test kapısını geçmiş (geri-sarılabilir geçmiş).
- [ ] Faz 5'in UselessAssignment bulguları için "gerçek bug mı / dead code mı" kararı belgelenmiş.
- [ ] Bu dosya ✅ Tamamlandı işaretlenmiş ve `index.md` senkronize.
