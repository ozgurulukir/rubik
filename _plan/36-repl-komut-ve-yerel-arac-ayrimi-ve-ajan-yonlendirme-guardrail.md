# 📋 Plan 36: REPL Komutu / Yerel Araç Ayrımı, Ajan Operasyonel Kuralları ve Komut Döngüsü Guardrail'ı

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** ✅ **Tamamlandı** (193/193 Test %100 Yeşil)

---

## 🎯 Amaç ve Problem Tanımı

### Problem
Kullanıcı serbest metin olarak *"deep review yap"*, *"kodları incele"* veya *"projeyi analiz et"* gibi isteklerde bulunduğunda, model doğrudan `list_files`, `search_symbols` ve `read_file` araçlarını çağırmak yerine sistem isteminde listelenen insan REPL komutlarına (`<repl_commands>`) bakarak `exec_repl_command("!review")` veya `exec_repl_command("!check")` gibi hayali komutlar çağırmaktadır. Bilinmeyen komut yanıtında 38 REPL komutunun listesi dönünce model sırayla `!status`, `!symbols`, `!diff`, `!outline` çağırarak sonsuz bir REPL komut döngüsüne (tool confusion loop) girmektedir.

### Çözüm
1. **İnsan REPL Alanı ile Ajan Araç Alanının Ayrılması:**
   - İnsanın terminalde kullandığı 38 interaktif komut listesi (`<repl_commands>`) genel sistem isteminden temizlenir (400+ token tasarrufu ve kafa karışıklığının engellenmesi).
   - Sistem istemine net `<operational_rules>` eklenerek modelin dosya okuma, arama, test ve kod incelemesi için doğrudan yerel araçları (`read_file`, `list_files`, `get_outline`, `search_symbols`, `run_tests`) kullanması garanti altına alınır.
2. **`ExecReplCommandTool` Akıllı Yönlendirme ve Guardrail:**
   - Model `exec_repl_command("!test")` veya `exec_repl_command("!sh")` gibi yerel aracı olan bir komut çağırdığında, doğrudan `"Notice: Please use native tool 'run_tests' / 'run_command' directly instead of exec_repl_command."` yönlendirmesi yapılır.
   - Model `exec_repl_command("!review")` gibi var olmayan bir komut çağırdığında 38 komut dökülmez; doğrudan dosya okuma ve sembol araçlarına yönlendirici mesaj döner.

---

## 🏛️ Mimari Ayrıntılar

### 1. `Rubik::Prompt::ContextBuilder`
- `build_system_context`: `<repl_commands>` blokunu kaldırır (yalnızca dinamik sentezlenmiş özel komutlar varsa eklenir).
- `build_system_prompt`: `<operational_rules>` bölümü ekler:
  - Kod İnceleme / Keşif: `list_files`, `get_outline`, `search_symbols`, `read_file`.
  - Kod Yazma / Düzenleme: `write_file`.
  - Test ve Çalıştırma: `run_tests`, `run_command`.
  - Asla `!review`, `!check` gibi hayali REPL komutları aranmamalı; dosyalar doğrudan okunmalıdır.

### 2. `Rubik::Tools::ExecReplCommandTool`
- Açıklama (`description`): `"Execute internal Rubik REPL configuration commands (!config, !model, !undo, !rollback, !runtime, !fibers, !services). Do NOT use this tool for reading files, writing code, or running tests—use direct tools (read_file, write_file, run_tests) instead."`
- Yönlendirme Haritası (Redirect Map):
  - `!test` $\rightarrow$ `run_tests`
  - `!sh` $\rightarrow$ `run_command`
  - `!read` $\rightarrow$ `read_file`
  - `!outline` $\rightarrow$ `get_outline`
  - `!symbols` $\rightarrow$ `search_symbols`
- Bilinmeyen Komut Hatası:
  - `"Unknown REPL command '!#{cmd}'. To explore files, read code, or do a review, use direct tools ('list_files', 'read_file', 'search_symbols') instead of REPL commands."`

---

## 🧪 Test Planı

`test/unit/test_repl_tool_separation_and_guardrails.rb`:
1. Sistem isteminde 38 komut kirliliği olmadığını ve `<operational_rules>` bulunduğunu doğrula.
2. `exec_repl_command("!test")` ve `exec_repl_command("!sh")` çağrılarının yerel araçlara yönlendirdiğini test et.
3. `exec_repl_command("!review")` çağrısının 38 komut listelemek yerine rehber hata mesajı döndüğünü test et.
4. Meşru meta komutların (`!model`, `!status`, `!context`) sorunsuz çalıştığını test et.
5. Tüm test paketinin (184+ test) regresyonsuz yeşil olduğunu doğrula.
