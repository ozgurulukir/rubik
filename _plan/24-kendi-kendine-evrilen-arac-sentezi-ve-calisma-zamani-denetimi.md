# 24 — Kendi Kendine Evrilen Araç Sentezi, Spatiotemporal Çalışma Zamanı Denetimi ve Canlı Yetenek Kazanımı

**Durum:** ✅ **Tamamlandı** · **Zorluk:** Zor · **Öneri kaynağı:** Kullanıcı Yönergesi & `AGENTS.md` (§1–§6) · **Faz:** 5 (Kendi Kendini Geliştiren Sistem & Meta-Runtime)  
**İlgili Planlar:** [20 — Spatiotemporal Composability](20-spatiotemporal-composability-eklenti-dongusu.md) · [21 — REPL Komut Sentezi](21-llm-komut-sentezi-ve-calistirma.md) · [23 — XML Yapılandırılmış Bağlam](23-xml-yapilandirilmis-baglam-ve-agents-protokol-entegrasyonu.md) · [Index](index.md)

---

## 🌟 Amaç ve Vizyon

Rubik'in en benzersiz ve güçlü yeteneği: **Yapay Zekânın Görev Esnasında Kendi Araçlarını (Native Tools) Sentezlemesi, Pre-flight Sandbox Doğrulamasıyla Canlı Çalışma Zamanına Katması ve Çalışma Zamanı Grafını Denetlemesi.**

1. **Dinamik Native Tool Sentezi (`synthesize_tool`):** Ajanın sadece REPL komutu değil, tam tipli JSON Schema sözleşmesine sahip birinci sınıf bir aracı (`Rubik::Tools::BaseTool`) çalışma anında üretmesi ve hemen bir sonraki adımda çağırabilmesi.
2. **Pre-flight Sandbox Doğrulaması ve Atomik Geri Alma:** Sentezlenen aracın önce `ctx.extend()` içinde izole test argümanlarıyla (`test_args`) çalıştırılması; hata verirse $\Omega$ LIFO ile anında geri alınması (*Atomic Rollback*), başarılı olursa canlı registry'e terfi ettirilmesi.
3. **Kapsamlı Kalıcılık:**
   - `:session` (görev süresince bellek içi),
   - `:project` (`.rubik/tools/<name>.rb` repo ile paylaşılır),
   - `:global` (`~/.rubik/tools/<name>.rb` evrensel).
4. **Çalışma Zamanı ve Coeffect Denetimi (`inspect_runtime` & `provide_service`):** Ajanın sistemdeki aktif servisleri, `Pending` ve `Active` fiberları, bağımlılık grafını ve $\Omega$ tersine çevrilebilir efekt durumunu sorgulaması.

---

## 🏛️ Tamamlanan Görevler

1. `Rubik::Tools::SynthesizeToolTool` (`synthesize_tool`):
   - `name`, `description`, `params_schema`, `scope`, `code`, `test_args` parametrelerini tam şemayla işler.
   - Pre-flight sandbox çalıştırma ve atomik rollback güvencesi sağlar.
   - `:project` ve `:global` kapsamlarında `.rubik/tools/` dizinine otomatik yazar ve `@tool_registry` içine canlı bağlar.
2. `Rubik::Tools::InspectRuntimeTool` (`inspect_runtime`):
   - Aktif fiberları, pending coeffectleri, kayıtlı servisleri, araçları ve REPL komutlarını teşhis eder.
3. `Rubik::Tools::ProvideServiceTool` (`provide_service`):
   - Ajanın context içine yeni servisler sunarak bekleyen (`Pending`) fiberları aktifleştirmesini sağlar.
4. `Rubik::Runtime::OverlayStorage` Genişletmesi:
   - `.rubik/tools/*.rb` ve `~/.rubik/tools/*.rb` dizinlerini yönetir, `save_tool`, `list_tools`, `load_tools` metotlarıyla sıfır kesintili geri yükleme sağlar.
5. `Rubik::Orchestrator::Loop` Canlı Şema Senkronizasyonu:
   - Ajan görev döngüsü içindeyken yeni bir araç sentezlerse, `opts[:tools]` her adımda `@tool_registry.schemas` üzerinden taze şemayla beslenir.
6. Birim ve İleri Düzey Entegrasyon Testleri:
   - `test/unit/test_self_evolving_tool_synthesis.rb` ve `test/unit/test_expanded_tools.rb`.

---

## Kabul Kriterleri

- [x] LLM `synthesize_tool` çağrısı yaparak geçerli JSON Schema ve Ruby kodu ile yeni bir araç ürettiğinde, bu araç anında `@tool_registry`'ye eklenir ve bir sonraki adımda LLM tarafından native tool olarak çağrılabilir.
- [x] Pre-flight test adımı (`test_args`) başarısız olan veya syntax hatası içeren araçlar geri alınır (*Atomic Rollback*) ve runtime bozulmaz.
- [x] `:project` kapsamındaki araçlar `.rubik/tools/` klasörüne yazılır ve yeni bir Rubik REPL oturumunda otomatik yüklenir.
- [x] `inspect_runtime` aracı, çalışma zamanı servislerini ve fiber durumlarını şeffafça modele raporlar.

---

## Bağımlılıklar

- [Plan 20 (Spatiotemporal Composability)](20-spatiotemporal-composability-eklenti-dongusu.md)
- [Plan 21 (REPL Komut Sentezi)](21-llm-komut-sentezi-ve-calistirma.md)
- [Plan 23 (XML Yapılandırılmış Bağlam)](23-xml-yapilandirilmis-baglam-ve-agents-protokol-entegrasyonu.md)
- `AGENTS.md` (§1–§6)

---

## Test Kapsamı

- `test/unit/test_self_evolving_tool_synthesis.rb`:
  - `test_synthesize_session_tool_and_execute`
  - `test_preflight_verification_failure_causes_atomic_rollback`
  - `test_synthesize_project_tool_persistence_and_autoloading`
  - `test_inspect_runtime_diagnostics`
  - `test_provide_service_activates_pending_fiber`
