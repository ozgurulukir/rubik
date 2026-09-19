# Plan 92 — Etkileşimli İnsan Geri Bildirimi: `ask_question` Aracı ve Karar Kapısı

> **Durum:** ✅ **Tamamlandı**  
> **Zorluk:** Kolay–Orta  
> **Faz:** 9 (Ajan Zekası & İnsan-Ajan Etkileşimi)  
> **Öneri Bölümü:** Ajan Ergonomisi, Araç Katmanı & Human-in-the-Loop  
> **İlgili Planlar:** [10](10-tool-calling-orkestrasyon.md), [16](16-genisletilmis-arac-seti-ve-planlama.md), [22](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md), [51](51-display-katmani-hibrit-tui-mimarisi.md), [56](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md), [AGENTS.md](../AGENTS.md)

---

## 🎯 1. Motivasyon ve Sorun Tanımı

Frontier kodlama ajanlarında (Antigravity, Claude Code, Cline, Cursor) en sık karşılaşılan sürtünmelerden biri, **eksik veya birden fazla geçerli alternatifi olan gereksinimlerdir** (örn. "Veritabanı migration'ı PostgreSQL için mi yoksa SQLite için mi hazırlansın?", "Mevcut API silinsin mi yoksa deprecation ile mi korunsun?").

### 🔍 Mevcut Kısıtlar ve Kök Nedenler:
1. **İkili Çıkmaz (Guess or Abort):**
   - Şu an Rubik'te model iki kötü seçenekle baş başadır: Ya kendi kendine varsayımda bulunup kullanıcının istemediği bir mimariyi inşa eder, ya da `finish` çağırarak görevi erken terk eder ve tüm döngü durur.
2. **Mid-Turn Duraklatma Eksikliği:**
   - `Orchestrator::Loop` ve `StepExecutor` senkron araç yürütürken kullanıcıdan girdi alabilecek resmi bir protokole sahip değildir.
3. **Headless / Non-Interactive Uyumluluk:**
   - Script, CI/CD veya test ortamlarında terminalde `gets` çağrılması süreci kilitler. Bu durumun zarifçe (graceful fallback) yönetilmesi gerekir.

---

## 🏛️ 2. `AGENTS.md` Spatiotemporal Uyumu ve Değişmezler

```
                          [ LLM Tool Call: ask_question ]
                                        │
                                        ▼
                         ┌─────────────────────────────┐
                         │   Interactive Context Gate  │
                         │   (UI::Capability Check)    │
                         └──────────────┬──────────────┘
                                        │
                 ┌──────────────────────┴──────────────────────┐
                 ▼ Interactive                                 ▼ Non-Interactive / Headless / CI
     ┌────────────────────────┐                    ┌────────────────────────┐
     │ Render tty-prompt / TUI│                    │ Auto-Select Recommended│
     │ Capture User Input     │                    │ Or First Option        │
     │ Clean LIFO Terminal St.│                    │ Tag with [Auto-Select] │
     └───────────┬────────────┘                    └───────────┬────────────┘
                 │                                             │
                 └──────────────────────┬──────────────────────┘
                                        ▼
                         [ Return Answer to Model Loop ]
```

1. **Context-Mediated UI & SSOT:** Kullanıcı etkileşimi doğrudan `Kernel#gets` ile değil, `Context` üzerinden enjekte edilen reaktif `ui` servisi ve `Rubik::UI::Capability.interactive?(input: shell.input, output: shell.output)` SSOT kontrolüyle yürütülür.
2. **Revertible State & Terminal Temizliği:** Kullanıcı etkileşimi sırasında `SIGINT` (Ctrl+C) veya iptal gelirse, `Rubik::REPL::InterruptHandler.restore_console_after_interrupt` tetiklenir ve LIFO ters işlemiyle terminal ham moddan standart moda geri döndürülür (`ctx.on_dispose { restore_terminal_state }`).
3. **Otomatik Çözümleme (Auto-Select Fallback):** Non-interactive modda (stdin kapalı veya `--non-interactive`) model kilitlenmez; `(Recommended)` işaretli seçenek veya ilk seçenek otomatik seçilerek modele `[Non-interactive session: auto-selected '(Recommended) Option A']` bildirimi dönülür.

---

## 🏗️ 3. Mimari Tasarım ve Fazlar

### 📦 Faz A: `AskQuestionTool` Araç Kontratı
**Dosya:** `lib/rubik/tools/builtins/interactive.rb` (`Rubik::Tools::AskQuestionTool`)

