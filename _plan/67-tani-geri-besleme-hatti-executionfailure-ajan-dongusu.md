# Plan 67 — Tanı Geri-Besleme Hattı: ExecutionFailure'ın Ajan Döngüsüne Akışı

> **Domain:** Orkestratör / Tanı (Diagnostics → Agent Loop)
> **Kaynak:** Dış değerlendirme (Ağustos 2026) — "Concern 8: Diagnostic Engine Structure" + "Key Recommendation 5: Integrate DiagnosticEngine" + "Concern 9: Adapter Test Runner Resolution" (tek haklı kırıntısı)
> **Durum:** ✅ **Tamamlandı**
> **Öncül Planlar:** [08](08-hata-ayristirma-teshis.md) · [11](11-kendi-kendine-onarim.md) · [22](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md) · [57](57-sistem-saglamligi-birlesik-tanilama-fuzyonu-e2e-ve-thread-safety.md) · [63](63-dis-degerlendirme-tavsiye-triyaji-ve-davranis-koruyucu-iyilestirmeler.md)

---

## 1. Amaç

`Runtime::DiagnosticEngine` / `ExecutionFailure` altyapısı güçlü ama ürünleşmiş hali ajan döngüsünün **içinden** görünür değil: `run_tests` aracı yapılandırılmış teşhisi (kategori + öneri) hesapladığı hâlde LLM'ye yalnızca ham çıktıyı veriyor. Bu plan, mevcut teşhis nesnelerini ajanın bir sonraki turuna akan geri-beslemeye çevirir ve adapter'in "koşucu bulunamadı" mesajını dürüstleştirir.

## 2. Kanıt ve Triyaj (kod tabanından)

### 2.1 "Not yet fully integrated" — büyük ölçüde güncel değil, gerçek bir eksik var

DiagnosticEngine **üç yerde** zaten entegre:

| Entegrasyon | Konum |
| :--- | :--- |
| Adapter test/format sonuçlarına `res[:diagnostic]` eki | `lib/rubik/adapter/base.rb:43,52` |
| LSP sunucu başlatma/fix hataları | `lib/rubik/lsp/manager.rb:137,163` |
| `repair_runtime_service` doğrulama hataları (`format_for_llm` kullanımı) | `lib/rubik/tools/builtins/lifecycle.rb:131-226` |

Değerlendirmenin görmediği **gerçek eksik**: `run_tests` aracı (`lib/rubik/tools/builtins/exec.rb:37-40`) `res[:output]`'u döndürüp `res[:diagnostic]`'i (category + suggestion) çöpe atıyor — ajan, başarısız test çalıştırmasından sonra **neden** başarısız olduğuna dair yapılandırılmış ipucu olmadan bir sonraki tura giriyor. `run_command` aracı hiç teşhis eklemiyor.

### 2.2 "Repair loop not integrated" — kök neden farklı

`lib/rubik/repair/loop.rb` çalışma zamanında **çağrılmıyor** (grep: yalnızca `benchmark/runner.rb`'deki "Self-Repair Success Rate" *metrik etiketi* geçiyor; kod çağrısı yok). Yani eksik entegrasyon değil, kullanılmayan bir modül var. Bu plan repair döngüsünü canlandırmayı **kapsam dışı** bırakır (ayrı karar: canlandırma mı emeklilik mi).

### 2.3 Concern 9 (adapter test runner) — çoğunlukla haksız, tek kırıntı haklı

- "Sessiz kalma" iddiası haksız: koşucu bulunamayınca `run_tests` yapılandırılmış başarısızlık döndürür (`base.rb:39-40` → `unavailable_result`, exit 127) — sessiz değil.
- "Ruby defaults rspec; proje minitest kullanıyor" iddiası haksız: keşif zinciri `rake test`'i kapsıyor (`runtime/discovery.rb:92` Gemfile adayları, `:129` ruby varsayılanı) — minitest yolu bu depoda tam da budur.
- **Tek haklı kırıntı:** `unavailable_result` mesajı *"#{bin} is unavailable on system"* derken `bin` dil binary'sidir (`base.rb:90-93`); koşucu bulunamadığında (binary kurulu, rspec/rake yok) mesaj **yanıltıcıdır** ve ajanı yanlış yönlendirir (binary'yi yeniden kurmayı dener).

## 3. Kapsam — Fazlar

