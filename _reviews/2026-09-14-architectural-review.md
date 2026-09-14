# 🏛️ Rubik — Mimari İnceleme (Architectural Review)

> **Tarih:** 14 Eylül 2026 (Pzt)
> **İncelene Sürüm:** `main` @ `67e75f0` ("fix(tests): make 8 failing tests pass on Windows (Ruby 4.0)")
> **Yöntem:** Modül yapısı taraması, çekirdek sınıf outline/body incelemesi, bağımlılık yönü analizi, temsili test çalıştırmaları
> **Kapsam:** `lib/` (210 dosya, ~27.7k LOC) · `test/` (181 dosya, ~28.1k LOC) · Ruby 4.0.6

---

## 1. Mimari Harita

```
bin/rubik → REPL::Shell (kompozisyon kökü + giriş döngüsü)
                │
                ├─ Orchestrator::Loop (adım döngüsü) ──→ LLM (router/providers)
                │        │                                  ↑
                │        └─→ Tools::Registry (coeffect-gated) ┤
                ├─ Runtime::Manager ──→ Context (revertible effects + coeffects)
                │        └─→ ComponentFiber (PENDING→ACTIVE→FAILED state machine)
                ├─ AST / LSP / MCP / Sandbox / Security / Plugin / Skills  (alt sistemler)
                └─ UI (Theme, Renderer, DiffViewer)  ← capability-gated
```

**Bağımlılık yönü sağlıklı:** `orchestrator/`, `runtime/`, `tools/` içinden `repl`'e hiçbir `require_relative` yok. `lib/rubik.rb` düz bir kompozisyon kökü (25 require, neredeyse hiç mantık yok).

---

## 2. Güçlü Yönler ✅

1. **Protokol sadakati gerçek, süs değil.** `Runtime::Context` LIFO inverse akümülatörü, hata izoleli dispose, per-hop locking (child→parent kilit ters sırası deadlock riski yorumda belgelenmiş), zero-restart kuralları (provide başına tek inverse, `prune_child` ile flat extend/dispose döngüleri) — bunlar `AGENTS.md` §1/§6'nın birebir uygulaması.
2. **Explicit coeffect sözleşmesi.** `Coeffects` modülü kanonik anahtarları tek kaynaktan yönetiyor; legacy alias köprüsü (`ALIAS_TO_CANONICAL`) reaktif reconcile'a bağlı — alias ile enjekte fiber, kanonik re-provide'a tepki veriyor. Küresel singleton araması yok.
3. **Reentrancy bilinci.** `Manager`'daki `@activating` guard'ı (factory'nin kendi bağımlılığını re-provide ederek sonsuz döngü kurması — Monitor reentrant olduğu için SystemStackError'a spirallenirdi), `reconcile_all`'daki snapshot iterasyonu (rubocop-disable gerekçeli) — bu seviyedeki eşzamanlılık düşüncesi ender görülür.
4. **Test/code oranı >1:1** (~28.1k/27.7k) ve disiplinli: paletin renk körlüğü güvenliği, `paint()`'in bilinmeyen stilde sessiz düşmemesi gibi davranışlar *testle kilitlenmiş*. Örneklenen dosyalar: `test_ui_theme` (20 runs), config reactivity (15), Elm diagnostics (21) — hepsi 0 failure.
5. **Kademeli parçalanma yolu doğru.** 594 satırlık `Shell` bile mixin'lere (lifecycle, presentation, config_wiring, composition) bölünmüş; `Loop` da step_executor/stream_manager/budget_manager'a devretmiş. İstikrarlı bir "facade + delegasyon" evrimi.

**Ek not — renk körlüğü güvenliği:** `UI::Theme` varsayılan paleti bilinçli olarak color-blind safe (`success/added: :cyan`, `removed/error: :red`; `:green` palette yok) ve `test_default_palette_is_color_blind_safe` ile koruma altında. DiffViewer `+`/`-` işaretlerini metinde tutuyor — renk hiçbir zaman tek bilgi kanalı değil.

---

## 3. Bulgular ve Riskler ⚠️

