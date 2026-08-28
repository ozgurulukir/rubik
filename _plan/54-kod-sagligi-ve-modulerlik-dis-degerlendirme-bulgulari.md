# 54 — Kod Sağlığı ve Modülerlik: Dış Değerlendirme Bulgularının Karşılanması

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Uygulandı** (28 Ağustos 2026) · **Zorluk:** Kolay → Orta–Zor (faz bazlı) · **Faz:** 6 (Bakım & Kod Sağlığı)  
> **İlgili Planlar:** [07](07-dil-adaptor-cercevesi.md), [41](41-repl-komut-modulerizasyonu-domain-driven-command-decoupling.md), [42](42-orchestrator-loop-dekompozisyonu-ve-llm-formatlayici.md), [45](45-spatiotemporal-oz-evrilen-calisma-zamani-ve-otonom-adaptor-sentezi.md), [46](46-ast-ve-baglam-motorunun-reaktif-coeffect-servisine-donusturulmesi.md), [47](47-orchestrator-loopun-reaktif-sistem-fiberina-donusturulmesi.md)  
> **Kapsam:** `lib/rubik/orchestrator/loop.rb`, `lib/rubik/tools/builtins.rb` (+ yeni `builtins/*.rb`), `lib/rubik/runtime/context.rb`, `lib/rubik/ast/ruby_extractor.rb`, `lib/rubik/adapter/{base,ruby,python}.rb`, test altyapısı  
> **Ön Çalışma:** 27 Ağustos 2026 dış değerlendirme incelemesi (7 bulgu) ve kod tabanı doğrulaması (§2)

---

## 🎯 1. Hedef ve Gerekçe

Rubik, dış bir değerlendirme tarafından **bakım sağlığı** ekseninden incelendi ve 7 iyileştirme alanı raporlandı. Bu plan, her iddiayı kod tabanında **doğruladıktan sonra** yalnızca haklı olanlarını fazlı iş paketlerine dönüştürür: 5 bulgu tamamen geçerli, 1 bulgu kısmen geçerli (teşhisi yanlış, kalıntı sorunu gerçek), 1 bulgu ise şu an için gerekçesiz görünüp belgelenmiş tetik koşuluyla ertelenir.

Planın üç ekseni:

1. **Modülerlik borcu:** `orchestrator/loop.rb` (654 satır) ve `tools/builtins.rb` (1321 satır, 21 araç sınıfı), projenin kendi hijyen ölçütlerinin (bkz. `shell.rb < 600` nöbetçi testi, `repl/commands/*.rb` alan-öbekli örüntü) üzerinde kalıyor. Plan 42 döngüyü metot seviyesinde bölmüş, sınıf seviyesinde işbirlikçi çıkarımı yapmamıştı; `orchestrator/` hâlâ tek dosya.
2. **Hata hijyeni:** `Runtime::Context#dispose` bir ters etki (inverse) başarısız olduğunda hatayı **sessizce yutuyor** — bu, AGENTS.md §5'in isim isim yasakladığı "Silent Failure Swallowing" anti-örgütünün birebir karşılığı ve protokolün kendi ölçütlerine göre düzeltilmesi gereken bir borç.
3. **Doğruluk ve kontrat:** AST fallback tarayıcısının naif `end` eşlemesi (string/heredoc/modifier-if körleri) ve `BaseAdapter#compile`'ın çağrıcısız kalan soyut-fakat-no-op ikilemi, küçük ama gerçek kontrat delikleridir.

---

## 🔍 2. Bulgu Değerlendirmesi (27 Ağustos 2026 doğrulaması)

