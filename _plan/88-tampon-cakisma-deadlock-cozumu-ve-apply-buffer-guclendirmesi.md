# Plan 88 — Tampon Çakışma Deadlock Çözümü, `apply_buffer` Güçlendirmesi ve Araç Ergonomisi

> **Durum:** 🟢 **Tamamlandı** (D-1..D-7 uygulandı, 0 offense)  
> **Zorluk:** Orta  
> **Faz:** 8  
> **Öneri Bölümü:** Tampon Bütünlüğü, Ajan Ergonomisi & Güvenli Yürütme  
> **İlgili Planlar:** [03](03-dosya-tamponu-snapshot-undo.md), [56](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md), [77](77-tampon-cekisme-tespiti-gercek-unified-diff-ve-genel-audit-tamiri.md), [85](85-tool-call-context-netlik-ve-cross-model-devam-surekliligi.md)

---

## 🎯 Motivasyon ve Gözlemlenen Sorun

`fff.cr` oturumunda (`session_20260911_004227_1191722_417.jsonl`), `internlm/intern-latest` modeli ile yapılan bir refactor çalışmasında kritik bir sistem kilitlenmesi (deadlock) yaşanmıştır:

1. **İlk Refactor Başarılı:** Model `write_file` ile `src/fff/icon_provider.cr` dosyasını düzenledi ve `apply_buffer` ile diske başarıyla yazdı.
2. **Harici Değişiklik:** Model hemen ardından kod kalitesini kontrol etmek amacıyla `run_command(command: "crystal tool format")` çalıştırdı. Crystal'ın formatlayıcısı `src/fff/icon_provider.cr` dosyasını diskte yeniden biçimlendirdi. Dosyanın diskteki SHA256 hash'i değişti.
3. **Test Hatası:** Model `crystal spec` çalıştırdığında bir test hatası gördü (`icon_provider_spec.cr:25`).
4. **Çakışma ve Deadlock:** Hatayı gidermek için `replace_file_content` / `write_file` ile dosyayı düzenleyip `apply_buffer` çağırdı. Ancak Plan 77'de eklenen çakışma kapısı devreye girdi:
   - `baseline = @original_hashes[path]` (eski diske yazılan hash)
   - `current_disk = disk_hash(path)` (formatlanmış yeni disk hash'i)
   - `baseline != current_disk` olduğu için `[CONFLICT] src/fff/icon_provider.cr: disk content changed since last read — skipped to prevent data loss` çıktısı üretildi ve dosya diske yazılmadı.
5. **Modelin Çaresizliği:**
   - `apply_buffer` bu çıktıyı `status: :ok` ile döndürdüğü için model işlemin başarısız olduğunu anlayamadı.
   - Model `read_file` çağırdı ancak `reload: true` vermediği için `Buffer::Manager#read` disk yerine `@buffer`'daki eski içeriği döndü; diskteki yeni biçimlendirmeyi göremedi.
   - Model `write_file` ile dosyayı tümüyle sıfırdan yazsa bile `@original_hashes` güncellenmediği için sonraki `apply_buffer` çağrıları da çakışma hatası verdi.
   - `apply_buffer` tool'unda çakışmayı aşmak için `force: true` veya `overwrite: true` seçeneği bulunmuyordu.
   - Sonuç olarak model 30 dakika boyunca dosyayı yazıp test çalıştırma ve başarısız olma döngüsünde kilitlendi.

Bu plan, söz konusu deadlock'u kökten çözen mimari düzeltmeleri ve araç ergonomisi iyileştirmelerini kapsar.

---

## 🔬 GitNexus Etki Analizi Özeti

| Sembol | Risk | Etki |
|:---|:---|:---|
| `Buffer::Manager#apply!` | UNKNOWN / MEDIUM | 8 çağrı noktası (StepExecutor, REPL commands, ApplyBufferTool, DiffViewer, testler) |
| `Buffer::Manager#write` | LOW / MEDIUM | WriteFileTool, ReplaceFileContentTool, testler |
| `Buffer::Manager#read` | LOW / MEDIUM | ReadFileTool, ReplaceFileContentTool, testler |
| `ApplyBufferTool` | MEDIUM | Araç kayıt defteri, LLM loop, REPL yürütümü |
| `StepExecutor::ERROR_PREFIXES` | LOW | Tool çıktılarının hata/başarı durumunun sınıflandırılması |
| `ReplaceFileContentTool` | LOW | Parametre toleransı (alias desteği) |

---

## 📐 Çözüm Mimarisi

```
┌─────────────────────────────────────────────────────────────┐
│  KATMAN 1: Buffer::Manager Senkronizasyonu                  │
│  - apply! sonrası @buffer.delete(rel_path) (SSOT)           │
│  - apply!(..., policy: "overwrite") per-call override       │
│  - write_file tam yazımlarda baseline güncelleme           │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  KATMAN 2: ApplyBufferTool & StepExecutor Hata Sınıflandırma│
│  - [CONFLICT] durumunda status: :error dönmesi              │
│  - ERROR_PREFIXES içine "[CONFLICT]" eklenmesi              │
│  - params_schema'ya force: boolean eklenmesi                │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  KATMAN 3: Araç Ergonomisi & Model Rehberliği               │
│  - replace_file_content parametre alias desteği             │
│    (old_content -> target_content, new_content -> repl)     │
│  - ContextBuilder operasyonel kurallarında net yönlendirme  │
└─────────────────────────────────────────────────────────────┘
```

---

## 📋 Uygulama Adımları

### D-1: `Buffer::Manager#apply!` Disk Senkronizasyonu ve `policy` Argümanı
**Dosya:** `lib/rubik/buffer/manager.rb`

1. **Metot İmzası:**
   ```ruby
   def apply!(target_paths = nil, policy: nil)
   ```
   `effective_policy = policy || external_modification_policy`
   Böylece çağrıcı (`ApplyBufferTool`), konfigürasyonu bozmadan tek seferlik `policy: "overwrite"` geçebilir.

2. **Başarılı Yazım Sonrası `@buffer` Temizliği:**
   Diske yazılan her `rel_path` için:
   ```ruby
   Rubik::Platform.atomic_write(full_path, content)
   @original_hashes[rel_path] = Digest::SHA256.hexdigest(content)
   @dirty_files.delete(rel_path)
   @buffer.delete(rel_path) # <-- EKLENECEK: disk ile senkronize edildi, buffer temizlenir
   applied_paths << rel_path
   ```
   **Gerekçe:** Dosya diske yazıldıktan sonra artık "kirli" değildir. `@buffer` temizlendiğinde, harici bir formatter (`crystal tool format`, `prettier`, `rubocop`) diski değiştirdiğinde bir sonraki `read_file` diskteki güncel içeriği okur ve `@original_hashes`'ı otomatik günceller.

---

### D-2: `Buffer::Manager#write` Baseline Yenileme Desteği
**Dosya:** `lib/rubik/buffer/manager.rb`

`write` metoduna `reset_baseline: false` seçeneği eklenir:
```ruby
def write(path, content, reset_baseline: false)
  @monitor.synchronize do
    rel_path = sanitize_path(path, for_write: true)
    normalized_content = Rubik::Platform.normalize_newlines(content)

    if reset_baseline || !@original_hashes.key?(rel_path)
      full_path = File.expand_path(rel_path, @root_dir)
      @original_hashes[rel_path] = (Digest::SHA256.hexdigest(Rubik::Platform.normalize_newlines(File.read(full_path))) if File.exist?(full_path))
    end

    @buffer[rel_path] = normalized_content
    @dirty_files[rel_path] = true
    @event_bus&.emit(:buffer_changed, path: rel_path)
    normalized_content
  end
end
```
`WriteFileTool#execute` içinden `write` çağrılırken `reset_baseline: true` iletilir.  
**Gerekçe:** Model `write_file` ile dosyanın tüm içeriğini sıfırdan oluşturuyorsa, referans aldığı temel diskteki en son durumdur.

---

### D-3: `ApplyBufferTool` Şeması ve `force` / `overwrite` Desteği
**Dosya:** `lib/rubik/tools/builtins/lifecycle.rb`

1. **Parametre Şeması:**
   ```ruby
   params_schema: {
     type: "object",
     properties: {
       reason: { type: "string", description: "Optional explanation of why buffer is being applied" },
       force: { type: "boolean", description: "If true, overwrites disk files even if modified externally by formatters or external processes (resolves [CONFLICT])" }
     }
   }
   ```
2. **Yürütme Mantığı:**
   - `force = args["force"] == true || args[:force] == true || args["overwrite"] == true || args[:overwrite] == true`
   - `@buffer_manager.apply!(policy: force ? "overwrite" : nil)`
3. **Çakışma Yanıtı:**
   - Eğer hiçbir dosya uygulanamadıysa ve çakışma varsa `ToolOutput.error(...)` dönülür.
   - Hata mesajı Elm tarzı yönlendirici olur:
     ```text
     [CONFLICT] src/fff/icon_provider.cr: disk content changed externally since last read.
     To force overwrite with your buffer changes, call: apply_buffer(force: true)
     To inspect the external changes first, call: read_file(path: "src/fff/icon_provider.cr", reload: true)
     ```

---

### D-4: `StepExecutor::ERROR_PREFIXES` Güncellemesi
**Dosya:** `lib/rubik/orchestrator/step_executor.rb`

`ERROR_PREFIXES` dondurulmuş dizisine `"[CONFLICT]"` ve `"[CONFLICT "` eklenir.  
Böylece herhangi bir araçtan dönen çakışma mesajı otomatik olarak `status: :error` olarak etiketlenir ve LLM durumun farkına varır.

---

### D-5: `ReplaceFileContentTool` Parametre Toleransı (Alias Desteği)
**Dosya:** `lib/rubik/tools/builtins/files.rb`

Frontier modellerin ve farklı LLM sağlayıcılarının yaygın kullandığı parametre adları tolere edilir:
```ruby
target = args["target_content"] || args[:target_content] ||
         args["old_content"] || args[:old_content] ||
         args["old_str"] || args[:old_str] ||
         args["target"] || args[:target]

replacement = args["replacement_content"] || args[:replacement_content] ||
              args["new_content"] || args[:new_content] ||
              args["new_str"] || args[:new_str] ||
              args["replacement"] || args[:replacement]
```
Eğer parametre eksikse dönen hata mesajı hangi parametrelerin beklendiğini açıkça gösterir.

---

### D-6: Sistem Promptu ve Operasyonel Kurallar
**Dosya:** `lib/rubik/prompt/context_builder.rb`

`build_operational_rules_xml` altındaki 2. kural güncellenir:
```text
If `apply_buffer` reports `[CONFLICT]` due to external modifications (e.g. from code formatters or test runners), either inspect disk changes with `read_file(path: "...", reload: true)` or overwrite deliberately with `apply_buffer(force: true)`.
```

---

### D-7: Test Kapsamı ve Doğrulama
**Yeni Test Dosyası:** `test/unit/test_buffer_conflict_resolution.rb`

1. **Formatter Sonrası Senkronizasyon:** `write_file` + `apply_buffer` yapıldıktan sonra diskte dosya harici bir işlemle değiştirildiğinde, sonraki `read_file` çağrısının yeni disk içeriğini okuduğu ve baseline'ı güncellediği doğrulanır.
2. **`apply_buffer(force: true)` Çakışma Aşımı:** Çakışma varken `force: true` ile dosyanın diske başarıyla yazıldığı test edilir.
3. **`[CONFLICT]` Hata Durumu:** Çakışmada dönen çıktının `status: :error` olarak sınıflandırıldığı doğrulanır.
4. **`replace_file_content` Alias Testi:** `old_content` / `new_content` parametreleri ile yapılan cerrahi düzenlemenin başarıyla çalıştığı test edilir.
5. **Mevcut Test Paketi:** `rake test` ile tüm testlerin yeşil kaldığı ve `rubocop` ile 0 offense sağlandığı doğrulanır.

---

## 🧪 Kırmızı Çizgiler

- `lib/rubik/config/defaults.rb` satır sayısı < 150 kalmalıdır.
- `lib/rubik/repl/shell.rb` satır sayısı <= 620 kalmalıdır.
- `Buffer::Manager#apply!` varsayılan davranışı (`policy: nil` olduğunda) geriye dönük uyumlu kalmalıdır (`config["buffer.on_external_modification"]` okunur).
- RuboCop 0 offense korunmalıdır.

---

## 🗂️ Etkilenen Dosyalar

| Dosya | Değişiklik Türü |
|:------|:----------------|
| `lib/rubik/buffer/manager.rb` | D-1: `apply!` policy kwargs & `@buffer.delete`, D-2: `write` reset_baseline |
| `lib/rubik/tools/builtins/lifecycle.rb` | D-3: `ApplyBufferTool` force param & ToolOutput.error |
| `lib/rubik/orchestrator/step_executor.rb` | D-4: `ERROR_PREFIXES` `[CONFLICT]` eklenmesi |
| `lib/rubik/tools/builtins/files.rb` | D-2: `WriteFileTool` reset_baseline: true, D-5: `ReplaceFileContentTool` alias toleransı |
| `lib/rubik/prompt/context_builder.rb` | D-6: `[CONFLICT]` ve `force: true` yönlendirme kuralı |
| `test/unit/test_buffer_conflict_resolution.rb` | D-7: Yeni kapsamlı birim testleri (6 senaryo) |

---

## 📝 Uygulama Günlüğü ✅

**Durum:** ✅ **Eksiksiz Uygulandı ve Doğrulandı** (D-1..D-7 tamamlandı, testler %100 yeşil, RuboCop 0 offense).

### Gerçekleştirilen Değişiklikler
1. **D-1 (Buffer Senkronizasyonu & SSOT):** `Buffer::Manager#apply!` içinde başarılı atomik diske yazım sonrası `@buffer.delete(rel_path)` uygulandı. Artık diske yazılan dosyalar bellek tamponunda kalarak harici araçların (`crystal tool format`, `prettier`, `rubocop`) disk değişikliklerini gölgeleyemez. Ayrıca `apply!(target_paths = nil, policy: nil)` parametresi ile per-call `policy: "overwrite"` desteği sağlandı.
2. **D-2 (Baseline Senkronizasyonu):** `Buffer::Manager#write` metoduna `reset_baseline: false` seçeneği eklendi. `WriteFileTool` tam dosya yazımlarında `reset_baseline: true` göndererek diskteki güncel hash'i yeni baseline olarak günceller. Mevcut mock/double testleriyle geriye dönük tam uyumluluk için `rescue ArgumentError` koruması eklendi.
3. **D-3 (ApplyBufferTool & force Parametresi):** `params_schema` içine `force` (ve `overwrite`) boolean alanı eklendi (`apply_buffer(force: true)`). Çakışma sebebiyle hiçbir dosya diske yazılamadığında `ToolOutput.error` döndürülerek sonucun `status: :error` olması sağlandı; Elm tarzı net aksiyon rehberi eklendi.
4. **D-4 (StepExecutor Sınıflandırması):** `ERROR_PREFIXES` listesine `"[CONFLICT]"` eklendi; çakışma durumları orkestratör döngüsünde anında `status: :error` olarak etiketlenir.
5. **D-5 (ReplaceFileContentTool Alias Toleransı):** `old_content`, `old_str`, `target` parametreleri `target_content` yerine; `new_content`, `new_str`, `replacement` parametreleri `replacement_content` yerine tolere edilir.
6. **D-6 (Sistem Promptu Operasyonel Kuralı):** `ContextBuilder` operasyonel kural 2 güncellenerek modelin çakışma anında `apply_buffer(force: true)` veya `read_file(reload: true)` kullanabileceği netleştirildi.
7. **D-7 (Test Kapsamı):** `test/unit/test_buffer_conflict_resolution.rb` dosyasında 6 yeni test senaryosu yazıldı.

---

## 🧪 Doğrulama ve Test Sonuçları

| Test Paketi | Run | Assertions | Failures | Errors | Skips | Durum |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|
| `test/unit/test_buffer_conflict_resolution.rb` | 6 | 36 | 0 | 0 | 0 | 🟢 Geçti |
| `test/unit/test_buffer_apply_conflict.rb` | 15 | 70 | 0 | 0 | 0 | 🟢 Geçti |
| `test/unit/test_elm_system_diagnostics_and_utf8_resilience.rb` | 13 | 70 | 0 | 0 | 0 | 🟢 Geçti |
| `test/unit/test_tool_layer_hardening.rb` | 8 | 44 | 0 | 0 | 0 | 🟢 Geçti |
| **Tam Süit (`bundle exec rake test`)** | **1480** | **8814** | **0** | **0** | **2** | 🟢 **%100 Yeşil** |
| **Lint (`bundle exec rubocop`)** | 6 dosya | - | 0 offense | 0 | - | 🟢 **0 Offense** |
| **GitNexus (`detect_changes`)** | 28 sembol | - | - | - | - | 🟢 **Risk: Medium** |

---

## 🎯 Kabul Kriterleri Doğrulaması

- [x] Formatter/linter diski değiştirdiğinde sonraki `read_file` diskteki yeni içeriği okur ve baseline senkronize olur.
- [x] Model `write_file` ile dosyayı sıfırdan yazdığında yapay çakışma oluşmaz (`reset_baseline: true`).
- [x] `apply_buffer` çakışma durumunda `status: :error` döner ve `force: true` ile zorla yazılabilir.
- [x] `replace_file_content` yaygın parametre alias'larını (`old_content`, `new_content`) tolere eder.
- [x] `defaults.rb` (< 150 satır: 149 satır) ve `shell.rb` (<= 620 satır: 578 satır) sınırları korunmuştur.
- [x] Tüm test süiti (1480 test) %100 yeşil ve RuboCop 0 offense'dir.
