# Plan: Doğrulanmış LOW Bulgu Düzeltmeleri — 2026-09-25

> **Kaynak:** 4 doğrulama ajanının verdict raporu (TRUE/LOW).
> **Protokol:** [`AGENTS.md`](../AGENTS.md) §A, §B, §6 (Zero-Restart).
> **Kapsam:** L1–L12 (fırsatçı, davranış-koruyucu temizlik).
> **Zorluk:** Kolay · **Faz:** 7 (Bakım / Teknik Borç)
> **Durum:** ✅ Tamamlandı (2026-09-25)

## Bağlayıcı kararlar
- Bu plan **davranış-koruyucu** (behavior-preserving) temizliktir; hiçbir kalem işlevsel çıktıyı değiştirmez.
- Refuted kalemler (C1/H9/M8/M10/M14/M16/M18) burada da yer almaz.

## İş kalemleri

- **W1** `runtime/context.rb` `resolve_with_alias`: çok-adımlı alias çözümünde TOCTOU/multi-lookup — tek `@services` snapshot'ı üzerinden çöz, ikinci `key?` çağrılarını kaldır.
- **W2** `tools/registry.rb` alias silme O(n): `@aliases.delete_if { ... }` yerine ters-indeks (`alias -> canonical`) veya `@alias_index` ile O(1); davranış aynı.
- **W3** `tools/base.rb` şemalarına `additionalProperties: false` eklenirse bilinçli-toleranslı tool'lar için opt-out bayrağı; varsayılanı değiştirmeden meta veri tutarlılığı.
- **W4** `ast/cache_store.rb` göreli-yol `/` varsayımı: `File::SEPARATOR`/`Platform` kullan, Windows `\` uyumu.
- **W5** `ast/extractor.rb` rescue kapsamı Tree-sitter hata sınıflarından dar: genişlet (bilinmeyen parse hatalarını yutmak yerine logla + boş sonuç).
- **W6** `config/deep_ops.rb` array merge: diziler bütün olarak değiştiriliyor — belgele (yorum) veya allowlist alanları için **union** opsiyonu ekle; varsayılanı koru.
- **W7** `config/store.rb` ayrıştırılamayan `allow_network`: sessizce fail-closed — bir `warn` ile görünür kıl (davranış aynı).
- **W8** `ui/theme.rb` bilinmeyen stil sessizce düz render: bir defalık `warn` (debug seviyesi) ile görünür kıl.
- **W9** `ui/dialog.rb` lazy require: Ctrl+C sonrası ham terminal bırakma riski — `ensure restore_console` doğrula; require'ı dosya başına taşı (yükleme döngüsü yoksa).
- **W10** `ui/statusline.rb` ikinci dereference unbound: nil-güvenli erişim (`&.`), davranış aynı.
- **W11** `lsp/client.rb` handshake capabilities yok sayılıyor: gelecekteki kullanım için sakla (davranış değişmez); `manager.rb` başarısız kolda başlatılan client'ı dispose et.
- **W12** `llm/message_sanitizer.rb` bozuk mesaj sessizce düşürülüyor: debug log ekle (davranış aynı).

## Commit planı (conventional)
Toplu tek commit uygun: `chore(review): address low-severity verified findings`
(İstenirse 3'e böl: `chore(runtime/tools)`, `chore(ast/config)`, `chore(ui/lsp/llm)`.)

## Test haritası
- W1/W2 → `test/unit/test_runtime_context.rb`, `test/unit/test_tool_registry.rb`.
- W4/W5 → `test/unit/test_ast_cache_store.rb`, `test/unit/test_ast_extractor.rb`.
- W6/W7 → `test/unit/test_config_deep_ops.rb`, `test/unit/test_config_store.rb`.
- W8/W9/W10 → `test/unit/test_ui_theme.rb`, `test/unit/test_ui_dialog.rb`, `test/unit/test_statusline.rb`.
- W11/W12 → `test/unit/test_lsp_client.rb`, `test/unit/test_message_sanitizer.rb`.
- Not: tüm kalemler davranış-koruyucu → mevcut pinler yeşil kalmalı; yalnız yeni log/warn iddiaları eklenir.

## Uygulama sırası
Düşük riskli tek-dosya kalemleri (W2, W4, W6, W8, W10) → durum/kaynak etkileyenler (W1, W5, W7, W11) → UI/LSP (W9) → W12 → `rake test:fast` + rubocop + GitNexus `detect-changes`.

## Kritik tuzaklar
- **W9**: lazy require kaldırılırsa yükleme sırası döngüsü oluşabilir (frame/theme ↔ interrupt_handler) → bağımlılık yönü korunmalı.
- **W6**: array union'a geçmek config override semantiğini değiştirir → yalnız opt-in allowlist alanları; varsayılan replace kalır.
- **W5**: rescue genişletmek gerçek bug'ları yutabilir → logla, durdurma.
- **W12**: log eklemek test çıktısını gürültülendirebilir → seviye `debug`.
- Her sembol öncesi **GitNexus impact**; ancak LOW kalemler düşük blast-radius.
 
## Uygulama ve Doğrulama Günlüğü (2026-09-25)

### Uygulanan Değişiklikler
- **W1 (`lib/rubik/runtime/context.rb`)**: `resolve_with_alias` metodunda tek `@services` snapshot'ı ve monitor lock kullanıldı, doğrudan ebeveyne delege edilerek TOCTOU ve çoklu kilit lookup'ları engellendi.
- **W2 (`lib/rubik/tools/registry.rb`)**: `@tool_aliases` indeksi (`tool_name => [aliases]`) eklenerek `unregister` işleminde alias temizliği O(N)'den O(1)'e düşürüldü.
- **W3 (`lib/rubik/tools/base.rb`)**: `allow_additional_properties` parametresi ve okuyucusu eklendi; varsayılan `true` kalırken opt-out araçlar için `to_h` şemasına `additionalProperties: false` enjekte edildi.
- **W4 (`lib/rubik/ast/cache_store.rb`)**: Windows ve POSIX dosya yollarının güvenli göreli yol dönüşümü için `Platform.normalize_path_raw` entegre edildi.
- **W5 (`lib/rubik/ast/extractor.rb`)**: Rescue bloğu `StandardError, ScriptError` olarak genişletilerek Tree-sitter ve Prism parser/syntax hataları güvenli şekilde ele alındı.
- **W6 (`lib/rubik/config/deep_ops.rb`)**: Dizi birleştirme davranışı belgelendi; geriye dönük uyumluluk korunarak `array_union: false` opsiyonel parametresi sağlandı.
- **W7 (`lib/rubik/sandbox/runner.rb`)**: `sandbox.allow_network` yapılandırması boolean olmayan veya geçersiz bir değer içerdiğinde `Platform.debug_warn` ile uyarı loglanıp güvenli kapatma (`fail-closed`) uygulandı.
- **W8 (`lib/rubik/ui/theme.rb`)**: Bilinmeyen UI stilleri için `@warned_styles` seti ile tek seferlik uyarı mekanizması kuruldu; debug modu haricinde sessiz kalması garanti altına alındı.
- **W9 (`lib/rubik/ui/dialog.rb`)**: `require_relative "../repl/interrupt_handler"` dosya başına taşındı; Ctrl+C / SIGINT kesilmelerinde lazy require kaynaklı race condition riski ortadan kaldırıldı.
- **W10 (`lib/rubik/ui/statusline.rb`)**: `routed[:spec]`, `dirty_files` ve `conversation_history` erişimleri nil-güvenli seyrüsefer operatörü (`&.`) ile sağlandı.
- **W11 (`lib/rubik/lsp/client.rb` & `lib/rubik/lsp/manager.rb`)**: Initialize el sıkışması sırasında gelen `@server_capabilities` saklandı; `manager.rb` içinde başlatma veya el sıkışma hatası alan istemcilerin `client.stop` ile kaynak sızıntısı yapmadan kapatılması sağlandı.
- **W12 (`lib/rubik/llm/message_sanitizer.rb`)**: Normalizasyon sırasında Hash olmayan veya bozuk mesajlar ayıklanırken `Platform.debug_warn` ile teşhis mesajı yazıldı.
- **Ek Düzeltmeler**:
  - `lib/rubik/lsp/client.rb` ve `lib/rubik/runtime/context.rb`: RuboCop `Style/RedundantBegin` temizlendi.
  - `test/unit/test_llm_retry.rb`: Ruby 3+ keyword argument eşleşme tutarlılığı ve `text_delta` mock olayı sağlandı.

### Doğrulama Sonuçları
- **RuboCop:** 13 dosyada 0 ihlal (`no offenses detected`).
- **Modül Hijyeni:** `test_module_hygiene.rb` — 11 runs, 80 assertions, 0 failures, 0 errors.
- **Fast Test Suite:** `rake test:fast` — 2013 runs, 10961 assertions, 0 failures, 0 errors, 1 skip.
- **GitNexus Değişiklik Tespiti:** `detect-changes --scope all` çalıştırıldı ve tüm etki alanları analiz edildi.

### Diff Review Bulguları ve İyileştirmeler (2026-09-25)
- **W2 Alias Silme Güvenliği (`lib/rubik/tools/registry.rb`)**:
  - *Bulgu:* Bir tool unregister edilirken, aynı alias ismine sonradan başka bir tool atanmışsa (`@aliases[al]` artık farklı bir tool'a işaret ediyorsa), önceki tool'un `@tool_aliases` listesinden `al` silinirken yeni tool'un alias kaydının da silinme riski mevcuttu.
  - *Düzeltme:* `@aliases.delete(al) if @aliases[al] == canonical_name` ve `@aliases.delete(name.to_s.downcase) if @aliases[name.to_s.downcase] == canonical_name` kontrolleri eklenerek yalnızca silinen tool'a ait alias eşleşmeleri temizlendi.
  - *Test:* `test/unit/test_tool_aliasing_and_naming.rb` dosyasına `test_unregister_cleans_aliases_without_affecting_reassigned_aliases` testi eklendi (10 runs, 135 assertions, 0 failures, 0 errors).