| # | İddia | Doğrulama | Hüküm |
| :--- | :--- | :--- | :--- |
| B-1 | **Orchestrator Loop karmaşıklığı** — `loop.rb` ~650 satır; retry, streaming, araç çalıştırma, sıkıştırma, bütçe tek sınıfta. | ✅ Ölçüm: **654 satır**, `orchestrator/` dizininde tek dosya. Metot envanteri en az beş ilişkiyi doğruluyor: bütçe (`evaluate_step_budget_warning!`, `track_token_usage!`), LLM istem/yeniden deneme (`send_llm_request_with_recovery`), streaming (`execute_streaming_request`, `build_response_from_chunks` ~90 satır), araç sevki (`execute_single_tool_call`, `execute_registered_tool` ~107 satır), geçmiş/sıkıştırma (`evaluate_context_compaction!`). Plan 42'nin dekompozisyonu metot seviyesinde kalmış. | **GEÇERLİ** → Faz C |
| B-2 | **builtins.rb boyutu** — ~1300 satır, "18 araç sınıfı" tek dosyada; `repl/commands/*.rb` örüntüsü çoğaltılmalı. | ✅ Ölçüm: **1321 satır, 21 sınıf** (değerlendirici sayımı eksik). `registry.rb#build_default` sınıfları doğrudan örnekliyor; namespace `Rubik::Tools` altında. `repl/commands.rb` yükleyici örüntüsü (açık `require_relative` listesi + şim) birebir mevcut. | **GEÇERLİ** → Faz B |
| B-3 | **AST fallback naif anahtar sayımı** — yalnız satır-başı yorumlar atlanıyor; `"end"` string'i, satır içi yorum, heredoc, modifier-if sayılmıyor. | ✅ `ruby_extractor.rb:201-220` alıntıya birebir uyuyor. Ek kusurlar da doğrulandı: `begin`/`while`/`for`/`until` açıcıları hiç sayılmıyor (derinlik eksik kalır), modifier `if/unless` ve endless `def x =` gereksiz `end` bekler, `:end` sembolü yanlış sayılır. Yalnız Prism yoksa çalışır (`PRISM_AVAILABLE` → LoadError dalı); Ruby 3.3+ prism'i göredir, sıklık düşük. | **GEÇERLİ (düşük öncelik)** → Faz D |
| B-4 | **`Context#dispose` sessiz hata yutma** — yorum "log or capture" diyor, ikisi de yapılmıyor. | ✅ `context.rb:93-99`: boş `rescue StandardError` bloğu, `e` kullanılmıyor. AGENTS.md §5 anti-örgütüyle birebir örtüşüyor. | **GEÇERLİ (en hızlı kazanç)** → Faz A |
| B-5 | **Test paketi parçalanması** — "tam paket load-path ve bundler sorunlarından düşüyor; pattern bazı dosyaları kapsamıyor". | ⚠️ Sayı doğru (98 test dosyası); **teşhis yanlış**: Rakefile örüntüsü `test/{unit,integration}/**/test_*.rb` 98 dosyanın tamamını kapsıyor (tek istisna `test/fixtures/plugins/...` örnek eklentisi — kasıtlı). "Load-path/bundler" sorunu yeniden üretilmedi. Gerçek kalıntı: (a) tam paket sıralamasında **3 ortamsal hata** (reline `reset` ArgumentError ×1, `Errno::EACCES` temp teardown ×2 — HEAD'de `git stash` ile birebir kanıtlandı), (b) Windows'ta çoklu dosya çağırma tuhaflıkları (`ruby -Itest a.rb b.rb` yalnız ilki çalıştırır; `rake test TEST="a b"` tek yol sayar). | **KISMEN GEÇERLİ** → Faz E |
| B-6 | **Platform modülü karışık ilişkiler** — OS tespiti, URI, yol, süreç, dosya I/O tek modülde. | ⚠️ Ölçüm: 216 satır, 26 singleton metot, lib içinde **40 çağrı noktası**. Bölme (OS/Path/Process/FileUtils) 40 noktalık churn'e, davranış kazancı sıfıra, hâlihazırda ölçüt-altı bir dosyaya mal olurdu. | **ERTelenDİ** (D-8, tetik koşullu) |
| B-7 | **Adapter `check_syntax`/`compile` gereksizliği** — RubyAdapter#compile statik no-op; compile opsiyonel işaretlenmeli. | ✅ `BaseAdapter#compile` `NotImplementedError` fırlatıyor; `ruby.rb` ve `python.rb` statik no-op override yazmak zorunda kalmış. Lib ve testlerde **hiç çağrıcısı yok** (yalnız `check_syntax` çağrılıyor: `repair/loop.rb:61`, `commands/agent.rb:800`). | **GEÇERLİ** → Faz A |

**Sonuç:** B-1, B-2, B-3, B-4, B-7 uygulama kapsamına; B-5 yalnız doğrulanmış kalıntısıyla (ortamsal hatalar + çağırma kılavuzu) kapsama; B-6 kapsam dışı.

---

## 🏛️ 3. AGENTS.md Hizalaması

| Çalışma | Protokol bağı |
| :--- | :--- |
| `dispose` hata kaydı (B-4) | **§1.A Failure Reversibility + §5 "Silent Failure Swallowing".** LIFO Ω akümülatörü bir inverse patladığında kesintiye uğramamalı (ses-sağlamlık) **ve** hata görünür olmalı (gözlemsellik). Düzeltme ikisini birden sağlar. |
| `builtins/*.rb` bölme (B-2) | **§3.1 Zero-Downtime Tool Swapping & Deterministic Tool Registration.** Alan-öbekli küçük dosyalar, sıcak-takası düşünülebilir en küçük birim haline getirir; `Registry`'nin deterministik kayıt kontratı değişmeden kalır. `repl/commands/*.rb` (Plan 41) örüntüsünün araç yüzeyine genişletilmesidir. |
| Loop dekompozisyonu (B-1) | **§3 Yönergelere hizmet:** küçük işbirlikçiler (StepExecutor/StreamManager/BudgetManager) döngünün yeniden başlatmasız evrimini ve birim testini mümkün kılar. Plan 42 (metot-seviyesi) ve Plan 47 (fiber yaşam döngüsü) arkının tamamlanmasıdır. |
| AST fallback sertleştirme (B-3) | **§1.B Reactive Coeffects kalitesi:** Plan 46 ile AST grafı `Σ` servisine dönüştü; yanlış `line_end` bozuk sembol gövdesi demek, bağımlı bileşenlere kirlilik sızması demek. Fallback yolunun da kontratı koruması gerekir. |
| `compile` no-op varsayılan (B-7) | **Plan 45 self-evolving adaptörler:** sentezlenen adaptörler için `compile` artık geçersiz kılınabilir bir yetenek, zorunlu bir formalite değil. |
| Test ortamı hijyeni (B-5) | Yukarıdakilerin tümü güven ağına yaslanır; "yeşil paket" ölçülebilir olmalı. |

---

## 🧩 4. Tasarım Kararları

### D-1 — `dispose` hata politikası: kaydet, sürdür, asla yutma
`Context#dispose` içindeki rescue bloğu: (a) tek satırlı `$stderr` uyarısı basar (`[rubik] dispose inverse failed: Class: message`), (b) hata `@last_dispose_errors` dizisine eklenir ve `last_dispose_errors` okuyucusuyla dışarı açılır (test ve `!runtime` içgörüsü için). **Asla re-raise edilmez; kalan inversler kesintisiz LIFO sırayla çalışır.** Çocuk bağlamların hataları ebeveyne sızmaz (§1 bağlam izolasyonu korunur — ebeveyninverse'i `child.dispose`'u çağırır ve o hiç hata fırlatmaz).

### D-2 — `compile` opsiyonel yetenek kontratı
`BaseAdapter#compile` varsayılan no-op sonuç döner (`{ ok: true, output: "<name> requires no compilation", duration: 0.0, exit_code: 0 }`); `ruby.rb` ve `python.rb`'deki statik override'lar silinir; c/go/zig/rust gerçek override'ları aynen kalır. `check_syntax` soyut kalır (gerçek zorunlu kontrat o). *Değerlendirilen alternatif:* tamamen silmek — reddedildi; Plan 45'in sentezlediği derlemeli-dil adaptörleri için geçersiz kılma noktası değerli.

### D-3 — `builtins/*.rb` alan-öbekli dosya haritası
`builtins.rb` yükleme şimine dönüşür (açık `require_relative` listesi — `repl/commands.rb` örüntüsü); `tools.rb`'deki tek `require_relative "tools/builtins"` satırı değişmez; namespace `Rubik::Tools` aynen korunur, `Registry.build_default` dokunulmaz. Önerilen harita (satır tahminleri):

| Dosya | Sınıflar | ~Satır |
| :--- | :--- | :--- |
| `builtins/files.rb` | ReadFile, WriteFile, ListFiles | ~90 |
| `builtins/grep.rb` | GrepSearch | ~220 |
| `builtins/symbols.rb` | SearchSymbols, GetOutline, FindReferences, GetSymbol | ~180 |
| `builtins/lsp.rb` | LSPDiagnostics, LSPHover, LSPDefinition | ~170 |
| `builtins/exec.rb` | RunTests, RunCommand, ExecReplCommand | ~165 |
| `builtins/synthesis.rb` | SynthesizeCommand, SynthesizeTool | ~175 |
| `builtins/runtime.rb` | InspectRuntime, ProvideService | ~100 |
| `builtins/lifecycle.rb` | ApplyBuffer, RepairRuntime, Finish | ~265 |

Değerlendiricinin "sınıf başına bir dosya" önerisinden bilinçli sapma: projenin kendi örüntüsü (`repl/commands/*.rb`) alan-öbekli gruplama kullanır; 21 dosya yerine 8 okunur dosya.

### D-4 — Boyut nöbetçi testlerinin genelleştirilmesi
`test_repl_command_decoupling.rb:82` (`shell.rb < 600`) örüntüsü `test_module_hygiene.rb` altında genelleştirilir: `builtins.rb < 60` (şim), her `builtins/*.rb < 300`, `loop.rb < 350`, her `orchestrator/*.rb < 300`. Sınırlar kabul kriterleriyle (§7) eşleşir; regresyonu anında yakalar.

### D-5 — Loop API'si delege edicilerle korunur
`test_loop_decomposition.rb` dâhil mevcut `send`-bazlı testler **değiştirilmez**. `Loop`, taşınan metotlar için tek satırlık delege ediciler tutar (ör. `def handle_finish_tool(...) = @step_executor.handle_finish_tool(...)`). Testleri yeniden yazmak, dekompozisyonun kendi güven ağını sökmek olur; dokunulmamış yeşil testler davranış korumasının kanıtıdır.

### D-6 — Çıkarım sırası risk artanına göre: Step → Budget → Stream
C1 StepExecutor (en kalabalık test kapsamı: `test_loop_decomposition.rb`) → C2 BudgetManager (`test_agent_step_budget.rb`, `test_conversation_history.rb`) → C3 StreamManager en son (`execute_streaming_request`, `build_response_from_chunks`; kesinti/pipe hattı b2b8a45'te elle düzeltildi — en hassas yüzey). `send_llm_request_with_recovery`/`execute_batch_request`/`execute_steps` koordinasyonu Loop'ta kalır. Her taşımadan sonra loop test bataryası + tam `rake` çalışır.

### D-7 — AST fallback "lexer-lite": pragmatik satır-öncesi temizleyici
Tam ayrıştırıcı yazılmaz; `find_matching_end` öncesine durum-makinesli bir satır temizleyici eklenir: (1) tırnak durum makinesiyle string **içerikleri** boşaltılır (tek/çift tırnak, ters-eğik çizgi kaçışı, `:"..."`), (2) tırnak dışı satır içi `#` yorumları atılır, (3) heredoc gövdeleri (`<<~ID`/`<<-ID`/`<<ID` başlatıcı + kapanış satırı) atlanır, (4) açıcı küme `begin`/`while`/`for`/`until` ile tamamlanır, (5) **modifier** `if/unless/while/rescue` (satırda koddan sonra gelen) açıcı sayılmaz, (6) endless `def x = ...` `end` beklemez, (7) `:end` sembol literal'i sayılmaz. **Belgelenmiş sınırlar (bilinçli kapsam dışı):** `%w[]`/`%i[]` içi anahtar kelimeler, `__END__`, egzotik string sınırlayıcılar. Taşma güven ağı korunur: eşleşme bulunamazsa bugünkü `start_idx + 1`. Test edilebilirlik için ekstraktöre yalnız-test amaçlı `force_fallback:` ctor kancası eklenir (`PRISM_AVAILABLE` sabiti stub'lanamaz).

### D-8 — `platform.rb` erteleme tetikleri
Bugün bölme gerekçesiz (216 satır, 40 çağrı noktası, davranış kazancı sıfır). Yeniden değerlendirme tetikleri: (a) dosya **>300 satıra** büyürse veya (b) yeni bir sorumluluk ailesi eklenirse (ör. süreç yönetimi genişlerse `Platform::Process`), o zaman alan-öbekli bölme D-3 örüntüsüyle yapılır.

### D-9 — Test ortamı: belgele, triyaj et, karantinayı adlandır
(a) README test bölümüne çağırma kılavuzu: tek dosya `ruby -Itest test/unit/<dosya>.rb`, tam paket `rake`; Windows çoklu argüman tuhaflıkları belirtilir. (b) reline tam-paket `reset` hatası triyaj edilir (Reline global terminal durumu/alt süreç teorisi); kök neden bulunamazsa **açıklamalı skip** ile karantinaya alınır ve §9'da kayda geçer. (c) `Errno::EACCES` teardown: kilitli tanıtıcı senaryosuna karşı test yardımcısına küçük gecikmeli-retry'lı temizlik yardımcısı eklenir; tekrar üretilemiyorsa belgelenir. Rakefile örüntüsüne dokunulmaz (doğrulandı: tam kapsam).

---

## 📦 5. Uygulama Fazları

### Faz A — Hızlı Hijyen Kazanımları (Kolay)
1. `runtime/context.rb`: D-1 dispose politikası (+~8 satır).
2. `adapter/base.rb`: D-2 compile varsayılanı; `adapter/{ruby,python}.rb`: no-op override'ların silinmesi (−2 blok).
3. Yeni testler: `test_context_dispose_hygiene.rb`, `test_adapter_compile_contract.rb`.

### Faz B — `builtins/*.rb` Bölme (Kolay–Orta, mekanik)
1. D-3 haritasıyla 8 dosya taşıma (davranış değişikliği yok; saf relocation).
2. `builtins.rb` → yükleme şimi.
3. `test_module_hygiene.rb`: D-4 nöbetçileri + 21 sınıfın yüklendiği + `Registry.build_default`'ın aynen kurulduğu doğrulama.
4. Rubocop: yeni dosyalar HEAD bütçesiyle parite (taşınan kod zaten denetimli).

### Faz C — Loop Dekompozisyonu (Orta–Zor, üç sıralı adım)
- **C1 `orchestrator/step_executor.rb`:** `execute_single_tool_call`, `execute_registered_tool`, `handle_finish_tool`, `handle_invalid_tool`, `parse_tool_call`. Loop'ta tek satır delege ediciler (D-5).
- **C2 `orchestrator/budget_manager.rb`:** `evaluate_step_budget_warning!`, `track_token_usage!`, `estimate_tokens_from_history`, `evaluate_context_compaction!`.
- **C3 `orchestrator/stream_manager.rb`:** `execute_streaming_request`, `build_response_from_chunks`, `llm_retry_notifier`.
- Her adımdan sonra: `test_loop_decomposition.rb`, `test_orchestrator.rb`, `test_orchestrator_stream.rb`, `test_orchestrator_fiber_lifecycle.rb`, `test_agent_step_budget.rb`, `test_conversation_history.rb`, `test_llm_retry_wiring.rb`, `test_finish_streamed_flag.rb` + tam `rake`. C3 sonrası manuel smoke: gerçek oturumda streaming goal koşusu + Ctrl+C.

### Faz D — AST Fallback Sertleştirme (Orta)
1. D-7 lexer-lite temizleyici + açıcı-kümesi tamamlama.
2. `force_fallback:` test kancası; `test_ast_fallback_scanner.rb`: `"end"` string'i, satır içi yorum, heredoc, modifier if, endless def, `begin/while` blokları, `:end` sembolü senaryoları.

### Faz E — Test Ortamı Hijyeni (Kolay–Orta)
1. README çağırma kılavuzu (D-9a).
2. reline triyaj/karantina (D-9b), EACCES teardown yardımcısı (D-9c).

> Fazlar büyük ölçüde bağımsızdır (yalnız C1→C2→C3 sıralı ve E, C'den sonra gelir ki 3 ortamsal hata ayıklaması yeni kodla karışmasın).

---

## 🧪 6. Test Stratejisi

| Test | Tür | Kapsam |
| :--- | :--- | :--- |
| `test_context_dispose_hygiene.rb` | Yeni | Hatalı inverse'te kalan inversler yine çalışır (LIFO sürer); `$stderr` uyarısı; `last_dispose_errors` dolu; çocuk bağlam hatası ebeveyne sızmaz |
| `test_adapter_compile_contract.rb` | Yeni | Base varsayılan no-op; ruby/python override'sız; c/zig gerçek derleme |
| `test_module_hygiene.rb` | Yeni | D-4 nöbetçileri; 21 sınıf yüklü; `build_default` 21 aracı kaydeder |
| `test_loop_decomposition.rb` | **DEĞİŞMEZ** (D-5) | Delege ediciler üzerinden eski davranış kanıtı |
| `test_orchestrator_stream.rb` | Genişletme | StreamManager çıkarımı sonrası chunk akümülasyonu |
| `test_ast_fallback_scanner.rb` | Yeni | D-7 senaryoları |
| Mevcut loop/bütçe/geçmiş testleri | Dokunulmaz | C1–C3 sonrası batarya |
| Tam `rake` | Her fazda | 661+ runs karşılaştırması; 3 ortamsal hata (B-5) ayrıştırılarak raporlanır |

---

## ✅ 7. Kabul Kriterleri

- [ ] `loop.rb` ≤ 350 satır (koordinatör); her yeni `orchestrator/*.rb` ≤ 300; delege ediciler mevcut `send`-bazlı testleri yeşil tutar.
- [ ] `builtins.rb` ≤ 60 satır (şim); her `builtins/*.rb` ≤ 300; `Rubik::Tools` 21 sınıfı aynen taşır; `Registry.build_default` çıktısı değişmez.
- [ ] Dispose: hatalı inverse kalan Ω'yı durdurmaz; hata `$stderr`'de + `last_dispose_errors`'da görünür.
- [ ] `compile`: BaseAdapter no-op varsayılan; ruby/python override silik; mevcut adaptör testleri yeşil.
- [ ] Fallback tarayıcı: D-7 senaryolarının tamamı doğru `line_end` döndürür; Prism yolu davranış değişikliği yok.
- [ ] Tam paket yeni hata üretmez (3 belgelenmiş ortamsal hata hariç); reline/EACCES triyaj kararı §9'da kayıtlı.
- [ ] Rubocop: düzenlenen her dosyada offense sayısı HEAD ≤ (CRLF renormalizasyonu bilinçli).
- [ ] `test_module_hygiene.rb` ve `test_repl_command_decoupling.rb` birlikte bütün dosya-boyut nöbetçilerini tutar.

---

## ⚠️ 8. Riskler ve Azaltımlar

| Risk | Olasılık | Azaltım |
| :--- | :--- | :--- |
| C3 streaming/interrupt regresyonu (b2b8a45 hassas yüzeyi) | Orta | En son adım; tam loop bataryası + gerçek oturum smoke testi; StreamManager saf fonksiyonel tutulur (durum Loop'ta kalır) |
| `builtins` taşımasında require döngüsü/sırası | Düşük | Şim dosyası tek giriş noktası; her dosya `require_relative "base"` ile başlar; `test_module_hygiene.rb` yükleme doğrulaması |
| Lexer-lite'ın kendi kenar durumları (B-3) | Orta | Test-tanımlı alt küme (D-7); taşma güven ağı (`start_idx + 1`) korunur; sınırlar belgelenir |
| Karantina kararının test sayısını düşürmesi | Düşük | Yalnız açıklamalı skip; §9 kaydı; tek dosya kapsamında |
| Rubocop bütçe aşımı (yeni dosyalarda metrik sıfırlanması) | Orta | Faz B'de taşınan kod paritesi; C'de yardımcı başına karmaşıklık nöbetçisi (§7) |
| Boyut nöbetçilerinin gelecek katkılarda sıkması | Düşük | Sınırlar cömert (300); aşımda plan güncellemesi §9'la zorunlu |

---

## 📝 9. Sapmalar ve Uygulama Kayıtları

**Uygulama:** 28 Ağustos 2026 — A→E tüm fazlar tamamlandı. Kalite kapısı: 3 inceleyici ajan (basitlik, doğruluk, konvansiyonlar) + taşınan 11 metodun normalize edilmiş birebir HEAD diff'i (hepsi parite; yalnız bilinçli farklar: `@loop.` erişim öneki, `loop_instance: @loop`, estimate çağrı yeri, ölü `@saw_chunks` ataması).

| # | Konu | Plan'dan Sapma | Gerekçe |
| :--- | :--- | :--- | :--- |
| 1 | Faz C1 yerleşimi (D-5/D-6) | `parse_tool_call` Loop'ta kaldı; `clean_llm_text` StepExecutor'a taşındı | `parse_tool_call`'ın tek çağrıcısı `extract_and_normalize_tool_calls` Loop'tadır; `clean_llm_text`'in tek çağrıcısı taşınan `handle_finish_tool` |
| 2 | C3 ölü durum (D-6) | `@saw_chunks` ataması taşınmadı — silindi | Keşif ajanının ivar haritasında yazma-dışı/hiç okunmayan durum tespit edildi; parite diff'i teyit etti |
| 3 | D-7 kapsam genişlemesi | Temizleyici ayrı dosyada (`ast/fallback_cleaner.rb`; plan kapsamı yalnız `ruby_extractor.rb` idi). `__END__` plana göre kapsam DIŞIYKEN EKLENDİ; ayrıca `=begin/=end` blokları, **regex literalleri**, `?"` karakter literalleri ve düz `<<EOS` için sütun-0 terminator kuralı eklendi. Yeni kabul edilen sınırlar: satır başına çoklu heredoc, `x <<identifier`'ın heredoc sanılması, regex içinde `/` karakter sınıfı | İnceleyici ajan `/["']/` içindeki tırnağın hayalet string açtığını buldu (ÖNEMLİ) — düzeltme regex tanımayı zorunlu kıldı; ClassLength 300 sınırı ayrı dosyayı gerekli kıldı |
| 4 | D-9b — reline | Karantina branch'i KULLANILMADI: kök neden bulunup **düzeltildi**. `interrupt_handler.rb`'deki `le.reset("", encoding: enc)` çağrısı hiçbir reline sürümünde geçerli değil (0.6.3 imzası `reset(prompt='')`); her koşuda ArgumentError fallback'ine düşüyordu. `enc` hesaplama bloğu kaldırıldı, çağrı `le.reset("")` + `ArgumentError` → `le.reset` oldu | Hata tam-paket-özel de değil: tek dosyada da yeniden üretiliyordu (önceki teşhis düzeltildi); test tasarımı zaten hatayı yakalamak içindi |
| 5 | D-9c — teardown | `remove_temp_dir` ayrıca `ENOTEMPTY` ve `ENOENT`'i kapsar | Windows gerçekleri; tam paketteki 2 EACCES error giderildi (2 temp dizini tanıtıcı açık kaldığı için yine silinemedi — 5 deneme sonrası uyarıyla geçildi, kabul) |
| 6 | §6 test tablosu | `test_orchestrator_stream.rb` genişletmesi StreamManager **doğrudan** testiyle yapıldı (`build_response_from_chunks` birim testi); `test_ast_fallback_scanner.rb` 13 teste çıktı (regex, bölme, düz-heredoc sahtesi dahil); `test_module_hygiene.rb` baz-adı listesiyle yeniden adlandırmaya karşı sağlamlaştırıldı | İnceleyici tautolojik motor-testi işaretledi — Prism imza farkıyla gerçek ayırt edici yapıldı |
| 7 | Gözlem (eylem yok) | 9 adet önceden var olan LF dosya (`platform.rb` + 8 test dosyası) CRLF normuna uymuyor; Plan 54 bunlara dokunmadı | D-8 ertelemesi kapsamında not; ayrı hijyen işi |
| 8 | Süreç | 2. keşif ajanı ve ilk loop-doğruluk inceleyicisi 600 sn zaman aşımına düştü; loop incelemesi dar kapsamla yeniden koşuldu (6/6 kimlik PASS) ve birebir diff ile kapatıldı. AGENTS.md GitNexus MCP araçları oturumda bağlı değildi → etki analizi yerine tam paket + HEAD karşılaştırmaları güven ağı oldu |  |

**Doğrulama ölçümleri (28 Ağustos 2026):**

- `loop.rb` **654 → 297** satır (koordinatör); `step_executor` 226, `stream_manager` 173, `budget_manager` 64 — hepsi < 300.
- `builtins.rb` **1321 → 14** satır şim; 8 alan dosyası en büyük 246 (`lifecycle.rb`) — hepsi < 300.
- Tam paket: **689 koşu / 3691 iddia / 0 hata / 0 error / 0 skip** — HEAD'deki 1 failure (reline) + 2 error (EACCES) düzeltildi; paket ilk kez tamamen yeşil.
- Rubocop: düzenlenen tüm dosyalar HEAD ≤ (builtins 104 → dağıtılmış 103; loop 53 → 14+36=50; context 2→1; adapter base 6→3; test_helper 1→0); yeni elle yazılan dosyalar 0 offense.
- Yeni testler: `test_context_dispose_hygiene` (4), `test_adapter_compile_contract` (4), `test_module_hygiene` (6), `test_ast_fallback_scanner` (13), `test_orchestrator_stream` +1; mevcut `send`-bazlı loop testleri DEĞİŞMEDİ.
