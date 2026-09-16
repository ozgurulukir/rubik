# dev/ — Araştırma, Teşhis ve Doğrulama Script'leri

## Test stratifikasyonu (ölçüme dayalı, 2026-09-14)

Per-file profil: `bundle exec rake test:profile` → `_report/unit_profile.csv` (resumable; CSV sıkıştırma
resume-duplicate şişmesini önler — özet için `dev/analyze_profile.rb`).
Taze ölçüm (2026-09-16): 180 unit dosyası, gerçek serial ~33.3 dk (boot ~25.5 dk / gövdeler ~7.8 dk;
eski ~74 dk tahmini resume-duplicate artefaktıydı); >15s olan 16 dosya `SLOW_UNIT_FILES` (Rakefile,
0 stale / 0 missing senkron).

| Komut | Ne yapar |
|---|---|
| `bundle exec rake` | default = `test:unit_once` + `test:integration` — ~8.1 dk (2026-09-16, N=4 pilot konfigürasyonu; eski tam serial ~33 dk) |
| `bundle exec rake test` | tam serial referans koşumu (değişmedi; karşılaştırma/kas belleği) |
| `bundle exec rake test:fast` | unit eksi 16 yavaş dosya — hızlı geri bildirim (184s) |
| `bundle exec rake test:slow` | yalnız 16 yavaş dosya (ayrık koşum, 248s) |
| `bundle exec rake test:unit_once` | tüm unit tek proses (boot 1×) — 552.7s / 1617 runs |
| `bundle exec rake test:parallel[4]` | proses-bazlı pilot, 4 worker — 195.9s, **%64.5 kazanç** (opt-in; N=6/8 timing-fragil) |
| `bundle exec rake test:profile` | per-file CSV profili |
| `ruby dev/analyze_profile.rb` | CSV özeti + SLOW listesi senkron denetimi |

**Kritik:** Suite her zaman `bundle exec` ile koşulmalı. Ruby 4.0 default gem'i minitest 6.0
(`minitest/mock` yok → sahte FAIL); `test/test_helper.rb` bunu fail-closed yakalar.

Bu dizin, performans/davranış incelemeleri sırasında yazılan ve **ileride
tekrar ihtiyaç duyulabilecek** bağımsız script'leri içerir. Üretim kodu
değildir; `rake test` ve gem yüklemesi bu dosyaları kullanmaz.

Tüm script'ler depo kökünden çalışır ve mutlak yol gerektirmez:

```bash
ruby dev/bench_context_scan.rb [root]      # Scanner/grep/list/AST gecikmeleri + rg/git baseline
ruby dev/bench_ast_extractors.rb [root]    # Extractör maliyet ayrıştırması (stat/sha/dil başına/thread denemesi)
ruby dev/bench_native_tools.rb [root]      # rg/sg/fd/JSON karşılaştırmaları
ruby dev/bench_rg_flag_cost.rb [count]     # rg bayrak maliyetleri (-j1, prune glob'ları)
ruby dev/debug_rg_stdin_trap.rb            # Windows rg stdin tuzağı kanıt reproduksiyonu (Plan 52 §2.4)
ruby dev/sim_finish_duplicate.rb           # Batch finish çift-baskı kanıtı (düzeltme sonrası: tek baskı)
ruby dev/sim_streaming_finish.rb           # Streaming finish tek-baskı doğrulaması
ruby dev/gen_synth_repo.rb [root] [count]  # Sentetik depo üreteci (benchmark girdisi)
ruby dev/verify_allowlist.rb               # Komut allowlist kapısı kabul sondaları (Paket A: 8/8 PASS beklenir)
ruby dev/run_unit_parallel.rb 4            # test:parallel pilotunun doğrudan koşumu (worker sayısı argümanı)
ruby dev/analyze_profile.rb                # unit_profile.csv özeti + SLOW_UNIT_FILES senkron denetimi
ruby dev/profile_unit_tests.rb [glob]      # test:profile'nin çekirdeği: per-file süre ölçümü
ruby dev/run_unit_once.rb                  # test:unit_once çekirdeği; RUBIK_TEST_SLICE=i/N dilim desteği
```

## Ortam notu (Windows — review Öneri 5)

İnceleme makinesinde `bash`/WSL bozuk durumdadır (`execvpe(/bin/bash) failed`); tüm script'ler
**cmd-uyumlu** tutulmalıdır (POSIX-only `&&` zincirleri, heredoc, `$(...)` kullanmayın) ya da
cmd'de ayrı satırlar hâlinde koşulun. Rubik'in `run_command` koruması cmd/bash/pwsh'i komut
başına otomatik yönlendirir — sorun yalnızca POSIX sözdizimi gerektiren script'lerde çıkar.
Yeni bir dev script'i eklerken bunu göz önünde bulundurun; aksi hâlde katkıda bulunanlar
"yalnızca bende çalışıyor" tuzağına düşer.

## İz bırakan bulgular

| Bulgu | Script | Sonuç |
| :--- | :--- | :--- |
| Windows'ta Open3 ile spawn edilen rg stdin'i arar, 0 sonuç döner | `debug_rg_stdin_trap.rb` | Çözüm: açık path argümanı + stdin kapatma (`NativeSearch`) |
| rg `-j 1` 3,5x yavaşlatır, prune glob'ları bedava | `bench_rg_flag_cost.rb` | Paralel rg + glob'lar tercih edildi (Plan 52 §9 D-2) |
| Extractör gövde dilimleme maliyeti parse'a yakın | `bench_ast_extractors.rb` | Tembel gövde (`BodyLoader`) kararı |
| Finish yolu nihai yanıtı iki kez basabiliyordu | `sim_finish_duplicate.rb`, `sim_streaming_finish.rb` | `res[:streamed]` gerçek durumu taşır; 🏁 tek satır |

Not: Bu script'ler biriktirici ölçüm için `benchmark/tool_latency.rb` ve
`!benchmark` kabul metriklerini (`Rubik::Benchmark::Runner`)_replace etmez;
onların yanında ayrıntılı teşhis aracıdır.