| # | Risk | Ciddiyet | Detay |
|---|---|---|---|
| 1 | **Geniş facade sınıfları:** `Shell` (594 satır, 50 sembol), `Orchestrator::Loop` (403 satır, 35 sembol) | 🟠 Orta | Shell hâlâ heredoc işleme, buffer hatırlatma, tool registry kurma, output capture gibi ayrı sorumlulukları tutuyor. Loop provider config + step + tool-call + budget + compaction'ı birleştiriyor. Mixin'ler dağılımı iyileştirdi ama sınıf genişliği değişmedi — yeni davranış eklemek yine bu iki çekirdeğe dokunduruyor. |
| 2 | **`Orchestrator::Loop` → `Shell` enjeksiyonu** (shell_deps.rb ile daraltılmış) | 🟡 Düşük-Orta | Yön doğru (repl→orchestrator), ama Loop'un gövdesi Shell'in geniş yüzeyine dokunuyor. `shell_deps` arayüz daraltıcı olarak belgelenmeli ve Shell'e yeni public metot eklerken "Loop bunu kullanıyor mu?" sorusu style-guide'a yazılmalı. ✅ **Kısmen çözüldü (commit `8d7542f`):** "core dizinlerden repl'e require yok" değişmezi `test/unit/test_architectural_boundaries.rb` ile CI'a kilitlendi. `shell_deps`'in arayüz-daraltıcı olarak belgelenmesi ve "Loop bunu kullanıyor mu?" style-guide kuralı hâlâ açık. |
| 3 | **Küresel durum:** `Rubik.current_shell` / `runtime_manager` (4 satır: set lifecycle'da, temizle shell#stop'ta) | 🟡 Düşük | Kod tabanının *tek* ambient kökü; kimlik kontrollü nil'leme yapılmış, sızıntı küçük. Ancak protokolün "implicit global" yasağına tek istisna — araçlar/sentezlenen kod bunu keşfedebilir hâlde. Uzun vadede ctx hizmeti ("shell" coeffect) olacak. |
| 4 | **Tam test paketi Windows'ta >5 dk** (300s timeout'ta bitmedi) | 🟠 Orta | 176 unit dosyası + adapter'ların process spawn maliyeti. Geri bildirim döngüsü yavaş → mimari değişikliklerde kapsamlı test çalıştırılmama riski. Test adapter'ının 15s varsayılan timeout'u pratikte yetersiz kalıyor. |
| 5 | **Görünürlük kör noktası:** coupling aracı iç bağımlılıkları görmüyor | 🟡 Bilgi | `analyze_module_coupling` dosya seviyesinde yalnızca gem bağımlılıklarını yakalıyor, dizin seviyesinde 0 dönüyor; `require` grafiği hub dosyaları sayesinde sığ. Gerçek coupling metot-çağrısı üzerinden — mimari sürüklenmeyi araç otomatik yakalayamaz, CI'da koruyucu test/grep kuralı şart. |
| 6 | **`Runtime::Fiber` ad çakışması** (`::Fiber` ile) | 🟢 Düşük | Dosyada belgelenmiş (`ComponentFiber` ≠ coroutine). Yine de grep/arama gürültüsü yaratıyor; yeni kodda `ComponentFiber` adını doğrudan kullanmak okunurluğu artırır. |
| 7 | **Sentez ömrü döngüsünde CRUD boşluğu:** `synthesize_command` / `synthesize_tool` Create-Read-Update yapıyor, **Delete yok** | 🟠 Orta | Create: `save_command`/`save_tool` + canlı kayıt. Read: `list_commands`/`list_tools` + `!commands`/`inspect_runtime`. Update: rebuild'de otomatik veya built-in olmayan üzerine yazma. Ama **diskten silme ve canlı kaydı kaldırma için ne REPL komutu ne API var**: `OverlayStorage`'da `delete_command`/`delete_tool` tanımsız; `plugins.rb`'deki `remove/uninstall` yalnızca plugin yolunu işliyor; `!commands`/`!tools` yalnızca listeliyor. `Tools::Registry.unregister` mevcut ama sentez yolu onu çağıran hiçbir akışa bağlı değil — bu inceleme oturumundaki somut vakada sentezlenen `analyze_module_coupling` diski elle temizlenmişken (boş manifest) canlı registry'de saatlerce hayalet tool olarak kaldı; çıkarma ancak süreç yeniden başlatılarak mümkün oldu. Kalıntı silinmezse yeniden kayıt riski yok (load_all/load_tools `integrity == :rejected` girdileri atlıyor, `overlay_storage.rb:161/237`) ama boş kalan manifest girdileri ve API'siz elle temizlik, silme eylemini protokolün dışına itiyor. ✅ **Çözüldü (commit `8d7542f`):** `OverlayStorage#delete_command`/`delete_tool` (manifest girdisi + dosya) ve canlı kaydı da kaldıran `UnsynthesizeTool` eklendi; silme etkisi revertible inverse ile geri alınabilir. |

