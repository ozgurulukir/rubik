# 📋 Plan: Komut Allowlist — Operatör Kontrollü Komut Whitelist Kapısı

> **Kaynak:** Canlı penetrasyon turu (14 Eylül 2026) — `node .gitnexus/run.cjs impact ...` komutu `Guard` sınıflandırıcısına takıldı; operatörün komut bazlı istisna verme mekanizması yok.
> **Tarih:** 14 Eylül 2026 (Pzt)
> **Durum:** ✅ Uygulandı (2026-09-14) — A/B0/B/C/D/F paketleri tamam; kilitleyen testler `test_command_allowlist.rb`, `test_allow_cmd_repl_command.rb`; kabul sondaları `dev/verify_allowlist.rb` (8/8 PASS)
> **İlgili planlar:** [12](12-guvenlik-diff-onay.md) (Guard), [48](48-harici-erisim-izinli-dizinler-ve-sifir-ast-sandbox-guvenlik-kapisi.md) (klasör fence'i — desen öncülü), [81](81-bash-ve-powershell-treesitter-guvenli-calistirma-ve-ast-katmani.md) (sınıflandırıcı), [43](43-repl-komut-modulerizasyonu-domain-driven-command-decoupling.md) (komut modülerliği)

---

## 🎯 Hedef

`Guard#verify_command_safety!` bugün fail-closed: sınıflandırıcının **bilmediği veya DANGEROUS dediği** her komutu reddediyor, ancak operatöre "bu komut ailesine güveniyorum" diyebileceği bir kapı yok (`!allow` yalnızca klasör çiti — `allowed_external_dirs`). Gerçek vakalar: GitNexus CLI (`node .gitnexus/run.cjs`), proje-özel betikler, makineye özgü araçlar.

**Çözüm:** `security.command_allowlist` config ad alanı + `Guard` içinde sınıflandırıcı sonrası allowlist kontrolü + operatör-only `!allow-cmd` REPL komutu. Model kendi iznini **asla** veremez (audience + çağrıcı-kaynağı kontrolü).

**İsimlendirme kararı (operatör onaylı):** klasör komutu `!allow`, daha açıklayıcı olan `!allow-dir` adına **terfi ettirilir** (alias Plan 48'de zaten kayıtlı — düşük risk); `!allow` tek satırlık deprekasyon uyarısı basan alias olarak bir süre daha yaşar. Komut allowlist'i simetrik adla `!allow-cmd` olur.

**Kısıtlar:** AGENTS.md §6'ya uygun; catastrophic regex katmanı allowlist'le bile **atlanamaz** (defense-in-depth korunur); yeni global durum eklenmez (config + Guard ivar); kırıcı değişiklik yok.

---

## 🔍 Etki Analizi (kök neden + dokunma yüzeyi)

### Kök neden zinciri (canlı turda doğrulandı)

1. `node.yaml:4` → `classification: DANGEROUS` — tüm `node` ikilisi tek seferde damgalı (gerekçe: `node -e` keyfi JS çalıştırır). Alt-komut ayrımı yok.
2. `matcher.rb:40-46` → veritabanında olmayan ikililer `UNKNOWN` + `risk: HIGH`.
3. `Guard#verify_command_safety!` (`guard.rb:131-149`) → `:dangerous` → `BlockedWriteError`; `:unknown` → fallback regex'e düşer.
4. **Kaçış yok:** `repair_runtime_service` kaydı yetki vermez; `synthesize_tool` muhafızı süreç-başlatan Ruby kodunu yasaklar (tasarım gereği — kum havuzu baypası kapalı).

### Dokunma yüzeyi

| Nokta | Dosya:Satır | Değişim |
| :--- | :--- | :--- |
| Guard çekirdek | `security/guard.rb` (`verify_command_safety!`, yeni `allowlisted?`) | Allowlist kontrolü eklenir |
| Guard kurulumu | `repl/composition.rb:70` | `command_allowlist` config'den enjekte |
| Config default | `config/defaults.rb:50-52` | `"command_allowlist" => []` |
| Reaktif kablolama | `repl/config_wiring.rb` (desen: `workspace.allowed_external_dirs`, sat. 73-88) | `security.command_allowlist` → guard güncelle |
| Yeni REPL komutu | `repl/commands/workspace.rb` (desen: `register_allow_command`, sat. 152-246) | `register_allow_cmd_command` |
| Yanlış yönlendirme metni | `tools/builtins/exec.rb:134-140` | Mesaj `!allow-cmd` (komutlar) + `!allow-dir` (klasörler) ikili yönlendirmesine çevrilir |
| Komut yeniden adlandırma | `repl/commands/workspace.rb:242-245` | `!allow-dir` birincil (tam açıklamalı); `!allow` deprekasyon alias'ı (uyarı basan sarmalayıcı → aynı handler) |
| Yönlendirme mesajları | `tools/diagnostic_reporter.rb:172,203` | `!allow <path>` → `!allow-dir <path>` |
| README komut tablosu | `README.md:159` | `!allow` → `!allow-dir` |
| Test yüzeyi | `test_allowed_external_dirs.rb`, `test_expanded_tools.rb:66`, `test_agent_command_contract.rb:142`, `test_repl_tool_separation_and_guardrails.rb:55`, `test_elm_system_diagnostics_and_utf8_resilience.rb:220,239` | Birincil komut `!allow-dir`'e geçer; `!allow` için bir deprekasyon-alias testi eklenir |
| Model self-allowlist deliği | `repl/commands/workspace.rb:248-249` (`!config`, `audience: :both`) | İşi paketi D — security.* seti kısıtı |
| Tool kontratı | `tools/builtins/exec.rb:91` (`RunCommandTool` description) | Operatör allowlist kapısı notu (Paket F) |

### Kritik güvenlik bulgusu (plan kapsamına girdi)

- `!config` komutu `audience: :both` → model `exec_repl_command("!config set security.command_allowlist ...")` ile **kendi allowlist'ini yazabilir**. Aynı delik bugün `sandbox.enabled` için de mevcut. İşi Paketi D bunu kapatır.
- `verify_synthesis_safety!` allowlist'ten **etkilenmez** — sentez desenleri Ruby kod yüzeyi, allowlist shell komut yüzeyi; ayrık kalır.

---

## 🏗️ Tasarım

### 0. İsimlendirme — klasör komutunun yeniden adlandırılması

| Bugün | Karar | Gerekçe |
| :--- | :--- | :--- |
| `!allow <path>` (birincil) + `!allow-dir` (alias, Plan 48) | **`!allow-dir` birincil**, `!allow` deprekasyon alias'ı | `allow` tek başına *neyin* izinlendiğini söylemiyor; `allow-dir`/`allow-cmd` ikilisi iki güvenlik alanını simetrik ve kendini anlatır yapıyor |
| — | `!allow-cmd` (yeni) | Komut allowlist'i; `!allow` ailesinden **bağımsız** komut (ayrık alanlar tek çatıya zorlanmaz) |

- `!allow` alias'ı sarmalayıcıyla tek satırlık deprekasyon uyarısı basar, sonra aynı handler'ı çalıştırır — sessiz kırılım yok (operatör kas hafızası + Plan 48 dokümantasyonu korunur).
- Handler çıktı etiketi `[Rubik::Allow]` olduğu gibi kalır (modül adı; churn'u sınırlamak için değiştirilmez — kapsam dışı).
- `!workspace allow <path>` alt-komutu ebeveyn bağlamıyla zaten açık; dokunulmaz.
- Reddedilen alternatif: `!allow`'ı tamamen silmek — README + Plan 48 + tanılama mesajları bugün `!allow`'a yönlendiriyor; sert kırılım gereksiz risk.

### 1. Config şeması

```ruby
"security" => {
  "audit_log_path" => ...,
  "command_allowlist" => []  # her giriş: token dizisi (örn. "node .gitnexus/run.cjs")
}
```

Giriş formatı: **token-prefix** (boşlukla bölünür). `node` (tek token) geniş; `node .gitnexus/run.cjs` dar — operatöre dar giriş önerilir.

### 2. Guard entegrasyonu (`verify_command_safety!` içi, raise'den önce)

```ruby
if ast.classification == :dangerous
  reason = dangerous_reason(ast.commands)
  if command_allowlisted?(ast)   # TÜM dangerous komutlar (recursive inner dahil) eşleşmeli
    log_audit("allowed_command", command: cmd_str, reason: "operator_allowlist")
    return true
  end
  raise BlockedWriteError, ...
end
# :unknown düşüşü: allowlist eşleşirse de ÖNCE catastrophic regex çalışır
```

**Değişmezler:**
- Pipeline/segment farkındalığı sınıflandırıcının `ast.commands` + `inner_commands` yürüyüşünden gelir (`dangerous_reason` deseni) — string-prefix naive eşleşme **kullanılmaz** (`node a.js; rm -rf /` gibi zincirlerde tek segment allowlist'i tümünü kurtaramaz).
- `verify_command_fallback_regex!` allowlist'ten **sonra da** çalışır: fork bombası, `rm -rf /` kalıpları allowlist'te bile bloke.
- Her izin `log_audit` ile izlenir (bloklar gibi) — audit log iki yönlü kanıt tutar.

### 3. `!allow-cmd` REPL komutu (`audience: :human` — model çağıramaz)

```
!allow-cmd add "node .gitnexus/run.cjs" [--project|--global] [--force]
!allow-cmd list | remove <prefix>
```

- `Base.parse_scope` ile `--project|--global` kalıcılığı (`config.set(..., persist: scope)` — `!allow-dir` deseni).
- Ekleme anında giriş ilk-token'ı sınıflandırıcıda DANGEROUS çıkarsa (örn. `node`) **uyarı** basılır; geniş giriş `--force` ister (fail-closed UX).
- `remove` LIFO gerektirmez — config + guard senkron yürür (Config on_change reaktivitesi tek doğruluk kaynağı).

### 4. Reaktif kablolama

`config_wiring.rb` → `when "security.command_allowlist"` → `shell.guard.set_allowed_commands(typed_val)` (desen: sat. 73-88). Canlı rekonfigürasyon, sıfır restart (Plan 75 deseni).

### 5. Hata mesajı düzeltmesi (`exec.rb`)

`Security blocked` ekinde: `"...ask the human operator to allowlist it via the !allow command"` → `"...via the !allow-cmd command (operator-only; !allow-dir is for external directories)."` — model bugün yanlış komuta yönlendiriliyor; yeni mesaj her iki alanı da doğru adla işaret eder.

---

## 📦 İş Paketleri

- **A — Guard allowlist çekirdeği:** `Guard.new(command_allowlist: [])`, `#command_allowlisted?` (recursive argv-prefix), `verify_command_safety!` entegrasyonu, audit aksiyonları. Birim testler: allowlist'li komut geçer; eşleşmeyen yine bloklar; `rm -rf /` allowlist'liyken bile regex'ten bloklanır; çoklu-segment zincirde kısmi eşleşme kurtarmaz; `:unknown` + allowlist + temiz → geçer.
- **B0 — `!allow` → `!allow-dir` rename (bağımsız, mekanik):** alias terfisi + `!allow` deprekasyon sarmalayıcısı + usage string'leri + `diagnostic_reporter` mesajları + README satırı + test güncellemesi. Davranış değişmez; yalnızca yüzey adı.
- **B — REPL komutları + config default + reaktif kablolama:** `!allow-cmd` (human-only), `--force` uyarı akışı, `config_wiring` kolu. Testler: REPL iş akışı (ekle→listele→çalışır→kaldır→bloklar), geniş-giriş `--force` zorunluluğu, config değişiminin canlı etki etmesi.
- **C — Ekipman düzeltmeleri:** `exec.rb:139` mesajı; `exec_repl_command` üzerinden `!allow-cmd` çağrısının `audience: :human` sayesinde fail-closed olduğu testi (model self-allowlist yasağı).
- **D — `!config` güvenlik ad alanı kısıtı (delik kapatma):** `!config set security.*` (ve `sandbox.*`) anahtarları agent çağrısından bloklansın. Taslak: `ExecReplCommandTool#execute` `execute_input` sarmalarken `shell.agent_caller = true` (ensure ile sıfırlar); config set handler bu bayrak + key-prefix kontrolüyle reddeder. Kapsam: küçük, izole, fail-closed.
- **E — Dokümantasyon:** `dev/README.md` veya Guard bölümüne allowlist sözleşmesi; audit log aksiyon adları.
- **F — Tool kontratı + prompt yüzeyi:** `RunCommandTool` description'una allowlist kapısı cümlesi ("operator-allowlisted commands may pass; otherwise ask the human operator to run `!allow-cmd <prefix>`"); `exec.rb` blocked mesajı Paket C ile tutarlı tek yönlendirme; `<agent_commands>` kümesi (`!allow-dir`, `!allow-cmd` human-only) korunur — prompt'a komut adı sızdırılmaz, yalnızca kapının varlığı anlatılır. Test: tool contract testinde description iddiası.

## ✅ Kabul Kriterleri

1. Operatör `!allow-cmd add "node .gitnexus/run.cjs"` dedikten sonra modelin `run_command`'i bu prefix'li komutlarda başarılı; diğer `node ...` komutları hâlâ bloklu.
2. Allowlist'liyken dahi `rm -rf /` ve fork bombası blok (catastrophic regex atlı değil).
3. Model `!allow-cmd` ve `!config set security.*` çağrılarından kaliteli reddetme mesajı alıyor.
4. Audit log'da `blocked_command` / `allowed_command` ikilisi izlenebilir.
5. Tüm test suite yeşil; yeni birim testler A/B0/B/C/D paketlerini kilitliyor.
6. `!allow-dir` yardım/usage'da birincil komut olarak görünüyor; `!allow` çağrısı aynı işi yapıp tek satırlık deprekasyon uyarısı basıyor; prompt'un `<agent_commands>` kümesinde ikisi de yok (human-only korunuyor).
7. `RunCommandTool` kontratı (description) allowlist kapısını anlatıyor; bloke mesajı operatöre tek doğru komutla (`!allow-cmd`) yönlendiriyor.

## ⏭️ Ertelenenler

- Glob/trailing-wildcard girişleri (`node .gitnexus/*`) — token-prefix MVP'den sonra değerlendirilir.
- Allowlist girişlerine süre/geçerlilik (TTL) meta'sı.
- `gitnexus://` MCP kaynaklarının bağlanması ayrı takip (MCP komutları da aynı Guard'dan geçer — allowlist onlara da uygulanır).
- `!allow` deprecated alias'ının kaldırma takvimi: önce yalnız-uyarı minor sürüm, silme major'da.
