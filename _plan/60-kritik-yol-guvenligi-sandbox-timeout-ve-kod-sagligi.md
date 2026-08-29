# 60 — Kritik Yol Yazma Güvenliği (Guard Entegrasyonu), Dinamik Sandbox Timeout ve Kod Sağlığı İyileştirmeleri

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Onaylandı (Review Tamamlandı)** · **Zorluk:** Orta · **Faz:** 6 (Güvenlik Sertleştirmesi, Sistem Dayanıklılığı & Kod Sağlığı)  
> **İlgili Planlar:** [03](03-dosya-tamponu-snapshot-undo.md), [12](12-guvenlik-diff-onay.md), [13](13-sandbox-izolasyon.md), [19](19-container-wasm-sandbox-guvenligi.md), [24](24-kendi-kendini-gelistiren-arac-sentezi.md), [41](41-repl-komut-ve-hizmet-dagilimi-domain-driven-command-decoupling.md), [48](48-harici-erisim-izinli-dizinler-ve-sifir-ast-sandbox-guvenlik-kapisi.md), [49](49-tam-kapsamli-cross-platform-ve-windows-uyumluluk-mimarisi.md), [54](54-step-executor-ve-arac-alani-moduler-refaktoru.md), [56](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md), [57](57-sistem-saglamligi-birlesik-tanilama-fuzyonu-e2e-ve-thread-safety.md), [58](58-elm-tarzi-sistem-hatalari-utf8-bagisikligi-ve-hata-toleransli-tarama.md), [59](59-cekirdek-guvenligi-sentez-sandbox-bare-rescue-ve-moduler-testler.md)  
> **Kapsam:** `lib/rubik/security/guard.rb`, `lib/rubik/buffer/manager.rb`, `lib/rubik/sandbox/runner.rb`, `lib/rubik/sandbox/driver/process.rb`, `lib/rubik/llm/client.rb`, `lib/rubik/config.rb`, `lib/rubik/repl/commands/agent.rb` (dekompozisyon), `lib/rubik/repl/commands/agent_models.rb` (yeni), `lib/rubik/repl/commands/agent_context.rb` (yeni), `lib/rubik/repl/commands/agent_execution.rb` (yeni), `test/unit/test_critical_write_guard.rb` (yeni)

---

## 🎯 1. Problem ve İhtiyaç Analizi

Canlı oturum incelemesi ve dış güvenlik denetimi sonucunda tespit edilen 5 temel bulgu ve mimari iyileştirme:

### 1.1. P1 (Güvenlik) — Kritik Yol Yazma Korumasının Gerçek Yazma Yoluna Bağlanması
- **Gözlem:** `Rubik::Security::Guard#verify_path_write!` metodu (`.env*`, `.git/**`, `secrets.*`, `*.pem`, `*.key`, `id_rsa*` gibi hassas dosyaları engelleyen kural seti) sadece doğrudan çağrılmaktaydı; gerçek araç yürütme yolunda (`WriteFileTool` / `ReplaceFileContentTool` ➔ `Buffer::Manager#write` / `apply!`) bu kontrol zorunlu tutulmamaktaydı.
- **Çözüm:** `Buffer::Manager` içine `Guard` enjekte edilerek `sanitize_path(..., for_write: true)` aşamasında `verify_path_write!` zorunlu kılınmalı; kritik dosyalara müdahale `BlockedWriteError` / `InvalidPathError` ile durdurulmalıdır.

### 1.2. P2 (Hata) — Sandbox Komut Zaman Aşımının (Timeout) Sessizce Ezilmesi
- **Gözlem:** `Sandbox::Runner#run` metodunda `timeout = (@config && @config.fetch("sandbox.timeout_seconds", timeout)) || timeout` yazımı sebebiyle, varsayılan yapılandırmada yer alan 15 saniyelik değer (`sandbox.timeout_seconds: 15`), çağrıcının `run(cmd, timeout: 300)` şeklinde açıkça talep ettiği zaman aşımını sessizce ezmekte ve uzun test/derleme komutlarının 15. saniyede öldürülmesine yol açmaktaydı.
- **Çözüm:** Çağrıcının açıkça belirttiği `timeout` değeri (`timeout: N`) yapılandırmadan öncelikli olmalı; yalnızca belirtilmediğinde (`timeout: nil`) yapılandırma değerine geri dönülmelidir:
  `effective_timeout = timeout || (@config && @config.fetch("sandbox.timeout_seconds", 15)) || 15`.