**Güçlü yön olarak not:** `ComponentFiber#activate!` hatada sub-context'i anında dispose edip `:failed`'e geçiyor (atomic rollback), `:failed` fiber koşullar sağlanınca manager tarafından yeniden deneniyor — `AGENTS.md` §2 state machine tablosuyla birebir örtüşüyor.

---

## 4. Öneriler (öncelik sıralı)

1. **Test stratifikasyonu (yüksek getiri):** unit/integration ayrımı + paralel minitest; adapter spawn testlerini `tag :slow` ile ayırıp varsayılan task'tan çıkar. Böylece `rake test` dakikalar yerine saniyeler içinde feedback verir.
2. **Mimari koruma testi:** "lib/rubik/{orchestrator,runtime,tools,llm} içinden repl'e require yok" iddiasını tek bir test dosyasıyla sabitleyin (Dir.glob + assert). Coupling aracının göremediği tek ihlal sınıfını CI'a bağlar. ✅ **Yapıldı (commit `8d7542f`) — `test/unit/test_architectural_boundaries.rb`:** `orchestrator/runtime/tools/llm` içinden `repl` dizinine ve üst düzey `repl.rb` dosyasına giden tüm `require`/`require_relative`'ları yakalar; bugün 0 ihlalle yeşil.
3. **Shell/Loop inceltme planı:** Shell'in kalan 50 sembolü için her PR'da "yeni davranış mixin'e mi gitti, çekirdeğe mi?" sorusunu review checklist'e ekleyin; Loop'taki provider-config bölümü ayrı bir `ProviderResolver`'a taşındı. ✅ **Yapıldı (commit `445f68f`):** `Rubik::Orchestrator::ProviderResolver` (gövdeler birebir, yorumlarıyla taşındı; tembel memoize erişimci — `build_knob_loop` tarzı `allocate`-tabanlı testler korunur), Loop'ta aynı ad/imzalı private delegasyon şimleri, `test/unit/test_provider_resolver.rb` (11 davranış) + allocate-uyumluluk kilidi testi. "Mixin'e mi çekirdeğe mi?" kontrol listesi `ARCHITECTURE.md` Bölüm 7 olarak kalıcılaştı. Shell tarafı inceltme (kalan 50 sembol) gelecek iş paketleri için açık.
4. **Küresel durum için geri sayım:** `Rubik.current_shell` okuyan her çağrı noktasını bulunup `ctx.require("shell")`'e çevrilebilir; 4 satırlık bugün küçük, yarın çoğalabilir.
5. **Geliştirici ortamı:** İnceleme makinesinde `bash`/WSL bozuk durumda (`execvpe(/bin/bash) failed`) — script'ler cmd-uyumlu tutulmalı veya alternatif runner bağlanmalı; yoksa katkıda bulunanlar "yalnızca bende çalışıyor" tuzağına düşer.
6. **Sentez CRUD'un tamamlanması:** `SynthesizeCommandTool`/`SynthesizeToolTool`'un ikizleri olarak `delete` taşıyan tek bir `unsynthesize` aracı ekleyin; `OverlayStorage`'a `delete_command`/`delete_tool` (manifest girdisi + dosya) yazın. Protokole uygun biçim: silme etkisi **inverse'i ile birlikte** — canlı kayıt için `@shell.commands.delete(name)`/`@tool_registry.unregister(name)`, `@runtime_manager.context.on_dispose { restore previous }` ile geri alınabilir. Test: "sentezle → sil → hem diskte yokluğu hem `registry.get(name).nil?` olduğunu doğrula" — canlı/disk ıraksaması (Bulgu 7) sinsi bir regresyon sınıfı olduğu için bu tek test kritik. ✅ **Yapıldı (commit `8d7542f`):** `UnsynthesizeTool` (aliases `delete_tool`/`delete_command`/`remove_tool`/`remove_command`) eklendi; `OverlayStorage#delete_command`/`delete_tool` manifest girdisi + dosyayı birlikte kaldırıyor (bozuk manifesti `{}` ile silmeyen fail-closed guard ile), canlı kayıt `unregister_command`/`unregister` ile kaldırılıyor, `on_dispose` inverse önceki kaydı geri yüklüyor, built-in silme reddediliyor. Kritik regresyon testleri `test_self_evolving_tool_synthesis.rb` içinde: `test_unsynthesize_tool_removes_live_and_disk` ve `test_unsynthesize_command_removes_live_and_disk` — ikisi de disk yokluğu + `registry.get(name).nil?`/`@shell.commands[name].nil?` + manifest girdisi kaldırılmasını doğruluyor.

