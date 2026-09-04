# 📋 Plan 76: LSP Tam Zamanında (JIT) Buffer Senkronizasyonu, Oturum Araç Kütüğü, Modern Web Adaptörü (Node/TS/Vue) ve Halüsinasyon Kırıcı Teşhis Hattı

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** İleri · **Faz:** 6 (Gelişmiş Ajan Ergonomisi, Çok Dilli Destek & Çalışma Zamanı Gözlemlenebilirliği)  
> **İlgili Planlar:** [13](13-sandbox-izolasyon.md), [29](29-lsp-derin-entegrasyonu-tanilama-ve-reaktif-geri-bildirim.md), [34](34-spatiotemporal-oturum-kaliciligi-ve-aninda-hafiza-yukleme.md), [48](48-harici-erisim-izinli-dizinler-ve-sifir-ast-sandbox-guvenlik-kapisi.md), [56](56-lsp-arka-plan-yonetimi-ve-reaktif-tanilama.md), [58](58-elm-tarzi-sistem-hatalari-utf8-bagisikligi-ve-hata-toleransli-tarama.md), [61](61-oturum-surekliligi-ve-hafiza-yonetimi.md), [73](73-arac-katmani-sertlestirme-kapsulleme-ve-hata-ayristirma.md), [74](74-endustri-standardi-sse-stream-reasoning-ve-iletisim-hatti.md), [75](75-reaktif-yapilandirma-gozlemcisi-sistem-geneli-knob-kablolamasi-ve-canli-rekonfigurasyon.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

Gerçek dünya karmaşık bir Vue 3 + TypeScript projesinde (`~/Projects/ipc-cost-tbfs-qwen-vue`) gerçekleştirilen çalışma ve oturum kaydı (`session_20260904_205623_140670_439.jsonl`) derinlemesine analiz edildiğinde, Rubik'in otonom çalışma deneyimini doğrudan etkileyen ve ciddi zaman/token kaybına yol açan 5 kritik mimari açık saptanmıştır:

### 1.1. LSP ↔ Bellek İçi Tampon (In-Memory Buffer) Desenkronizasyonu ve Halüsinasyon Tetikleyicisi
- **Mevcut Durum:** Model yeni veya değiştirilen bir dosyayı (`lsp-probe.ts`) hafızada oluşturduğunda, dosya henüz diske yazılmamıştır (`Buffer::Manager` içindedir). Model `lsp_hover` veya `lsp_diagnostics` çağırdığında, dil sunucusu (`tsserver`) disk tabanlı çalıştığı ve dosya için `textDocument/didOpen` / `didChange` bildirimi almadığı için **~1 ms'de boş yanıt** döner.
- **Tehlikeli Geri Besleme Döngüsü:** Model `repair_runtime_service` çalıştırdığında araçtan *"✨ Successfully verified and promoted runtime service... zero downtime"* mesajı alır. Sunucunun ayakta olduğundan emin olan model, boş dönen yanıtları Rubik'in mimari kusuru sanarak *"Rubik'in tool köprüsü eski bağlantıda kaldı"* şeklinde **yanlış bir teşhis (halüsinasyon)** üretir ve kullanıcıdan terminalde gidip `!lsp restart typescript` çalıştırmasını ister (440k token ve 10+ dakika israf).
- **İhtiyaç:** LSP araçları (`lsp_hover`, `lsp_definition`, `lsp_references`, `lsp_diagnostics`), sorgulanan dosya `Buffer::Manager`'da kirli veya yeni ise, sorguyu göndermeden **hemen önce** dosyayı `textDocument/didOpen` veya `didChange` ile LSP sunucusuna otomatik iletmeli (JIT Buffer Sync); boş yanıtlarda ise Elm-tarzı teşhis ipucu sağlamalıdır.

### 1.2. Oturum Kaydında Araç Çağrılarının Kaybolması (`session.jsonl` Boşluğu)
- **Mevcut Durum:** [`Rubik::Session::Recorder`](file:///home/aristo/Projects/rubik/lib/rubik/session/recorder.rb) içinde `record_tool_call` ve `record_tool_result` metotları bulunmasına rağmen, [`Rubik::REPL::Shell#on_step`](file:///home/aristo/Projects/rubik/lib/rubik/repl/shell.rb#L444) bu event'leri `Recorder`'a hiç iletmemektedir.
- **Sonuç:** Oturum dosyalarında sadece `user_turn`, `command` ve final `assistant_response` yer almakta; modelin onlarca adımda gerçekleştirdiği dosya okuma/yazma, git, test ve linter adımları tamamen kaybolmaktadır.

### 1.3. Modern Web Adaptörü Eksikliği (Node / TS / JS / Vue)
- **Mevcut Durum:** [`lib/rubik/adapter/`](file:///home/aristo/Projects/rubik/lib/rubik/adapter/) altında yalnızca `ruby`, `python`, `go`, `rust`, `c`, `zig` adaptörleri vardır. JavaScript/TypeScript/Node için hiçbir adaptör bulunmamaktadır.
- **Sonuç:** `run_tests` aracı ve REPL `!test` komutu TS/JS/Vue projelerinde `"No adapter available for language 'typescript'"` hatası vererek çökmekte; model testleri mecburen ham kabuk komutlarıyla (`run_command("npm run test:run")`) çalıştırmak zorunda kalmaktadır.

### 1.4. Vue.js Desteğinin Eksikliği
- **Mevcut Durum:** `EXTENSION_MAP` içinde `.vue` uzantısı tanımlı değildir. `DEFAULT_CONFIG["lsp"]["servers"]` ve `Discovery::LSP_CANDIDATES` içinde Vue language server (`@vue/language-server`, `vue-language-server`, `vls`) yer almamaktadır.

### 1.5. Ajanın `!lsp` Komutunu Yönetmesinin Engellenmesi ve Sabitlenmiş Yardım Metni
- **Mevcut Durum:** `!lsp` komutu varsayılan `audience: :user` olarak tescillendiğinden ajan `exec_repl_command('!lsp start')` yapamamakta, kullanıcıyı manuel işlem yapmaya zorlamaktadır. Ayrıca `!lsp start` çıktısı `<go|rust|zig|c|python|ruby>` şeklinde sabit kodlanmıştır.
- **İkili Ağ Yapılandırması:** `network.allow` ve `sandbox.allow_network` arasındaki kopukluk, kullanıcı ve model için mükerrer komut çalıştırma zorunluluğu yaratmaktadır.

---

## 🏛️ 2. Mimari Tasarım ve Çözüm Bileşenleri

```
                                  ┌────────────────────────┐
                                  │   LSP Query Request    │
                                  │ (hover/definition/diag)│
                                  └───────────┬────────────┘
                                              │
                                              ▼
                             ┌─────────────────────────────────┐
                             │ File in BufferManager & Dirty?  │
                             └───────┬─────────────────┬───────┘
                                     │ Evet            │ Hayır
                                     ▼                 │
                      ┌─────────────────────────────┐  │
                      │ JIT sync_buffer_file        │  │
                      │ (textDocument/didOpen|Change│  │
                      └──────────────┬──────────────┘  │
                                     │                 │
                                     ▼                 ▼
                             ┌─────────────────────────────────┐
                             │    Send Request to LSP Client   │
                             └───────────────┬─────────────────┘
                                             │
                                             ▼
                             ┌─────────────────────────────────┐
                             │ Empty response & file dirty?    │
                             └───────┬─────────────────┬───────┘
                                     │ Evet            │ Hayır
                                     ▼                 ▼
                      ┌─────────────────────────────┐ ┌────────────────┐
                      │ Append Elm Diagnostic Hint  │ │ Return Clean   │
                      │ ("Apply buffer to disk...") │ │ LSP Response   │
                      └─────────────────────────────┘ └────────────────┘
```

### 2.1. Bileşen 1: Tam Zamanında (JIT) LSP-Buffer Senkronizasyonu & Teşhis İpucu
- [`Rubik::LSP::Manager`](file:///home/aristo/Projects/rubik/lib/rubik/lsp/manager.rb):
  - `sync_buffer_file_if_needed(file_path, buffer_manager)`: Dosya tamponda varsa ve açık değilse veya kirliyse `sync_buffer_file(file_path, content)` çağrılır.
- [`LSPHoverTool`](file:///home/aristo/Projects/rubik/lib/rubik/tools/builtins/lsp.rb), [`LSPDefinitionTool`](file:///home/aristo/Projects/rubik/lib/rubik/tools/builtins/lsp.rb), [`LSPDiagnosticsTool`](file:///home/aristo/Projects/rubik/lib/rubik/tools/builtins/lsp.rb):
  - `execute` başında `buffer_manager` üzerinden JIT senkronizasyon tetiklenir.
  - Yanıt boş döndüğünde, eğer dosya tamponda kirliyse Elm-tarzı empatik yönlendirme eklenir:
    `"No hover information available at ...\n\n💡 Tip: This file has unapplied in-memory buffer modifications. If the language server relies on disk indexing, call 'apply_buffer' to persist changes to disk."`

### 2.2. Bileşen 2: Oturum Kütüğü Araç Entegrasyonu (`shell.rb`)
- [`Rubik::REPL::Shell#on_step`](file:///home/aristo/Projects/rubik/lib/rubik/repl/shell.rb):
  - `case step_info[:type]&.to_sym`:
    - `:tool_call` -> `@recorder&.record_tool_call(step_info[:tool], step_info[:args], call_id: step_info[:call_id])`
    - `:tool_result` -> `@recorder&.record_tool_result(step_info[:tool], step_info[:output], status: step_info[:status] || :ok, call_id: step_info[:call_id])`
  - Bu sayede oturum JSONL dosyası tüm araç adımlarını, girdi argümanlarını ve çıktılarını eksiksiz yakalar.

### 2.3. Bileşen 3: Modern Web Adaptörü (`NodeAdapter`)
- [`lib/rubik/adapter/node.rb`](file:///home/aristo/Projects/rubik/lib/rubik/adapter/node.rb) oluşturulacak:
  - `NodeAdapter < BaseAdapter`
  - Desteklenen diller: `"javascript"`, `"typescript"`, `"node"`, `"vue"`.
  - `resolve_test_cmd(root_dir)`:
    - `package.json` içindeki `"scripts"` okunur: `"test:run"`, `"test"`, `"test:unit"` vb. önceliklendirilir (vitest/jest watch moduna girmemesi için `--run` veya `test:run` önceliği).
    - `pnpm-lock.yaml` -> `pnpm test`, `yarn.lock` -> `yarn test`, `bun.lockb` -> `bun test`, `package-lock.json` -> `npm test`.
  - `check_syntax(file_path)`: Node/TypeScript sözdizim denetimi (`node --check` veya `npx eslint --no-ignore` / `npx tsc --noEmit`).
  - `format_code(file_path)`: `prettier --write` veya `biome format --write`.
  - [`lib/rubik/adapter/registry.rb`](file:///home/aristo/Projects/rubik/lib/rubik/adapter/registry.rb) içine `"javascript"`, `"typescript"`, `"node"`, `"vue"` için `NodeAdapter.new` kaydı.

### 2.4. Bileşen 4: Vue.js Desteği & Genişletilmiş Dil Haritası
- [`Rubik::LSP::Manager::EXTENSION_MAP`](file:///home/aristo/Projects/rubik/lib/rubik/lsp/manager.rb):
  - `".vue" => "vue"` eklenmesi.
- [`lib/rubik/config/defaults.rb`](file:///home/aristo/Projects/rubik/lib/rubik/config/defaults.rb):
  - `DEFAULT_CONFIG["lsp"]["servers"]["vue"] = "vue-language-server --stdio"`
- [`Rubik::Runtime::Discovery`](file:///home/aristo/Projects/rubik/lib/rubik/runtime/discovery.rb):
  - `LSP_CANDIDATES["vue"] = ["vue-language-server --stdio", "@vue/language-server --stdio", "vls"]`
  - `TEST_RUNNER_MARKERS["vue"] = ...`

### 2.5. Bileşen 5: `!lsp` Komutu ve Ağ Senkronizasyonu
- [`lib/rubik/repl/commands/lsp.rb`](file:///home/aristo/Projects/rubik/lib/rubik/repl/commands/lsp.rb):
  - `audience: :both` ile ajanın `exec_repl_command('!lsp start <lang>')` çalıştırmasına izin verilmesi.
  - `Usage: !lsp start <#{supported_languages.join('|')}>` ile dinamik liste sunulması.
- [`lib/rubik/repl/config_wiring.rb`](file:///home/aristo/Projects/rubik/lib/rubik/repl/config_wiring.rb):
  - `network.allow` değiştiğinde `sandbox.allow_network` değerini de reaktif senkronize etme.

---

## 📋 3. Uygulama Adımları & Değişecek Dosyalar

1. **`lib/rubik/adapter/node.rb` & `lib/rubik/adapter/registry.rb`:**
   - `NodeAdapter` sınıfının oluşturulması ve Registry'ye `"typescript"`, `"javascript"`, `"node"`, `"vue"` dillerinin eklenmesi.
2. **`lib/rubik/runtime/discovery.rb` & `lib/rubik/config/defaults.rb`:**
   - Vue dili için LSP ve test runner adaylarının eklenmesi.
3. **`lib/rubik/lsp/manager.rb` & `lib/rubik/lsp/client.rb`:**
   - `EXTENSION_MAP`'e `.vue` eklenmesi.
   - `sync_buffer_file_if_needed(file_path, buffer_manager)` metodunun eklenmesi.
4. **`lib/rubik/tools/builtins/lsp.rb`:**
   - `LSPDiagnosticsTool`, `LSPHoverTool`, `LSPDefinitionTool` sınıflarına `buffer_manager:` parametresinin bağlanması, JIT senkronizasyonu ve Elm-tarzı teşhis ipucu eklenmesi.
5. **`lib/rubik/repl/commands/lsp.rb`:**
   - `audience: :both` ve dinamik dil listesi desteği.
6. **`lib/rubik/repl/shell.rb`:**
   - `on_step` hook'unda `:tool_call` ve `:tool_result`'ın `@recorder`'a iletilmesi.
7. **`lib/rubik/repl/config_wiring.rb`:**
   - `network.allow` ↔ `sandbox.allow_network` senkronizasyon hook'u.
8. **Test Dosyası:**
   - `test/unit/test_lsp_jit_buffer_sync_and_web_adapter.rb` test dosyasının oluşturulması (Node adapter, LSP JIT sync, Elm diagnostics, recorder tool calls, vue mapping).

---

## 🛡️ 4. Kalite ve Hijyen Garantileri

- **Spatiotemporal Protokol Uyumu:** Tüm servisler ve dinleyiciler LIFO stack (`ctx.on_dispose`) üzerinden geri alınabilir (revertible).
- **Satır Sayısı Limitleri:**
  - `loop.rb` <= 350 satır
  - `shell.rb` <= 620 satır
  - Builtin araç etki alanı dosyaları < 300 satır
- **Geriye Dönük Uyumluluk:** Mevcut test süitinin tamamı (1,207 test) %100 yeşil; RuboCop 0 hata ile geçmektedir.

---

## 🎯 5. Doğrulama ve Kabul Denetimi (Audit & Acceptance)

- **Test Sonuçları:** `test/unit/test_lsp_jit_buffer_sync_and_web_adapter.rb` (20 run, 91 assertion) ve tüm test süiti (`bundle exec rake test`: 1,207 run, 7,098 assertion, 0 failure, 0 error) %100 yeşil.
- **RuboCop:** 319 dosya denetlendi, 0 hata/offense.
- **Satır Sayısı Denetimleri:**
  - `lib/rubik/repl/shell.rb`: 617 satır (<= 620 satır kuralı sağlandı)
  - `lib/rubik/tools/builtins/lsp.rb`: 282 satır (< 300 satır kuralı sağlandı)
  - `lib/rubik/config/defaults.rb`: 149 satır (< 150 satır kuralı sağlandı)
- **Modülerlik & Davranış Kontrolleri:**
  - `Buffer::Manager#dirty?`: Argümansız ve `path` parametreli tam uyumluluk, `@dirty_files` ve in-memory tampon/disk varlık kontrolü.
  - `NodeAdapter`: Lockfile çözümlemeleri (pnpm/yarn/bun/npm), vitest watch koruması (`scripts["test:run"]` önceliği), syntax/format denetimleri.
  - `LSP::Manager` & `Client`: Vue language server eşlemeleri, `sync_buffer_file_if_needed` JIT senkronizasyonu.
  - Araç Katmanı: `LSPDiagnosticsTool`, `LSPHoverTool`, `LSPDefinitionTool` JIT senkronizasyonu ve kirli dosyalarda Elm-tarzı `buffer_tip` geri bildirimi.
  - REPL & Yapılandırma: `!lsp` komutu için `audience: :both` ve dinamik dil listesi; `network.allow` ↔ `sandbox.allow_network` iki yönlü reaktif senkronizasyonu.