### 1.3. P3 & P4 (Doğruluk & Sınırlar) — Süreç Yalıtım Seviyesi Dürüstlüğü
- **Gözlem:** `ProcessDriver` için `isolation_level` değeri `"rlimit+env_proxy"` olarak dönmekteydi; ancak kod tabanında herhangi bir `rlimit` (özellikle Windows'ta) uygulanmamaktadır.
- **Çözüm:** `ProcessDriver` için yalıtım seviyesi dürüstçe `"process (env_proxy)"` olarak etiketlenmeli; süreç sürücüsünün savunma-derinliği (best-effort) olduğu, tam izolasyonun Docker/Podman/WASM ile sağlandığı dokümante edilmelidir.

### 1.4. P5.1–P5.4 (Dayanıklılık & Gizlilik) — SSE Akış Temizliği, Config Dosya İzinleri (`0600`)
- `SSEParser#feed` içinde `chunk_bytes` UTF-8 dönüştürülürken geçersiz bayt dizilimlerinin `Encoding::CompatibilityError` oluşturmaması için `.scrub` uygulanmalıdır.
- API anahtarlarını barındıran `~/.rubik/config.yml` kaydedilirken `File.chmod(0o600, path) rescue nil` ile dosya izinleri sadece kullanıcıya özel kılınmalıdır.

### 1.5. P5.5 (Kod Sağlığı) — `repl/commands/agent.rb` Modülerleştirilmesi (< 300 Satır Kuralı)
- 863 satırlık monolitik `lib/rubik/repl/commands/agent.rb` dosyası, domain-driven yaklaşımla odaklı alt modüllere (`agent_models.rb`, `agent_context.rb`, `agent_execution.rb`) bölünmeli ve her dosya 300 satır sınırının altına çekilmelidir.

---

## 🧩 2. Tasarım Kararları (Design Decisions)

### D-1: `Buffer::Manager` ➔ `Guard` Entegrasyonu
[`lib/rubik/buffer/manager.rb`](file:///C:/Github/rubik/lib/rubik/buffer/manager.rb):
- `Buffer::Manager.new(root_dir: Dir.pwd, guard: nil, ...)` yapıcı metodunda `@guard = guard || Rubik::Security::Guard.new` tanımlanır.
- `sanitize_path(path, for_write: true)` çağrıldığında `@guard.verify_path_write!(rel_path)` çalıştırılır; kritik yollar `BlockedWriteError` / `InvalidPathError` ile anında engellenir.

### D-2: Dinamik Timeout Önceliklendirmesi
[`lib/rubik/sandbox/runner.rb`](file:///C:/Github/rubik/lib/rubik/sandbox/runner.rb):
- `Sandbox::Runner#run(cmd, timeout: nil, ...)`:
  ```ruby
  effective_timeout = timeout || (@config && @config.fetch("sandbox.timeout_seconds", 15)) || 15
  ```
  Böylece `run_command(cmd, timeout: 300)` veya uzun testler asla 15s ile erken kesilmez.

### D-3: Dürüst İzolasyon Etiketi
[`lib/rubik/sandbox/runner.rb`](file:///C:/Github/rubik/lib/rubik/sandbox/runner.rb):
- `Sandbox::Runner#isolation_level`:
  - `docker` ➔ `"container (docker oci)"`
  - `podman` ➔ `"container (podman rootless)"`
  - `wasm` ➔ `"wasm / wasi sandbox"`
  - `process` ➔ `"process (env_proxy)"`

### D-4: Güvenli Config Dosya İzinleri (`0600`)
[`lib/rubik/config.rb`](file:///C:/Github/rubik/lib/rubik/config.rb):
- `Rubik::Config#store_for` ve kaydetme işlemlerinde, hedef dosya oluşturulduğunda veya güncellendiğinde POSIX/Windows uyumlu `File.chmod(0o600, target_path) rescue nil` uygulanır.

### D-5: `SSEParser` UTF-8 Scrubbing
[`lib/rubik/llm/client.rb`](file:///C:/Github/rubik/lib/rubik/llm/client.rb):
- `SSEParser#feed(chunk_bytes)`:
  ```ruby
  incoming = chunk_bytes.to_s.dup.force_encoding(Encoding::UTF_8)
  incoming = incoming.scrub unless incoming.valid_encoding?
  @buffer << incoming
  ```

### D-6: `agent.rb` Modüler Dekompozisyonu
- [`lib/rubik/repl/commands/agent_models.rb`](file:///C:/Github/rubik/lib/rubik/repl/commands/agent_models.rb): `!model`, `!models`, `!fast`, `!plan_model`, `!review_model`, `!providers` komutları.
- [`lib/rubik/repl/commands/agent_context.rb`](file:///C:/Github/rubik/lib/rubik/repl/commands/agent_context.rb): `!context`, `!compact`, `!budget`, `!goal`, `!plan` komutları.
- [`lib/rubik/repl/commands/agent_execution.rb`](file:///C:/Github/rubik/lib/rubik/repl/commands/agent_execution.rb): `!agent`, `!run`, `!auto_apply`, `!stream`, `!cancel`, `!step` komutları.
- [`lib/rubik/repl/commands/agent.rb`](file:///C:/Github/rubik/lib/rubik/repl/commands/agent.rb): Ana koordinatör olarak alt modülleri yükler ve REPL kabuğuna kaydeder (< 100 satır).

---

## 📋 3. Uygulama Adımları

- [ ] **Adım 1:** `lib/rubik/buffer/manager.rb` içine `Guard#verify_path_write!` çağrısının entegre edilmesi.
- [ ] **Adım 2:** `lib/rubik/sandbox/runner.rb` içinde dinamik timeout önceliğinin ve `isolation_level` etiketinin güncellenmesi.
- [ ] **Adım 3:** `lib/rubik/llm/client.rb` içinde `SSEParser#feed` metoduna `.scrub` eklenmesi.
- [ ] **Adım 4:** `lib/rubik/config.rb` içinde `0o600` dosya izinlerinin sağlanması.
- [ ] **Adım 5:** `lib/rubik/repl/commands/agent.rb` dosyasının `agent_models.rb`, `agent_context.rb` ve `agent_execution.rb` olarak 300 satır kuralına uygun şekilde bölünmesi.
- [ ] **Adım 6:** `test/unit/test_critical_write_guard.rb` birim test dosyasının oluşturulması.
- [ ] **Adım 7:** Test süitinin (`bundle exec rake test:fast`, `bundle exec rake test:unit`, `bundle exec rake test`) %100 yeşil koşulması.

---

## 🎯 4. Kabul Kriterleri

1. `WriteFileTool` veya `ReplaceFileContentTool` ile `.env`, `secrets.json`, `.git/config`, `id_rsa` gibi kritik dosyalara yazma girişimleri `BlockedWriteError` / `InvalidPathError` ile engellenmelidir.
2. `Sandbox::Runner#run(cmd, timeout: 60)` çağrıldığında 15s varsayılan yapılandırması yerine 60s zaman aşımı uygulanmalıdır.
3. `SSEParser` bozuk veya bölünmüş UTF-8 baytları aldığında exception fırlatmadan akışı sürdürmelidir.
4. `repl/commands/` altındaki tüm dosyalar 300 satır kuralına uymalıdır.
5. Tüm testler 0 failure, 0 error ile %100 yeşil geçmelidir.
