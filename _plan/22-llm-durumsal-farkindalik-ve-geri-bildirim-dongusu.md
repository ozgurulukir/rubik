# 22 — LLM Durumsal Farkındalık, Dinamik Prompt Enjeksiyonu ve Kendi Kendini Düzeltici Geri Bildirim Döngüsü

**Durum:** ✅ **Tamamlandı** · **Zorluk:** Orta–Zor · **Öneri kaynağı:** Kullanıcı Yönergesi & `AGENTS.md` (§3, §6) · **Faz:** 5 (Kendi Kendini Geliştirme & Kapalı Devre Geri Bildirim)  
**İlgili Planlar:** [21 — LLM REPL Komut Yürütümü ve Sentezi](21-llm-komut-sentezi-ve-calistirma.md) · [10 — Tool-Calling](10-tool-calling-orkestrasyon.md) · [02 — REPL Çekirdeği](02-repl-cekirdegi.md) · [Index](index.md)

---

## Amaç

Ajanın (LLM) çalışma anındaki yeteneklerinden, araçlarından ve REPL ortamından **tam durumsal farkındalığa (Situational Awareness)** sahip olmasını sağlamak; araç şemalarını (Tool Contracts) zenginleştirmek, mevcut komutları dinamik olarak System Prompt'a enjekte etmek ve hatalı kullanımlarda modeli kendi kendini düzeltmeye (Self-Correction) sevk eden açıklayıcı geri bildirim döngüleri sunmak.

---

## Mimari Yapı ve Geri Bildirim Akışı

```text
                        ┌──────────────────────────────────────────────┐
                        │        LLM DURUMSAL FARKINDALIK SİSTEMİ      │
                        └──────────────────────┬───────────────────────┘
                                               │
                       ┌───────────────────────┴───────────────────────┐
                       ▼                                               ▼
     ┌───────────────────────────────────┐           ┌───────────────────────────────────┐
     │ 1. DİNAMİK BAĞLAM ENJEKSİYONU     │           │ 2. TOOL CONTRACT (JSON SCHEMA)    │
     ├───────────────────────────────────┤           ├───────────────────────────────────┤
     │ • Canlı kayıtlı `!` komut listesi │           │ • `exec_repl_command` şeması      │
     │ • Dil, tampon, git dalı durumu    │           │ • `synthesize_command` parametre  │
     │ • Görev moduna özel yönergeler    │           │   tipleri ve enum değerleri       │
     └───────────────────────────────────┘           └───────────────────────────────────┘
                                                       │
                               ┌───────────────────────┴───────────────────────┐
                               ▼                                               ▼
                     ┌───────────────────┐                           ┌───────────────────┐
                     │ 3. HATA TESPİTİ   │                           │ 4. SELF-CORRECT   │
                     │    & YÖNLENDİRME  │ ────────────────────────► │    FEEDBACK LOOP  │
                     └───────────────────┘                           └───────────────────┘
                     • "Bilinmeyen komut!                            • Model çıktıyı     │
                        Kullanılabilirler:                            okur ve doğru      │
                        !diff, !test, ..."                            parametreyle dener.│
```

---

## Tamamlanan Görevler

1. **Tool Contract (JSON Schema) Zenginleştirmesi:**
   - `exec_repl_command`: Modelin hangi komutları ne amaçla çağırabileceğini belirten ayrıntılı şema ve parametre açıklaması.
   - `synthesize_command`: `name`, `description`, `scope: [session, project, global]` ve `code: ->(args, out, shell) { ... }` format kontratı.
2. **Dinamik System Prompt Enjeksiyonu (`Rubik::Orchestrator::Loop`):**
   - Çalışma anında modelin önüne o an sistemde yüklü olan tüm yerleşik ve katman komutlarının listesini çıkarma.
3. **Akıllı ve Rehberlik Eden Hata Geri Bildirimi (Closed-Loop Error Feedback):**
   - **Var Olmayan Komut Durumu:** Model yanlış veya hayali bir komut çağırdığında (`exec_repl_command("!olmayan")`), sistem `"Bilinmeyen komut: !olmayan. Kullanılabilir komutlar: !apply, !commands, !context, !diff, !model, !test, !undo (!help'e bakın)."` şeklinde tüm geçerli alternatifleri listeler.
   - **Eksik/Hatalı Argüman Durumu:** Örneğin `!model set` eksik argümanla çağrıldığında `"Usage: !model set <default|fast|advanced> <provider/name>"` şablonu geri beslenir.
   - **Sözdizimi Hata Yakalaması:** Model `synthesize_command` sırasında Ruby syntax hatası yaparsa, `SyntaxError` yakalanıp anlaşılır hata mesajı olarak modele iletilir.

---

## Kabul Kriterleri

- [x] LLM, `exec_repl_command` ve `synthesize_command` araçlarını JSON Schema kontratı üzerinden tam tipli olarak öğrenir.
- [x] Model var olmayan bir REPL komutunu çağırdığında, hata mesajında aktif geçerli komutların listesi öneri olarak sunulur.
- [x] Hatalı kod sentezinde Ruby `SyntaxError` ve `ScriptError` hataları yakalanıp modele düzeltici geri bildirim olarak iletilir.
- [x] Model, aldığı bu geri bildirimleri kullanarak bir sonraki adımda kendini düzeltebilir (*self-correct*).

---

## Bağımlılıklar

- [Plan 21 (LLM REPL Komut Yürütümü ve Sentezi)](21-llm-komut-sentezi-ve-calistirma.md)
- [Plan 10 (Tool-Calling Orkestrasyonu)](10-tool-calling-orkestrasyon.md)
- [Plan 02 (REPL Çekirdeği)](02-repl-cekirdegi.md)
- `AGENTS.md` (§3, §6)

---

## Test Kapsamı

- `test/unit/test_repl.rb`: `test_unknown_command_shows_error` (Kullanılabilir komut önerisi doğrulaması).
- `test/unit/test_repl_command_execution_and_synthesis.rb`: Bilinmeyen komut, sözdizimi hata yakalaması ve dinamik komut yürütüm testleri.