### Faz A — `run_tests` / `run_command` teşhis zenginleştirmesi
- `exec.rb:37-40`: `res[:ok]` false VE `res[:diagnostic]` varsa araç çıktısına `format_for_llm` bloğu eklenir (kategori + öneri + stderr özeti). Başarılıda çıktı değişmez.
- `run_command` aracı: başarısızlıkta `DiagnosticEngine.analyze_process_result` ile teşhis üretip aynı kalıbı uygular (base adapter'daki mevcut kalıbın araç tarafına genişletmesi).
- Ajan bir sonraki turda artık ham stderr yerine "Category: TEST_FAILURE — Suggestion: ..." görür (Plan 22'nin durumsal farkındalık hedefine doğrudan hizmet).

### Faz B — Adapter mesaj doğruluğu
- `BaseAdapter#unavailable_result` seçmeli sebep parametresi alır: koşucu çözümlenemediğinde mesaj *"No test runner found for ruby (tried: bundle exec rspec, bundle exec rake test, rake test). Install one or set tools.test_cmd."* gibi keşfedilen adayları söyler; binary gerçekten yoksa mevcut mesaj kalır.
- `resolve_test_cmd`'in "bulamadım" durumu artık sessiz `nil` değil, çağrıcıya görünür olur (dönüş kontratı değişmez — yalnız mesaj üretimi zenginleşir).

### Faz C — Testler
- Birim: (1) fixture başarısız test çıktısı → araç çıktısında `:test_failure` kategorisi + öneri satırı; (2) başarılı koşumda ek blok yok; (3) koşucu-yok senaryosunda adayları sayan mesaj; (4) `run_command` başarısızlığında teşhis bloğu.
- Mevcut `test` dosyaları (exec/adapter kümesi) birebir yeşil kalır; E2E gerekmiyor.

## 4. Kapsam Dışı (bilinçli)

- **`Repair::Loop`'un orkestratöre bağlanması/canlandırılması** — modül çalışma zamanında kullanılmıyor (2.2); canlandırma-emeklilik kararı ayrı bir planın konusu. Bu plan dokümanı o kararı not eder, uygulamaz.
- **EventBus async/wildcard** (Concern 7) — değerlendirme kendisi "adequate" diyor; spekülatif genişletme YAGNI.
- Yeni teşhis kategorileri / `determine_category` kalıp genişletmesi — mevcut kategori taksonomisi yeterli.

## 5. Riskler ve Notlar

- Faz A, araç çıktısına satır ekler → çıktı boyutu sınırlaması (`tools.max_output_chars`) mevcut kesme altyapısıyla korunur; `format_for_llm` zaten kısa (stderr boşsa stdout, tek satır özet).
- REPL `!test` yüzeyi (`repl/commands/agent_execution.rb:126-154`) zaten `res[:diagnostic]`'i insan-okur biçimde basıyor — Faz A yalnızca **ajan** akışını (araç çıktısı) zenginleştirir, REPL çıktısı değişmez.
- Teşhis üretimi yalnızca `res[:ok] == false` dalında çalışır; başarı yolunda sıfır ek maliyet.

## 6. Kabul Kriterleri

- [ ] Faz C'deki 4 test senaryosu yeşil; mevcut exec/adapter testleri birebir.
- [ ] Tam `rake test` yeşil, `rubocop` 0 ihlal.
- [ ] Başarılı test koşumunun araç çıktısı bit-biti aynı kalıyor (regresyon yok).
- [ ] Koşucu bulunamadığında mesaj dil binary'sini değil, denenmiş adayları söylüyor.

## 7. Uygulama Sonucu

- **Diff İncelemesi:** `lib/rubik/tools/builtins/exec.rb` ve `lib/rubik/adapter/base.rb` başarıyla güncellendi.
- **Testler:** `test/unit/test_exec_tools_diagnostics.rb` eklendi; 4 yeni test senaryosu ve mevcut testler yeşil.
- **Sağlık:** `bundle exec rubocop` ve `bundle exec rake test` sıfır hata/uyarı ile tamamlandı.
- **Çıktı Kalitesi:** Başarısız koşumlarda diagnoztik bilgisi ajana iletiliyor, başarılı koşumlarda regresyon yok, adapter hata mesajları denenen adayları listeliyor.

## 8. Disiplin

Her faz sonrası: tam `rake test` + `rubocop` kapısı, Windows'ta LF normalizasyonu, faz başına anlamlı commit. `run_tests` aracı ve `unavailable_result` düzenlenmeden önce GitNexus `impact` (erişim yoksa Plan 63 emsaliyle explorer agent etki analizi).