---

## 5. `AGENTS.md` §6 Checklist Sonucu

- ✅ **Locality of disposal** — her serve/inverse `Context#provide` içinde eşleşik; banner tarzı "remote teardown" taramasında bulunmadı.
- ✅ **Explicit dependencies** — kanonik coeffect anahtarları + legacy alias köprüsü.
- ✅ **LIFO unwinding / atomic rollback** — `dispose` hata izoleli; `activate!` partial-inverse geri sarıyor.
- ✅ **Sub-context scoping** — fiber başına `context.extend`; erken dispose'da parent prune.
- ✅ **Zero-restart** — provide başına tek inverse; reentrant reconcile guard'ı ile 1000× reload hedefi destekleniyor.
- ⚠️ Tek çekince: test paketinin yavaşlığı, "zero-restart altında yük testi" pratiğini maliyetli kılıyor — Öneri 1'deki stratifikasyon bunu doğrudan iyileştirir.

---

## Genel Değerlendirme

**Sağlıklı ve olgun bir mimari — 8/10.** Protokol ilkeleri kodun ritmi haline gelmiş; ana borç iki geniş facade sınıfı ve yavaş test döngüsü — ikisi de organik büyüme belirtileri, yapısal çürüme değil.

---

*İnceleme oturum notları: Tam test paketi (`bundle exec rake test`) Windows ortamında 300 saniyede tamamlanamadı; sağlık örneklemesi temsili test dosyalarıyla yapıldı (60 run, 0 failure). Bash/WSL binary hatası nedeniyle komutlar cmd sözdizimiyle yürütüldü.*

*Revizyon 1 (aynı gün): Sürüm referansı `d60b8a1` → `67e75f0` ve `lib/rubik.rb` require sayısı 28 → 25 olarak doğrulandı. Bulgu 7 (sentez CRUD boşluğu) ve Öneri 6, sentezlenen `analyze_module_coupling` aracının canlı oturumda yaşadığı hayalet-kayıt vakası sonrası eklendi; aracın disk kalıntısı temizlendi, canlı oturumdan çıkarılması `delete` API'sinin yokluğu nedeniyle ancak süreç yeniden başlatılarak tamamlandı. Revizyon sırasında Bulgu 7'nin "yeniden kayıt riski" ifadesi doğrulama sonrası düzeltildi: `load_all`/`load_tools` integrity `:rejected` girdileri atlıyor — gerçek boşluk Delete API'sinin yokluğu.*

*Revizyon 2 (aynı gün): Bulgu 7 + Öneri 6 ve Bulgu 2 + Öneri 2, pipeline ile çözüldü (commit `8d7542f`, `feat(tools): add unsynthesize tool to close synthesis CRUD gap`). `UnsynthesizeTool` + `OverlayStorage#delete_command`/`delete_tool` (manifest + dosya, fail-closed corrupt-manifest guard, revertible inverse, built-in reddi) ve `test/unit/test_architectural_boundaries.rb` mimari koruma testi eklendi. Kritik regresyon testleri `test_self_evolving_tool_synthesis.rb` içinde (canlı + disk + manifest yokluğu).*

*Revizyon 3 (aynı gün): Öneri 3 pipeline ile çözüldü (commit `445f68f`, `refactor(orchestrator): extract ProviderResolver from Loop; add PR review checklist`). `Rubik::Orchestrator::ProviderResolver` çıkarımı (gövdeler + yük taşıyıcı yorumlar birebir; tembel memoize erişimci `allocate`-tabanlı test dublolarını korur; Loop'ta aynı ad/imzalı private delegasyon şimleri), `test/unit/test_provider_resolver.rb` (11 davranış: registry-key fallback zinciri, scoped-nil = unset, explicit-false korunması, KeyError'suz plain-Hash düşüşü, crash toleransı) + `test_llm_custom_headers_and_config_knobs.rb` içine allocate-uyumluluk kilidi testi, `ARCHITECTURE.md` Bölüm 7 PR kontrol listesi. Doğrulama: resolver 11/11, loop-knob 18 run (4 önceden var olan `minitest/mock` ortam hatası HEAD'de de var — regresyon değil), shell_deps + step_budget + mimari sınır 10/10. Açık kalanlar: Öneri 1 (test stratifikasyonu), Öneri 4 (küresel durum → `ctx.require("shell")`), Öneri 5 (dev ortamı), Bulgu 6 (Fiber ad çakışması).*
