# Test Stratifikasyonu (Review Öneri 1) — 2026-09-14

**Durum:** ✅ Uygulandı — review Öneri 1 reçetesinin **taktiksel türevi** (aynı gün; unit_once 1616 runs/9549 assertions tek proses 7.5 dk — serial 74 dk'ya karşı). Reçeteyle birebir örtüşme aşağıdaki **Kapsam Notu** tablosunda; **Öneri 1 tam kapanmadı** — kalan açık kalemler tabloda.
**Ek düzeltme (aynı tur):** `test:fast` kabulünde kalan 4 failure HEAD'de de vardı — unsynthesize commit'i (`8d7542f0`) 22→23 tool sayımlarını atlamış ve `synthesis.rb`'yi 389 satırla 350 sınırının üstüne taşımıştı. `UnsynthesizeTool` `builtins/unsynthesize.rb`'ye çıkarıldı (synthesis.rb → 294 satır, koruma sağlandı), üç sayım testi + domain-dosya listesi 23/10'a güncellendi. Sonuç: `test:fast` 1513 runs **0 failures**.
**Kaynak:** `_reviews/2026-09-14-architectural-review.md` Öneri 1 + Bulgu 4 (tam paket Windows'ta >5 dk, 300s timeout'ta bitmiyor)

**Ölçülen koşum süreleri (kabul kriteri 2):** `test:fast` 1513 runs, 0 failures — **184s duvar süresi**; `test:slow` 104 runs — 248s; `test:unit_once` 1616 runs — ~7.5 dk.

## Kapsam Notu — Öneri 1 reçetesine göre taktiksel türev

Reçete ("unit/integration ayrımı + paralel minitest; adapter spawn testlerini `tag :slow` ile ayırıp varsayılan task'tan çıkar; `rake test` saniyeler içinde feedback versin") profil ölçümüyle revize edildi: maliyet adapter spawn'larında değil, dosya başına ~8.5s sabit boot maliyetindeydi. Reçetenin **mekanizması değil, hedefi** (hızlı geri bildirim) ölçüme dayalı türevle karşılandı:

| Reçete öğesi | Durum | Not |
|---|---|---|
| unit/integration ayrımı | ✅ Zaten mevcuttu | `test:unit`/`test:integration` bu işten önce var; kapsam dışı. |
| Paralel minitest | ❌ Uygulanmadı — **açık** | Boot maliyeti paralellikten bağımsız; tek-proses `test:unit_once` aynı hedefi Windows'ta risksiz karşıladı. Paralel minitest (minitest 5, Windows) ayrı değerlendirme gerektirir. |
| `tag :slow` mekanizması | 🔄 Türevle değiştirildi | Etiket yerine ölçüme dayalı `SLOW_UNIT_FILES` (profil >15s; kanıt `_report/unit_profile.csv`). Yavaş sınıf adapter spawn değil thread/sleep ağırlıklı 15 dosya çıktı. |
| Yavaşların varsayılan task'tan çıkarılması | ⚠️ Kısmi | `test:fast` çıkarıyor; **varsayılan `rake test` değişmedi** — hâlâ tam serial (unit+integration) koşar. |
| `rake test` saniyeler içinde feedback | ❌ Karşılanmadı — **açık** | Hızlı döngü bugün `test:fast` (184s) ve `test:unit_once` (~7.5 dk); varsayılan task'ta değil. |

**Öneri 1'den kalan açık iş:** (1) varsayılan `rake test`'in hızlandırılması (default'ı `test:fast` + integration'a bağlamak veya paralelleştirme kararı), (2) paralel minitest'in minitest-5/Windows'ta değerlendirilmesi. Bu kalem kapanmadan Öneri 1 için "tamamlandı" değil "kısmen" denmelidir.

## Sorun — Ölçülmüş Kanıt (`_report/unit_profile.csv`, 400 dosya)

- Serial toplam **4415s (~74 dk)**, ort. **11.0s/dosya**; dosya başına ~**8.5s sabit boot maliyeti**
  (Ruby + `require rubik`) — test gövdelerinin kendisi hızlı.
- **Sahte FAIL kök nedeni — çift minitest:** Ruby 4.0.6 default gem'i **minitest 6.0.0**
  (`minitest/mock` **kaldırılmış**), Gemfile `~> 5.20` → lock **5.26.2**. Çıplak `ruby` ile koşan
  dosyalar FAIL; `bundle exec` ile aynı dosyalar yeşil (doğrulanan: security_guard 10✅,
  chunk_assembler 17✅, bubblewrap 3✅, crystal_and_generic_adapter 33✅, test_repl 12✅).
- **Platform gating GEREKMEZ:** "platform" görünen tüm FAIL'ler ortam artefaktı. Bubblewrap
  Windows'ta bile yeşil (driver stub tabanlı). Karar: platform-özel test/gating eklenmeyecek;
  bunun yerine koşucu ortam tutarlılığı zorlanacak (bundler pin).

## Paketler

**A — Ortam kalkanı (sahte FAIL'lerin kökten çözümü)**
- `test/test_helper.rb`: `Minitest::VERSION >= 6` ise fail-closed abort — mesaj `bundle exec`
  yönlendirmesi içerir. Sessiz yanlış-negatif yerine net sinyal.
- `dev/profile_unit_tests.rb`: child prosese bundler devralma (`-rbundler/setup`, parent bundler
  altındaysa) → profil artık gerçek CI ortamını ölçer.

**B — Stratifikasyon (Rakefile, ölçüme dayalı)**
- `SLOW_UNIT_FILES`: profil >15s olan 15 dosya (test_repl, spatiotemporal_runtime_invariants,
  mcp_client, plugin_repl_integration, plan_and_goal, buffer_reminder_and_auto_apply,
  mcp_manager_composability, lsp_manager_and_diagnostics, sticky_routing,
  failed_turn_persistence, conversation_history, cli, synthesis_security,
  structured_context_builder, agent_command_contract).
- `test:fast` → unit eksi SLOW (hızlı geri bildirim döngüsü; ölçülen 184s, 1513 runs).
- `test:slow` → yalnız SLOW (yeni).
- `test:profile` → `dev/profile_unit_tests.rb` sarmalayıcı (yeni).
- `test:unit_once` → `dev/run_unit_once.rb` tek-proses tüm unit (boot maliyetini 1'e indirir; CI).

**C — Koşucu ortam tutarlılığı (run_tests aracı)**
- `Runtime::Discovery` ruby test-runner adayı Gemfile+lock varken `bundle exec` tercih edecek
  şekilde güncellenir (Gemfile yoksa davranış değişmez). Böylece `run_tests` her zaman pinned
  stack koşar.

**D — Lint temizliği**
- `dev/profile_unit_tests.rb` + `dev/run_unit_once.rb`: 17 offense → 0.

**E — Dokümantasyon**
- `dev/README.md`: stratifiye komutlar + profil akışı. Review dosyasına revizyon notu.

## Kabul Kriterleri
1. Çıplak `ruby test/unit/test_security_guard.rb` net aksiyonlanabilir hatayla durur (sessiz FAIL yok).
2. `bundle exec rake test:fast` 0 failure ve süresi ölçülür; SLOW 15 dosya hariçtir.
3. `bundle exec rake test:slow` 0 failure.
4. `rubocop` dev/ iki dosyada 0 offense.
5. Platform gating eklenmedi — karar ve kanıt bu dosyada belgelendi.
6. GitNexus impact (öncesi) + detect-changes (commit öncesi) akışı işletilir.
