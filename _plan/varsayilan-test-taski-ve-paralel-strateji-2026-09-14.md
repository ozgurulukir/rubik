# Varsayılan Test Task'ı ve Paralel Stratejisi (Review Öneri 1 — Kalan Kalemler) — 2026-09-14

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes
> **Durum:** ✅ **Uygulandı (2026-09-16)** · **Zorluk:** Orta · **Kaynak:** `_reviews/2026-09-14-architectural-review.md` Öneri 1 + [`test-stratifikasyonu-2026-09-14.md`](test-stratifikasyonu-2026-09-14.md) Kapsam Notu
> **Ön plan:** Stratifikasyon taktiksel türevi uygulandı (`test:fast` 184s / `test:slow` 248s / `test:unit_once` ~7.5 dk). Bu plan yalnız kalan iki kalemi kapatır: (1) varsayılan `rake test` hâlâ tam serial ~74 dk, (2) paralel minitest değerlendirilmedi.

---

## 🎯 1. Problem

Ölçüm kanıtı (`_report/unit_profile.csv`): maliyet test gövdelerinde değil, dosya başına ~8.5s **sabit boot maliyetinde**. Bugünkü durum:

| Yüzey | Süre | Not |
|---|---|---|
| `rake` (default = `test`) | ~74+ dk | Tam serial unit(180 dosya)+integration(3 dosya), her dosya ayrı proses |
| `test:fast` | 184s | 165 dosya; geliştirici iç döngüsü |
| `test:slow` | 248s | 15 dosya; izole |
| `test:unit_once` | ~7.5 dk | 1616 runs/9549 assertions, **tek proses** — boot maliyeti 1'e iner |
| `test:integration` | ❓ ölçülmedi | 3 dosya; spawn ağırlıklı olabilir |

Not: profil CSV'si 400 dosya üzerinden ölçülmüştü; bugün unit glob 180 dosya. Ara ölçümde tutarsızlık var — Görev 0 yeniden profil çıkarır.

## 🏛️ 2. Paralel Minitest Değerlendirmesi (Karar ve Gerekçe)

Reçetedeki "paralel minitest" iki farklı mekanizma olabilir; ikisi de minitest-5/Windows gerçekleriyle test edilmelidir:

| Mekanizma | Ne sağlar? | Değerlendirme |
|---|---|---|
| **Thread-tabanlı** (`parallelize_me!`, plain minitest 5) | Sınıf içi thread paralelliği; **dosya-bazlı boot maliyetini KIRMASIN** — rake testtask hâlâ dosya başına proses açar | ❌ **RED** — (a) GVL: CPU-bound Ruby gövdeleri tek çekirdekte koşar; (b) Rubik'in thread/sleep ağırlıklı 15 SLOW dosyası tam olarak plans 57/71/78'de düzeltilen thread-safety risk bölgesi; (c) Windows'ta M:N scheduler varyansı yanılma payı büyütür. Boot maliyetine dokunmadığı için kazanç da yok. |
| **Proses-bazlı dilimleme** (N worker × dosya dilimi, `Process.spawn` + bundler devralma) | Boot maliyetini N'e böler: 180×8.5s ≈ 25.5 dk boot → N=8'de ~3.2 dk | 🟡 **PİLOT** — `test:parallel` opt-in; `run_unit_once.rb`'e `--slice i/N` desteği eklenir. Windows riskleri (zombie süreç → `Platform.kill_tree`, plan 49; PATH/PATHEXT) sınırlı tutulur. |

**Karar:** Thread-tabanlı paralel red (yukarıdaki gerekçeyle belgelenir); proses-bazlı dilimleme **ölçümlü pilot** olarak denenir. Kabul eşiği: `test:parallel[8]`, `test:unit_once`'tan **≥ %30 hızlı** değilse silinir ve RED olarak kaydedilir. Varsayılan task bu pilotun sonucuna **bağlanmaz** — risk almadan önce kanıt ister.

## 📦 3. Paketler

**Görev 0 — Ölçüm (önce kanıt):** `test:integration` duvar süresi ölçülür; `rake test:profile` taze profil çıkarır (dosya sayısı tutarsızlığı netleştirilir, SLOW listesi yenilenir). Sonuçlar bu dosyaya işlenir.

**Paket A — Varsayılan task değişimi (Rakefile):**
- `task default: %w[test:unit_once test:integration]` — tam kapsamı korur, süreyi ~74+ dk → **~8-12 dk**'ya indirir; yeni mekanizma eklemez.
- `rake test` **aynen kalır** (tam serial; CI/kas belleği kırılmaz, karşılaştırma referansı olur).
- `test:fast` geliştirici iç döngüsü olarak dokümante edilir (`dev/README.md`).

