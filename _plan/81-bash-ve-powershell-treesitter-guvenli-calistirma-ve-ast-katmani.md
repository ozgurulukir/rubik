# 📋 Plan 81: Bash ve PowerShell Tree-Sitter AST Güvenli Çalıştırma Katmanı (bash-classify Ruby Portu, 168+ CLI Tanımı, Pwsh Desteği ve Guard Entegrasyonu)

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟡 **Planlandı** · **Zorluk:** Zor · **Faz:** 6  
> **İlgili Planlar:** [12](12-guvenlik-diff-onay.md), [49](49-tam-kapsamli-cross-platform-ve-windows-uyumluluk-mimarisi.md), [55](55-run-command-platform-kapili-kabuk-secimi.md), [59](59-cekirdek-guvenligi-sentez-sandbox-bare-rescue-ve-moduler-testler.md), [60](60-kritik-yol-guvenligi-sandbox-timeout-ve-kod-sagligi.md), [79](79-guvenlik-baslatma-izolasyonu-sandbox-seffafligi-ve-repl-sh-tamiri.md), [80](80-sandbox-mimari-refaktoru-guarded-runner-bubblewrap-ve-wasm-konumlandirmasi.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

Rubik'in mevcut komut çalıştırma kalkanı ([`Rubik::Security::Guard#verify_command_safety!`](../lib/rubik/security/guard.rb#L138-L147)), komut güvenliğini yalnızca statik düzenli ifadeler (`DANGEROUS_COMMAND_PATTERNS`) ile denetlemektedir. Bu yaklaşımın iki büyük açığı bulunmaktadır:

1. **Yanlış Pozitifler (False Positives):** `echo "do not run rm -rf /"` veya `git commit -m "fix rm -rf /"` gibi sadece string veya açıklama içinde geçen komutlar, ajanın veya kullanıcının çalışmasını gereksiz yere engeller.
2. **Sözdizimsel Atlatma & Delegasyon (Obfuscation & Delegation Evasion):** `sh -c "rm -rf /"`, `find . -exec rm -f {} \;`, `sudo rm -rf /`, `cat file > /etc/hosts` veya değişkenler ardına gizlenmiş komutlar düz regex ile tespit edilemez veya eksik yakalanır.
3. **Tek Tip Karar Mekanizması:** Sistem yalnızca "İzin Ver" veya "Engelle" diyebilir; "Bu komut salt-okunurdur, sürtünmesiz çalıştır", "Bu komut yerel dosya değiştirir, izle", "Bu komut ağa çıkar, dikkat et" gibi kademeli risk sınıflandırması yapamaz.
4. **Cross-Platform & Windows/PowerShell İhtiyacı:** Windows ortamında PowerShell (`pwsh`) komutları (`Remove-Item -Recurse C:\`, `Invoke-WebRequest`, `Stop-Process`) bash sözdiziminden farklıdır. Güvenlik katmanının hem POSIX/Bash hem de Windows/PowerShell sözdizimlerini AST düzeyinde tanıması gerekir.

Bu plan ile:
- Modern **`bash-classify`** (Filip Prochazka, MIT) projesi saf Ruby'ye port edilmektedir.
- [`tree_sitter_language_pack`](https://github.com/xberg-io/tree-sitter-language-pack) (v1.16+) gem'i sisteme eklenerek hem **Bash** hem de **PowerShell** için pre-compiled, sıfır C derleme maliyetli AST motoru entegre edilmektedir.
- Bu adım aynı zamanda Rubik'in gelecekteki **370+ dilli Codebase Intelligence** vizyonuna hazır bir zemin oluşturur.
- 168 adet popüler CLI aracının alt komut ve opsiyon kuralları (`commands/*.yaml`) ve PowerShell cmdlet tanımları Rubik'e dahil edilir.

---

## 🏛️ 2. Mimari Tasarım ve Veri Akışı

```
                               ┌────────────────────────────────┐
                               │   Rubik Command / Tool Call    │
                               │  (!sh, RunCommandTool, Agent)  │
                               └───────────────┬────────────────┘
                                               │ cmd_string (bash / pwsh)
                                               ▼
                               ┌────────────────────────────────┐
                               │     Rubik::Security::Guard     │
                               └───────────────┬────────────────┘
                                               │ verify_command_safety!(cmd)
                                               ▼
                    ┌────────────────────────────────────────────────────────┐
                    │          Rubik::Security::Classifier                   │
                    │               (Unified Facade)                         │
                    └──────────────────────────┬─────────────────────────────┘
                                               │
               ┌───────────────────────────────┴───────────────────────────────┐
               ▼                                                               ▼
┌──────────────────────────────┐                                ┌──────────────────────────────┐
│       BashParser (AST)       │                                │       PwshParser (AST)       │
│  (TreeSitter Bash Grammar)   │                                │ (TreeSitter PowerShell Gram) │
├──────────────────────────────┤                                ├──────────────────────────────┤
│ • Pipeline ( | , |& )        │                                │ • Pipeline & PipelineChain   │
│ • Logic ( && , || , ; )      │                                │ • Cmdlets & Parameters       │
│ • Redirects ( > , >> , < )   │                                │ • Operators & Redirections   │
│ • Subshells & Substitutions  │                                │ • ScriptBlocks { ... }       │
└──────────────┬───────────────┘                                └──────────────┬───────────────┘
               │                                                               │
               └───────────────────────────────┬───────────────────────────────┘
                                               ▼
                               ┌────────────────────────────────┐
                               │    CommandDatabase (YAML)      │
                               │  • 168+ Bash CLI Yaml Files    │
                               │  • Built-in PowerShell Cmdlets │
                               │  • Lazy-loading O(1) Cache     │
                               └───────────────┬────────────────┘
                                               ▼
                               ┌────────────────────────────────┐
                               │      Matcher & Classifier      │
                               │  • Subcommands & Aliases       │
                               │  • Delegation Resolution       │
                               │    (sudo, xargs, find, sh -c)  │
                               │  • System Path Elevations      │
                               │    (/etc, /usr vs /tmp)        │
                               └───────────────┬────────────────┘
                                               ▼
                               ┌────────────────────────────────┐
                               │      ExpressionResult          │
                               │  • classification (:readonly   │
                               │    :local_effects, :dangerous) │
                               │  • risk (:low, :med, :high)    │
                               │  • write_paths, read_paths     │
                               └───────────────┬────────────────┘
                                               │
             ┌─────────────────────────────────┼─────────────────────────────────┐
             ▼                                 ▼                                 ▼
   [ READONLY / LOW ]               [ LOCAL_EFFECTS / MED ]             [ DANGEROUS / HIGH ]
 (ls, cat, git status)             (mkdir, git commit, build)          (rm -rf /, > /etc/hosts)
             │                                 │                                 │
             ▼                                 ▼                                 ▼
      🟢 Auto-Allow                     🟡 Normal Run                     🔴 BlockedWriteError
     (Sıfır Sürtünme)               (Sandbox / Buffer İzleme)              (Guard İstisnası)
```

---

## 🔧 3. Detaylı Bileşenler ve Uygulama Adımları

### 3.1. Gemspec ve Bağımlılıklar
- `rubik.gemspec` dosyasına `spec.add_dependency "tree_sitter_language_pack", "~> 1.16"` eklenmesi.
- `bundle install` ile kilitlenmesi.
- Gem, Linux x86_64, aarch64, macOS için önceden derlenmiş native binary sunar; ilk kullanımda grameri `~/.cache` dizininde önbelleğe alır.

### 3.2. Modeller: `lib/rubik/security/classifier/models.rb`
Ruby 3.4 `Data.define` kullanılarak immutable ve bellek dostu:
- `Classification`: `:readonly` (0), `:local_effects` (1), `:external_effects` (2), `:unknown` (3), `:dangerous` (4).
  - Şiddet sıralaması: `DANGEROUS > UNKNOWN > EXTERNAL_EFFECTS > LOCAL_EFFECTS > READONLY`.
- `Risk`: `:low` (0), `:medium` (1), `:high` (2).
  - Şiddet sıralaması: `HIGH > MEDIUM > LOW`.
- `DelegationMode`: `:rest_are_argv`, `:after_separator`, `:terminated_argv`, `:flag_value_is_expression`, `:args_are_expression`.
- `SubcommandMode`: `:hierarchical`, `:match_all`.
- `Redirect`: `operator:`, `target:`, `affects_classification:`.
- `CommandInvocation`: `argv:`, `redirects:`, `position_in_pipeline:`, `pipeline_length:`, `context:`, `operator_before:`, `is_background:`, `raw_text:`.
- `CommandResult`: `command:`, `argv:`, `classification:`, `risk:`, `matched_rule:`, `inner_commands:`, `options:`, `positionals:`, `classification_reason:`, `write_paths:`, `read_paths:`.
- `ExpressionResult`: `expression:`, `classification:`, `risk:`, `commands:`, `directories:`, `write_paths:`, `read_paths:`, `parse_warnings:`.

### 3.3. Komut Veritabanı: `lib/rubik/security/classifier/database.rb`
- `/tmp/bash-classify/src/bash_classify/commands/*.yaml` dosyalarının (168 dosya) `lib/rubik/security/classifier/commands/` altına kopyalanması.
- PowerShell için temel cmdlet ve takma ad tanımlarının (`lib/rubik/security/classifier/pwsh_commands/` veya yerleşik harita):
  - `Remove-Item` (`del`, `erase`, `rd`, `ri`, `rm`, `rmdir`) -> `DANGEROUS` (özellikle `-Recurse`, `-Force`, kök sürücüler `C:\`).
  - `Get-ChildItem` (`dir`, `gci`, `ls`) -> `READONLY`.
  - `Get-Content` (`cat`, `gc`, `type`) -> `READONLY`.
  - `Stop-Process` (`kill`, `spps`) -> `LOCAL_EFFECTS` / `MEDIUM`.
  - `Invoke-WebRequest` (`curl`, `iwr`, `wget`), `Invoke-RestMethod` (`irm`) -> `EXTERNAL_EFFECTS`.
  - `Start-Process` (`saps`, `start`) -> delegasyon veya `LOCAL_EFFECTS`.
  - `Set-Content` (`sc`), `Add-Content` (`ac`), `Out-File` -> `LOCAL_EFFECTS` (sistem yollarında `DANGEROUS`).
- `CommandDatabase`:
  - `Psych` (`YAML.safe_load`) ile thread-safe lazy-loading (`Monitor`).
  - İlk erişimde diskten okunur ve bellekte cache'lenir (O(1) sonraki aramalar).

### 3.4. Tree-Sitter Parsers: `lib/rubik/security/classifier/parsers/`
- **`BashParser` (`lib/rubik/security/classifier/parsers/bash.rb`):**
  - `TreeSitterLanguagePack.get_parser("bash")` ile CST üretimi.
  - Node ziyaretçisi (Visitor):
    - `pipeline`, `list` (`&&`, `||`, `;`, `&`),
    - `command`, `variable_assignment` (önek atamalarını ayırma),
    - `file_redirect`, `heredoc_redirect` (gövdeyi atlayıp satır içi devamı yakalama),
    - `subshell`, `command_substitution`, `process_substitution`.
    - Tırnak unquoting (`"..."`, `'...'`, `$'...'`).
- **`PowerShellParser` (`lib/rubik/security/classifier/parsers/powershell.rb`):**
  - `TreeSitterLanguagePack.get_parser("powershell")` ile CST üretimi.
  - `statement_list`, `pipeline`, `pipeline_chain`, `command`.
  - `command_name`, `command_parameter` (`-Recurse`, `-Force`), `generic_token`, `array_literal_expression`.
  - Yönlendirmeler (`>`, `>>`) ve pipeline bağlantıları.

### 3.5. Matcher ve Classifier Motoru: `lib/rubik/security/classifier/matcher.rb` & `classifier.rb`
- Binary ve alias çözümleme (`glab mr note`, `kubectl exec`, `git push`, `docker run`).
- Global bayrakları ayırma (`git -C /path`, `kubectl --context=prod`).
- Alt komut hiyerarşisi (`hierarchical`) ve toplu eşleşme (`match_all` - Maven `clean install`).
- Bayrak ve opsiyon değer çözümlemesi (`-o file`, `-rf`, `--namespace=prod`).
- İç delegasyon kuralları:
  - `sudo`, `xargs`, `timeout` (`rest_are_argv`),
  - `sh -c`, `bash -c`, `pwsh -c` (`flag_value_is_expression`),
  - `find -exec` (`terminated_argv`).
- Sistem dizini yükseltmeleri:
  - `/etc`, `/usr`, `/boot`, `/bin`, `/sbin`, Windows `C:\Windows`, `C:\System32` yazma veya silme denemeleri → `DANGEROUS`, `Risk.HIGH`.
  - `/tmp`, `/var/tmp` veya yerel çalışma alanı geçici dosyaları → Güvenli `LOCAL_EFFECTS` / `Risk.LOW`.
  - `/dev/tcp`, `/dev/udp` soket yönlendirmeleri → `DANGEROUS`, `Risk.HIGH`.
  - Arka plan çalıştırma (`&`) → `LOCAL_EFFECTS` / `Risk.MEDIUM`.

### 3.6. Rubik Güvenlik Katmanı Entegrasyonu: `lib/rubik/security/guard.rb`
- `verify_command_safety!(cmd)`:
  - `Classifier.classify(cmd)` çalıştırılır.
  - Eğer `classification == :dangerous` veya `risk == :high`:
    - Audit loguna detaylı AST sebebi (`classification_reason`, `matched_rule`, `write_paths`) yazılır.
    - `BlockedWriteError` fırlatılır: `"Dangerous command execution blocked: #{cmd} (reason: #{reason})"`.
  - Statik regex listesi (`DANGEROUS_COMMAND_PATTERNS`) derinlemesine savunma (defense-in-depth) olarak yedekte tutulur.

### 3.7. Sandbox Runner & Tool Risk Raporlama
- `Rubik::Sandbox::Runner#run`:
  - Komut sınıflandırma çıktısını (`res[:classification]`, `res[:risk]`) sonuç özetine ekler.
- `RunCommandTool`:
  - Çıktıda risk bilgisini döndürür.

---

## 🧪 4. Doğrulama ve Test Stratejisi

1. **Birim Testleri:**
   - `test/unit/test_command_classifier_models.rb`: Şiddet sıralaması ve model doğrulaması.
   - `test/unit/test_command_classifier_bash_parser.rb`: Boru hatları, alt kabuklar, yönlendirmeler, heredoc'lar.
   - `test/unit/test_command_classifier_pwsh_parser.rb`: PowerShell cmdlet'leri, parametreleri, pipeline'ları.
   - `test/unit/test_command_classifier_database.rb`: 168 YAML dosyasının yüklenmesi, strict kuralları.
   - `test/unit/test_command_classifier_matcher.rb`: `kubectl`, `git`, `find -exec`, `sh -c`, `sudo`.
   - `test/unit/test_command_classifier_integration.rb`: `SPEC.md`'den alınan doğrulamalar (`kubectl get pods`, `echo "do not run rm -rf /"`, vb.).
   - `test/unit/test_security_guard_classifier.rb`: Guard entegrasyonu, false positive'lerin sıfırlanması, tehlikeli komutların bloklanması.
2. **Regresyon ve Kalite:**
   - `bundle exec rake test`: 1,267+ testin tamamı %100 yeşil kalmalı.
   - `bundle exec rubocop`: 0 offense.
   - `detect_changes`: GitNexus ile grafik analizi.
