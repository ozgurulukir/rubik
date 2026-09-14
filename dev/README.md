# dev/ — Araştırma, Teşhis ve Doğrulama Script'leri

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
```

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
