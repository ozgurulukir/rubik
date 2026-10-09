# dev/ — Araştırma, Teşhis ve Doğrulama Script'leri

## Test stratifikasyonu (ölçüme dayalı)

Per-file profil: `bundle exec rake test:profile` → `_report/unit_profile.csv` (resumable; CSV sıkıştırma
resume-duplicate şişmesini önler — özet için `dev/analyze_profile.rb`).

Unit dosya sayısı hızla büyüyor (2026-09-16'da 180, 2026-10-06'da 297, 2026-10-09'da 319); aşağıdaki süreler
artık tarihlenmiş anlık ölçümlerdir — karşılaştırma yapmadan önce taze profil alın.
Son taze ölçüm (2026-10-06): `test:unit_once` 1445.7s / 2836 runs / 18366 assertions
(0'e inen bilinen timing flake'leri için aşağıdaki flake notuna bakın); `SLOW_UNIT_FILES`
>15s eşiğiyle 16 dosyada sabit (Rakefile; taze profille yeniden senkronlanmalı).

| Komut | Ne yapar |
|---|---|
| `bundle exec rake` | default = `test:unit_once` + `test:integration` — süreler süit büyüklüğüyle değişir; güncel sayılar için taze profil alın |
| `bundle exec rake test` | tam serial referans koşumu (değişmedi; karşılaştırma/kas belleği) |
| `bundle exec rake test:fast` | unit eksi 16 yavaş dosya — hızlı geri bildirim (184s @ 2026-09-16, 180 dosya) |
| `bundle exec rake test:slow` | yalnız 16 yavaş dosya (ayrık koşum, 248s @ 2026-09-16) |
| `bundle exec rake test:unit_once` | tüm unit tek proses (boot 1×) — 1445.7s / 2836 runs (2026-10-06, 297 dosya) |
| `bundle exec rake test:parallel[4]` | proses-bazlı pilot, 4 worker — 195.9s, %64.5 kazanç (2026-09-16 ölçümü; opt-in; N=6/8 timing-fragil) |
| `bundle exec rake test:profile` | per-file CSV profili |
| `ruby dev/analyze_profile.rb` | CSV özeti + SLOW listesi senkron denetimi |

**Kritik:** Suite her zaman `bundle exec` ile koşulmalı. Ruby 4.0 default gem'i minitest 6.0
(`minitest/mock` yok → sahte FAIL); `test/test_helper.rb` bunu fail-closed yakalar.

**Flake notu (2026-10-06):** Timing-eşikli testler (concurrency/AST-cache perf iddiaları)
makine yükü altında yanlış kırmızı verebilir — izole koşumda geçerler; karar için
`ruby dev/rerun_flaky.rb <dosya> [n]` kullanın. Ayrıca `test_mcp_client`, mock sunucuyu
`ruby -e <kod>` ile spawn eder; bu yolda makine durumuna duyarlı sessiz-takılma gözlemlendi
(mock kodu dosyadan koşunca sorunsuz — transport sağlıklı). Kırmızıysa önce izole tekrar alın.

Bu dizin, performans/davranış incelemeleri sırasında yazılan ve **ileride
tekrar ihtiyaç duyulabilecek** bağımsız script'leri içerir. Üretim kodu
değildir; `rake test` ve gem yüklemesi bu dosyaları kullanmaz.

Tüm script'ler depo kökünden çalışır ve mutlak yol gerektirmez:

```bash
ruby dev/bench_context_scan.rb [root]      # Scanner/grep/list/AST gecikmeleri + rg/git baseline
ruby dev/bench_ast_extractors.rb [root]    # Extractör maliyet ayrıştırması (stat/sha/dil başına/thread denemesi)
ruby dev/bench_ast_index.rb [root]         # AST indeks kurulum + tekrarlı lookup gecikmesi (extractör bazının indeks-seviyesi tamamlayıcısı)
ruby dev/bench_native_tools.rb [root]      # rg/sg/fd/JSON karşılaştırmaları
ruby dev/bench_rg_flag_cost.rb [count]     # rg bayrak maliyetleri (-j1, prune glob'ları)
ruby dev/debug_rg_stdin_trap.rb            # Windows rg stdin tuzağı kanıt reproduksiyonu
ruby dev/sim_finish_duplicate.rb           # Batch finish çift-baskı kanıtı (düzeltme sonrası: tek baskı)
ruby dev/sim_streaming_finish.rb           # Streaming finish tek-baskı doğrulaması
ruby dev/gen_synth_repo.rb [root] [count]  # Sentetik depo üreteci (benchmark girdisi)
ruby dev/verify_allowlist.rb               # Komut allowlist kapısı kabul sondaları (8/8 PASS beklenir)
ruby dev/verify_safe_probe.rb              # Safe-probe muafiyeti + audit-log mesaj varyantları doğrulaması
ruby dev/run_unit_parallel.rb 4            # test:parallel pilotunun doğrudan koşumu (worker sayısı argümanı)
ruby dev/analyze_profile.rb                # unit_profile.csv özeti + SLOW_UNIT_FILES senkron denetimi
ruby dev/profile_unit_tests.rb [glob]      # test:profile'nin çekirdeği: per-file süre ölçümü
ruby dev/run_unit_once.rb                  # test:unit_once çekirdeği; RUBIK_TEST_SLICE=i/N dilim desteği
ruby dev/rerun_flaky.rb <dosya> [n=5]      # Tek test dosyasını n taze proseste koşar; flake/timing yayılımı raporu
ruby dev/soak_lifecycle.rb [epochs=1000]   # Context/ComponentFiber yaşam döngüsü soak denetimi (Ω baseline dönüşü)
ruby dev/generate_tools_doc.rb             # TOOLS.md mekanik hücrelerini üretir (rake tools:doc'ın çekirdeği)
ruby dev/update_test_badge.rb              # Tam süiti koşup README test badge'ini gerçek sayılardan üretir (rake test:badge'in çekirdeği)
ruby dev/probe_default_guard.rb            # Default Guard politikası + RunCommandTool çıktı sondası
ruby dev/probe_guard_matrix.rb             # Guard sınıflandırıcı matrisi: sabit komut seti için PASS/BLOCK + gerekçe
ruby dev/probe_paste.rb                    # REPL paste tanı sondası (Reline stub'lı Shell bootu; kilitlenme fazını yerelleştirir)
ruby dev/probe_review.rb                   # Classifier davranış matrisi (bash -c / eval / env önek kalınlığı)
ruby dev/review_fix_check.rb               # İnceleme düzeltmeleri sonrası taze-göz doğrulama sondaları
```

## Ortam notu (Windows)

İnceleme makinesinde `bash`/WSL bozuk durumdaydı (`execvpe(/bin/bash) failed`); tüm script'ler
**cmd-uyumlu** tutulmalıdır (POSIX-only `&&` zincirleri, heredoc, `$(...)` kullanmayın) ya da
cmd'de ayrı satırlar hâlinde koşulun. Rubik'in `run_command` koruması cmd/bash/pwsh'i komut
başına otomatik yönlendirir — sorun yalnızca POSIX sözdizimi gerektiren script'lerde çıkar.
Yeni bir dev script'i eklerken bunu göz önünde bulundurun; aksi hâlde katkıda bulunanlar
"yalnızca bende çalışıyor" tuzağına düşer.

## İz bırakan bulgular

| Bulgu | Script | Sonuç |
| :--- | :--- | :--- |
| Windows'ta Open3 ile spawn edilen rg stdin'i arar, 0 sonuç döner | `debug_rg_stdin_trap.rb` | Çözüm: açık path argümanı + stdin kapatma (`NativeSearch`) |
| rg `-j 1` 3,5x yavaşlatır, prune glob'ları bedava | `bench_rg_flag_cost.rb` | Paralel rg + glob'lar tercih edildi |
| Extractör gövde dilimleme maliyeti parse'a yakın | `bench_ast_extractors.rb` | Tembel gövde (`BodyLoader`) kararı |
| Finish yolu nihai yanıtı iki kez basabiliyordu | `sim_finish_duplicate.rb`, `sim_streaming_finish.rb` | `res[:streamed]` gerçek durumu taşır; 🏁 tek satır |

Not: Bu script'ler biriktirici ölçüm için `benchmark/tool_latency.rb` ve
`rake bench` kabul metriklerini (`Rubik::Benchmark::Runner`) yerine geçmez;
onların yanında ayrıntılı teşhis aracıdır.