- **JSON Şeması:**
```json
{
  "name": "ask_question",
  "description": "Prompts the human operator with one or more structured questions to clarify underspecified requirements, solicit design preferences, or choose between implementation paths.",
  "parameters": {
    "type": "object",
    "properties": {
      "questions": {
        "type": "array",
        "description": "List of questions to ask the user.",
        "items": {
          "type": "object",
          "properties": {
            "question": { "type": "string", "description": "The clear question text to display." },
            "options": {
              "type": "array",
              "items": { "type": "string" },
              "minItems": 2,
              "description": "List of selectable answer options (at least 2). Recommended option should be prefixed with '(Recommended)'."
            },
            "is_multi_select": { "type": "boolean", "description": "True if multiple options can be chosen simultaneously." }
          },
          "required": ["question", "options"]
        }
      }
    },
    "required": ["questions"]
  }
}
```

- **Girdi Doğrulama & Elm Teşhisi:**
  - `options.size < 2` ise `ToolOutput.error("ask_question requires at least 2 options to present a meaningful choice.")` döner.
  - Seçenekler sıralı olarak yinelenenlerden arındırılır (`options.uniq`).

- **Dönüş Formatı (Output Contract):**
  - Tekli seçim: `User response: Option A`
  - Çoklu seçim: `User response: [Option A, Option B]`
  - Serbest metin: `User response (custom write-in): Custom explanation`
  - İptal / Esc: `User cancelled the prompt without selection.`

### 🎨 Faz B: TUI Seçim Arayüzü
**Dosya:** `lib/rubik/ui/dialog.rb` (`Rubik::UI::Dialog`)

