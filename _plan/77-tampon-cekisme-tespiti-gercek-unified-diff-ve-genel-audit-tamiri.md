# 📋 Plan 77: Tampon Çakışma Tespiti, Gerçek Unified Diff ve Genel Audit Tamirleri

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes
> **Durum:** 🔵 **Planlandı** · **Zorluk:** Orta–İleri · **Faz:** 6
> **İlgili Planlar:** [03](03-dosya-tamponu-snapshot-undo.md), [70](70-write-file-garbage-path-korumasi.md), [71](71-calisma-zamani-saglamlastirma-lsp-devre-kesici-buffer-thread-safety-ve-izole-testler.md), [73](73-arac-katmani-sertlestirme-kapsulleme-ve-hata-ayristirma.md), [75](75-reaktif-yapilandirma-gozlemcisi-sistem-geneli-knob-kablolamasi-ve-canli-rekonfigurasyon.md), [76](76-lsp-buffer-jit-senkronizasyonu-oturum-arac-kaydi-ve-modern-web-adaptoru.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

Tam kod tabanı audit'i (baseline: `rake test` 1.207 test / 7.098 assertion %100 yeşil, RuboCop 319 dosya 0 offense) sırasında saptanan bulgular tek semantik birimde toplanır.

### 1.1. Tampon Çakışma Tespiti Eksik (Plan 03 Görev 9 yarım)

- Plan 03 "Görev 9": `!apply` anında disk, snapshot tabanından beri değiştiyse çakışma bildirilmeli.
- Altyapı ilk commit'ten beri var (`@original_hashes`: manager.rb:32,144,154-157,242,252,266) ama **hiçbir yerde okunmuyor** — tüketici yok.
- Senaryo: ajan okur → edit yapar → bu arada kullanıcı/`git pull` diske yazar → `!apply` sessizce ezer → elle yapılan değişiklik kaybolur.

### 1.2. Sahte Unified Diff

- `Diff.build_hunk` (diff.rb:23-35) `@@ -1,N +1,M @@` header'ı ile **her satırı** `-`/`+` olarak basar → 500 satırlık dosyada 1 satırlık değişiklik ~1000 diff satırı üretir (LLM bağlam israfı).
- Tüketiciler: `diff_all` (manager.rb:214) → `apply_buffer`/`finish` araç çıktısı; `!diff` → `DiffViewer.render` (buffer.rb:27,32).

### 1.3. Oturum Kaydedicisi Sınırsız Bellek

- `recorder.rb:36` `@events = []` her olayı bellekte tutar; `read_history(limit=20)` yalnızca kuyruk okur → O(session) bellek israfı.

### 1.4. Sandbox "İzolasyon" Vaadi Danışmanlık Düzeyinde

- `process.rb:27-31`: `allow_network: false` yalnızca ölü proxy env'leri ayarlar; çocuk süreç `unset HTTP_PROXY` ya da ham soket ile aşar.
- `sandbox.driver: auto` docker/podman mevcutken bile process'e düşer.

### 1.5. LICENSE Eksik

- gemspec:14 `license = "MIT"` + files glob'unda "LICENSE" var ama diskte LICENSE dosyası yok.

---

## 🏛️ 2. Mimari Tasarım ve Çözüm Bileşenleri

### 2.1. Bileşen 1: `apply!` Çakışma Kapısı (Plan 03 Görev 9'un tamamlanması)

- `Manager#apply!` (manager.rb:227-260) döngüsünde her kirli yol için, yazmadan önce:
  ```ruby
  baseline = @original_hashes[rel_path]
  if baseline && File.exist?(full_path) &&
     Digest::SHA256.hexdigest(Rubik::Platform.normalize_newlines(File.read(full_path))) != baseline
    conflicts << rel_path   # yazma; skip
  end
  ```
- DRY: ortak özel yardımcı `disk_hash(rel_path)` — `write` (154-157) ve kapı ortak kullanır.
- Olay/çıktı yüzeyi:
  - `@event_bus&.emit(:buffer_apply_conflict, paths: conflicts)`
  - Araç/komut çıktısına `[CONFLICT] <path>: disk, son okumadan beri değişti — uygulanmadı. Dosyayı yeniden okuyup düzenleyin.`
- **Dönüş tipi korunur:** `apply!` yine uygulanan yolların dizisini döner (8 çağrı noktası doğrulandı: step_executor.rb:41,58,178; buffer.rb:44,52; agent_execution.rb:117,163; lifecycle.rb:34). Çakışanlar ayrı alan/event ile bildirilir.
- Yapılandırma: `buffer.on_external_modification` = `"skip"` (varsayılan, fail-safe) | `"overwrite"` — defaults.rb:52-58 bloğuna eklenir.
- `!apply` çıktısı: uygulanan + çakışan sayıları ayrı satırda.

### 2.2. Bileşen 2: Gerçek Unified Diff (`diff-lcs`)

* **Bağımlılık:** `Gemfile` + `gemspec` → `gem "diff-lcs", "~> 1.5"` (gerçek pure Ruby, MIT, CLI/işletim sistemi bağımsız).
* **`diff.rb` yeniden yazım:** `Diff.diff_lines(orig, new, path: nil, context: 3)` arayüzü; `Diff::LCS` motoru ve `Diff::LCS::Formatters::Unified` kullanılarak uygulanır. `--- a/<rel>` / `+++ b/<rel>` dosya başlıkları metnin başına eklenir.
* **Tüketiciler değişmez:** `string-in / string-out` arayüzü korunur (`diff_all`, `DiffViewer.render`).
* **DiffViewer uyumu:** Üretilen `@@ -l,c +l,c @@` hunk başlıkları ve `+` / `-` satır önekleri, mevcut `DiffViewer` renklendiricisi (`diff_viewer.rb:28-34`) ile tam uyumlu çalışır.
* **Testler:** `test_buffer_diff.rb` baştan yazılır:
* `@@ -l,c +l,c @@` hunk başlığı doğrulaması
* 3 satırlık context penceresi
* `+` ve `-` satır işaretleri
* `identical` (birebir aynı) içeriklerde `""` dönüşü
* `nil` / `empty` girdi toleransı
* Sondaki `\n` eksikliği durumu (trailing newline handling)

### 2.3. Bileşen 3: Recorder Bellek Üst Sınırı

- `@events` 500 ile sınırlanır (`MAX_RECENT_EVENTS = 500`); sınır aşımında `shift`.
- Tek yazım noktası: özel `push_event(event)` yardımcısı; `record_*` metotları ve `load_history` geri yükleme döngüsü (recorder.rb:99-105) buna geçer.
- JSONL diskte zaten tam kayıt; bellek kopyası yalnızca `read_history` kuyruğu için.

### 2.4. Bileşen 4: Sandbox İzolasyon Dürüstlüğü

- **(a) `auto` yükseltme:** `sandbox.driver: "auto"` → `docker` → `podman` → `process` önceliği; binary varsa container sürücü seçilir (TTY::Which veya `which` ile sonda).
- **(b) Şeffaflık satırı:** sandbox aktifken `run_command` aracı sonucuna tek satır eklenir:
  - Container: `🔍 Isolation: container (docker, network=none) — strong`
  - Process: `🔍 Isolation: process (advisory-only network guard) — weak`
- Container sürücüsü zaten `--network none` ile sert izolasyon sağlar; proxy-env hilesi orada ek kalkan olarak kalır.

### 2.5. Bileşen 5: LICENSE Dosyası

- MIT LICENSE dosyası eklenir; telif: `2026 Rubik Team` (gemspec `spec.authors` ile uyumlu).

### 2.6. Ek Bileşen 6: Guard Deseni Sertleştirme + Baypas Regresyon Testleri

- `guard.rb:22` `rm\s+-rf\s+/` boşlukları: `rm -fr /`, `rm -rf /*` yakalanmıyor. Yeni desen:
  `%r{rm\s+(-\w+\s+)*(-\w*r\w*f\w*|-\w*f\w*r\w*)\s+(--\s+)?/(\s|$)}` (+ glob varyantı).
- Ek desenler: `dd if=`, `mkfs`.
- Test politikası: belgelenmiş her desen için blok-testi + bilinen baypas regresyonları (`rm -fr /`, `rm -rf /*`).

### 2.7. Audit Dipnotu (düşürülen bulgu)

- LSP istek zaman aşımı: `client.rb:319 send_request(method, params, timeout: 5)` mevcut — Plan 71'de çözülmüş; bulgu listeden çıkarıldı.

---

## 📋 3. Uygulama Adımları & Değişecek Dosyalar

1. **`lib/rubik/buffer/manager.rb` + `lib/rubik/config/defaults.rb`:** çakışma kapısı + `disk_hash` yardımcısı + `buffer.on_external_modification` kolu.
2. **`Gemfile` + `rubik.gemspec` + `lib/rubik/buffer/diff.rb`:** diffy bağımlılığı ve gerçek unified diff.
3. **`lib/rubik/session/recorder.rb`:** 500 olay üst sınırı + `push_event` yardımcısı.
4. **`lib/rubik/sandbox/driver.rb` (+ runner/tools kablosu):** auto-upgrade çözümlemesi + izolasyon şeffaflık satırı.
5. **`LICENSE` (yeni) + `rubik.gemspec`:** MIT metni.
6. **`lib/rubik/security/guard.rb`:** sertleştirilmiş desenler.
7. **`lib/rubik/repl/commands/buffer.rb` + `lib/rubik/tools/builtins/lifecycle.rb`:** `[CONFLICT]` çıktı satırı.
8. **Testler:** `test/unit/test_buffer_apply_conflict.rb` (yeni), `test_buffer_diff.rb` (yeniden), `test_session_recorder.rb` (sınır testi), `test_sandbox_isolation_disclosure.rb` (yeni), `test_security_guard.rb` (baypas regresyonları).

---

## 🛡️ 4. Kalite ve Hijyen Garantileri

- **Spatiotemporal Protokol Uyumu:** kapı `apply!` içinde; event emit + config okuması tek semantik noktada, ters etkisi yok.
- **Geriye Dönük Uyumluluk:** `apply!` dönüş tipi ve tümden davranış yalnızca çakışma durumunda değişir (fail-safe `skip`); mevcut 1.207 test yeşil kalmalı.
- **GitNexus Notu:** `apply!` upstream risk `UNKNOWN` (8 çağrı noktası index dışı) — metin araması ile 8 çağrı noktası doğrulandı; dönüş tipi korunarak risk düşürüldü.

---

## 🎯 5. Doğrulama ve Kabul Denetimi

- **Beklenen test dosyaları:** `test_buffer_apply_conflict.rb` (4 senaryo: dış değişim→skip+disk bozulmadan; dış değişim yok→normal+taban yenilenir; disk silinmiş→yeniden oluşturur; hiç okunmamış→serbest).
- **Kabul:** `bundle exec rake test` %100 yeşil; `rubocop` 0 offense; `!diff` çıktısında gerçek hunk'lar; LICENSE `gem build` ile pakete girer; `rm -fr /` guard'da yakalanır.
- **Güncellenecek İndeks:** `_plan/00-index.md` → satır 91'e Plan 77 satırı + ASCII akış diyagramına `77` düğümü.