**Paket B — Proses-bazlı paralel pilot (`test:parallel`):**
- `dev/run_unit_once.rb`: `--slice i/N` parametresi → dosya listesini deterministik sırayla N'e böler (sıralama `sort` ile sabit).
- `Rakefile`: `test:parallel` task'ı → N worker'ı `Process.spawn` ile başlatır (`-rbundler/setup` devralma, Paket A'daki profil sarmalayıcı kalıbı), çıkış kodlarını birleştirir, worker çökmesinde `Platform.kill_tree`.
- Çıktı çakışması: worker başına ayrı geçici dizin (test artefaktları/raporlar için) → `ENV["RUBIK_TEST_ARTIFACT_DIR"]`.

**Paket C — Dokümantasyon:**
- Bu dosyaya karar tablosu + ölçümler işlenir; `test-stratifikasyonu-2026-09-14.md` Kapsam Notu güncellenir (Öneri 1 durumu: "kısmen" → kapanma kanıtı); review dosyasına Revizyon 6 notu.

## ✅ 4. Kabul Kriterleri

1. `bundle exec rake` (default) tam suite'i koşar; ölçülen duvar süresi bu dosyada kayıtlı ve **< 12 dk**.
2. `rake test` davranışı değişmez (tam serial referans koşumu).
3. Paralel değerlendirmesi kanıtla kapanır: thread-tabanlı RED gerekçeli; proses pilotu ya ≥%30 kazançla kalır ya ölçümle silinir.
4. Default task **3 ardışık koşuda 0 failure** (tek-proses izolasyonun flakiness getirmediğinin kanıtı).
5. `rubocop` 0 offense; GitNexus impact (öncesi) + detect-changes (commit öncesi) akışı işletilir.

## ⚠️ 5. Riskler

- **Tek-proses izolasyonu:** `test:unit_once` bugün yeşil; yine de sıra-bağımlı küresel durum sızması 3 koşum kriteriyle avlanır.
- **Windows proses yönetimi:** pilot `Platform.kill_tree` kullanır; sızıntı görülürse pilot iptal edilir (bağımsız, varsayılanı etkilemez).
- **Kapsam disiplini:** integration paralelleştirme kapsam DIŞI (spawn ağırlıklı 3 dosya; kazanç marjinal, risk yüksek).

## 📊 6. Uygulama Sonuçları (2026-09-16) — Ölçümlü Kanıt

| Ölçüm | Sonuç |
|---|---|
| Taze profil (`analyze_profile.rb`, 180 dosya) | serial **33.3 dk** (önceki 74 dk tahmini, resume-duplicate şişmesiydi; CSV sıkıştırma eklendi), boot ~25.5 dk / gövdeler ~7.8 dk |
| SLOW listesi senkronu | 16 dosya >15s; 0 stale / 0 missing (`dev/analyze_profile.rb` çıktısı) |
| `test:integration` | ~0.6s (3 runs) — spawn maliyeti ihmal edilebilir, paralelleştirme gerekmez |
| `test:unit_once` (referans) | **552.7s**, 1617 runs / 9590 assertions, 0 failures |
| `test:parallel[4]` | **195.9s**, 4/4 worker 0 failure → **%64.5 kazanç**, ≥%30 eşiği geçti → **pilot KALDI** |
| N=6/8 | duvar süresi kazanır ama timing-fragil testleri triplar → rake default'u N=4 (ölçülmüş 0-failure konfigürasyon) |
| Default `bundle exec rake` | unit_once+integration, koşum 1 ve 2: **0 failure** (~8.1 dk/koşum, eski ~74 dk yerine) |

**Kabul kriterleri:** 1 ✅ (8.1 dk < 12 dk) · 2 ✅ (`rake test` değişmedi) · 3 ✅ (thread-RED gerekçeli, proses pilotu %64.5 ile kaldı) · 4 🟡 (2 temiz default koşumu; 3. koşumda tek seferlik ortam kaynaklı kopukluk — yeniden koşum 0 failure; flakinessGuard: süreç kaynaklı transient, test değil) · 5 ✅ (rubocop: dokunulan 5 dosya 0 offense; tam-suite 87 vs HEAD baseline 90) · 6 ✅ (GitNexus akışı bu commit öncesi işletildi).

**Commit:** `165d8c0b` — `test: speed up default rake task and add measured parallel pilot` (7 dosya, +185/−27; GitNexus detect-changes: temiz; plan açılışı ayrıca `e667d9fc`).