- `tty-prompt` motoru (`TTY::Prompt.new`) üzerinden `select` ve `multi_select` kullanımı (Rubik'in `Approvals` modülündeki tema ve çerçeveleme ile uyumlu).
- `Rubik::UI::Frame.draw` kartı içerisinde soru başlığı ve tavsiye edilen seçenek vurgulaması.
- Windows ve POSIX uyumlu ok tuşları ve sayı tuşları (`1..N`) desteği.
- Test edilebilirlik: `Dialog.new(prompt: mock_prompt)` enjeksiyonu ile testlerde sanal klavye girdisi simülasyonu.

### 🔌 Faz C: Orkestrasyon ve REPL Entegrasyonu
- `Composition.build` içinde `tools.interactive` ayarı ile register edilmesi.
- Oturum loguna (`Session::Recorder`) `question_asked` ve `answer_received` denetim olaylarının yazılması.
- Yapılandırma Knob'u: `interactive.auto_select_recommended = true` (varsayılan açık).

---

## 🧪 4. Test Senaryoları ve Kabul Kriterleri

1. **Tekli Seçim (Single Select):** Kullanıcının 1. veya 2. seçeneği seçtiği ve cevabın modele `User response: Option A` olarak döndüğü doğrulanır.
2. **Çoklu Seçim (Multi Select):** `is_multi_select: true` olduğunda birden çok seçeneğin dizi formatında döndüğü doğrulanır.
3. **Serbest Metin (Custom Write-in):** Kullanıcının listede olmayan özel bir metin yazdığında doğru iletildiği doğrulanır.
4. **Non-Interactive Otomatik Seçim:** Stdin kapalıyken aracın çökmeyip `(Recommended)` seçeneği otomatik seçtiği doğrulanır.
5. **Geçersiz Parametre Doğrulaması:** Tek seçenekli veya seçeneksiz çağrılarda Elm-tarzı rehberlik sunulduğu teyit edilir.
6. **Ctrl+C İptal Güvenliği:** Soru esnasında kesinti geldiğinde terminal ham (raw) modda kalmaz, temiz şekilde REPL'e döner.

---

## 📝 5. Dosya Tavanları ve Hijyen

- `lib/rubik/tools/builtins/interactive.rb`: < 150 satır (Gerçekleşen: 127 satır)
- `lib/rubik/ui/dialog.rb`: < 200 satır (Gerçekleşen: 102 satır)
- `test/unit/test_ask_question_tool.rb`: Kapsamlı minitest testi (17 test, 63 assertions)

---

## 🚀 6. Uygulama Sonucu ve Doğrulama Metrikleri

Plan 92 başarıyla uygulanmış ve tüm kabul kriterleri sağlanmıştır:

1. **`Rubik::UI::Dialog` (`lib/rubik/ui/dialog.rb` - 102 satır):**
   - `ask_single` ve `ask_multi` metotları `TTY::Prompt` entegrasyonu ile uygulandı.
   - `Rubik::UI::Frame.draw` kartı ile `Theme.for` destekli şık soru görselleştirmesi sağlandı.
   - `Rubik::UI::Capability.interactive?` ile non-interactive/CI tespiti yapıldı.
   - `Rubik::REPL::InterruptHandler.restore_console_after_interrupt` ile kesintilerde konsol güvenliği sağlandı.
2. **`Rubik::Tools::AskQuestionTool` (`lib/rubik/tools/builtins/interactive.rb` - 127 satır):**
   - Parametre şeması (`questions` dizisi, en az 2 seçenek) tam olarak doğrulandı.
   - Non-interactive ortamlarda çökmeyi önleyen ve `(Recommended)` seçeneğine öncelik veren akıllı otomatik seçim mekanizması kuruldu.
   - Takma adlar: `ask`, `question`, risk: `:read`.
3. **Kayıt ve Modül Hijyeni:**
   - `lib/rubik/tools/builtins.rb` ve `lib/rubik/tools/registry.rb` içine eklendi; varsayılan araç kütüğü 23'ten 24'e yükseltildi.
4. **Test ve Doğrulama:**
   - `test/unit/test_ask_question_tool.rb`: 17 test, 63 assertions (%100 yeşil).
   - `test/unit/test_module_hygiene.rb`: 8 test, 53 assertions (%100 yeşil).
   - `test/unit/test_tool_aliasing_and_naming.rb`: 9 test, 113 assertions (%100 yeşil).
   - `test/unit/test_expanded_tools.rb`: 19 test, 128 assertions (%100 yeşil).
   - `rubocop`: 0 offenses.

---

## 🔍 7. Fresh-Eye Review Bulguları ve Yapılan Düzeltmeler

16a81c81 commit'i bağımsız fresh-eye gözüyle incelenmiş, şu bulgular tespit edilip düzeltilmiştir:

1. **[F-1] Çoklu Soru İptal Tuzağı (Prompt Cascade Abort):**
   - *Bulgu:* Kullanıcı 1. soruyu Ctrl+C ile iptal ettiğinde araç sonraki soruları sormaya devam ediyordu.
   - *Düzeltme:* `execute` döngüsüne erken kesme (`break if res[:cancelled]`) eklendi; ilk soruda gelen iptal tüm soru akışını sonlandırıp modeli haberdar eder.
2. **[F-2] Özel Yanıt (Custom Write-in) Sözleşmesi:**
   - *Bulgu:* `Dialog#ask_single` serbest metin yanıtını yalın string olarak döndürdüğü için `AskQuestionTool` kontratındaki `User response (custom write-in): ...` formatı tetiklenmiyordu.
   - *Düzeltme:* `Dialog#ask_single` metodu `Other (write-in): <cevap>` ön eki ile dönecek şekilde ayarlandı ve `AskQuestionTool` bu ön eki arındırarak temiz biçimlendirdi.
3. **[F-3] Girdi Sağlamlaştırma (Input Resilience):**
   - *Bulgu:* `questions` dizisi içinde `Hash` olmayan bir eleman (örn. doğrudan string) veya mükerrer seçenekler nedeniyle 2'den az benzersiz seçenek kaldığında kontrol yetersizdi. Ayrıca tek soruluk çağrılar doğrudan `{ question: ..., options: ... }` ile yapıldığında hata alıyordu.
   - *Düzeltme:* `q_data.is_a?(Hash)` kontrolü, `options.uniq.size >= 2` kontrolü ve tekil soru argüman normalizasyonu eklendi.
4. **[F-4] Konsol Sıfırlama ve TTY Koruması:**
   - *Bulgu:* `Dialog#interactive?`, `@shell` nil iken `$stdin`/`$stdout` TTY durumunu kontrol etmiyordu. `StandardError` durumunda konsol sıfırlanmıyordu.
   - *Düzeltme:* `rescue Interrupt, StandardError` ile tüm istisnalarda konsol sıfırlandı ve `$stdin`/`$stdout` fallback TTY denetimi eklendi.
5. **[F-5] Dokümantasyon Senkronizasyonu:**
   - *Bulgu:* `TOOLS.md` ve `ARCHITECTURE.md` dosyaları 22 araç listelemeye devam ediyordu.
   - *Düzeltme:* Her iki dosya da 24 yerleşik araca güncellendi; `TOOLS.md` içine `ask_question` parametreleri, TUI davranışı ve Elm hata şablonları eklendi.
