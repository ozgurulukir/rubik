# 📋 Plan 41: REPL Komut Modülerizasyonu ve Etki Alanı Ayrımı (Domain-Driven Command Decoupling)

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** Orta · **Faz:** 5 (Mimari İyileştirme & Temiz Kod)  
> **İlgili Planlar:** [02](02-repl-kabugu-ve-etkilesimli-arayuz.md), [20](20-spatiotemporal-runtime-context-ve-fiber-yasam-dongusu.md), [36](36-repl-komut-ve-yerel-arac-ayrimi-ve-ajan-yonlendirme-guardrail.md), [37](37-kademeli-verbosity-ayarlari-ve-canli-ajan-izleme.md), [40](40-coklu-calisma-alani-ve-ek-kok-dizin-erisim-yonetimi.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

### Mevcut Durum (God Method)
- [`lib/rubik/repl/shell.rb`](../lib/rubik/repl/shell.rb) dosyası 1.470 satırdan oluşmakta ve tek bir metot (`register_default_commands`) 980 satır sürmektedir.
- Bu metot içerisinde 41 adet REPL komut bloğu (`!help`, `!diff`, `!apply`, `!undo`, `!rollback`, `!session`, `!workspace`, `!lsp`, `!model`, `!verbosity`, `!runtime` vb.) iç içe 31 nesting derinliğinde tanımlanmıştır.
- Bu durum kod inceleme zorluğu, yüksek birleştirme çakışması (merge conflict) riski ve tek sorumluluk prensibinin (SRP) ihlaline yol açmaktadır.

### Hedef
- `register_default_commands` devasa metodunu etki alanı bazlı (domain-driven) bağımsız komut modüllerine ayırmak:
  - `Rubik::REPL::Commands::Buffer` (`!diff`, `!apply`, `!undo`, `!redo`, `!snapshot`, `!rollback`)
  - `Rubik::REPL::Commands::Session` (`!history`, `!sessions`, `!resume`, `!save-session`)
  - `Rubik::REPL::Commands::Workspace` (`!workspace`, `!roots`, `!config`)
  - `Rubik::REPL::Commands::Lsp` (`!lsp`, `!diagnostics`, `!symbols`)
  - `Rubik::REPL::Commands::Agent` (`!plan`, `!goal`, `!model`, `!verbosity`, `!repair`, `!cost`, `!stats`)
  - `Rubik::REPL::Commands::System` (`!help`, `!clear`, `!version`, `!runtime`, `!fibers`, `!services`, `!plugins`, `!hooks`, `!alias`, `!tools`)
- `Shell` sınıfının sadece çekirdek yönlendirme (core dispatch) ve girdi işleme sorumluluğunu üstlenmesini sağlamak (~250 satıra indirmek).
- 244 testin tamamının tek bir kırılma olmadan %100 yeşil kalmasını sağlamak.

---

## 🏛️ 2. Modüler Mimari Tasarım

```
                               ┌───────────────────────────────────┐
                               │       Rubik::REPL::Shell          │
                               │   • initialize                    │
                               │   • execute_input / dispatch      │
                               │   • register_default_commands     │
                               └─────────────────┬─────────────────┘
                                                 │
                                                 │ registers via Commands.register_all(self)
                                                 ▼
       ┌───────────────────────────────────────────────────────────────────────────────────┐
       │                             Rubik::REPL::Commands                                 │
       ├──────────────┬──────────────┬──────────────┬──────────────┬──────────────┬────────┤
       │    Buffer    │   Session    │  Workspace   │     Lsp      │    Agent     │ System │
       ├──────────────┼──────────────┼──────────────┼──────────────┼──────────────┼────────┤
       │ !diff        │ !history     │ !workspace   │ !lsp         │ !plan        │ !help  │
       │ !apply       │ !sessions    │ !roots       │ !diagnostics │ !goal        │ !clear │
       │ !undo / redo │ !resume      │ !config      │ !symbols     │ !model       │ !ver   │
       │ !snapshot    │ !save-sess   │              │              │ !verbosity   │ !run   │
       │ !rollback    │              │              │              │ !repair      │ !plug  │
       └──────────────┴──────────────┴──────────────┴──────────────┴──────────────┴────────┘
```

---

## ⚙️ 3. Uygulama Detayları

1. **Komut Dizin Yapısı (`lib/rubik/repl/commands/`):**
   - `lib/rubik/repl/commands.rb` (Tüm komut modüllerini yükler ve `register_all(shell)` sağlar)
   - `lib/rubik/repl/commands/base.rb` (Ortak yardımcı metotlar ve DSL)
   - `lib/rubik/repl/commands/buffer.rb`
   - `lib/rubik/repl/commands/session.rb`
   - `lib/rubik/repl/commands/workspace.rb`
   - `lib/rubik/repl/commands/lsp.rb`
   - `lib/rubik/repl/commands/agent.rb`
   - `lib/rubik/repl/commands/system.rb`
2. **`Shell#register_default_commands` Sadeleştirmesi:**
   ```ruby
   def register_default_commands
     Rubik::REPL::Commands.register_all(self)
   end
   ```
3. **Kapsülleme ve Geriye Dönük Uyumluluk:**
   - Mevcut tüm komut parametreleri, çıktılar, renkler ve hata mesajları birebir korunur.
   - `shell.register_command` arayüzü bozulmaz.

---

## 🧪 4. Kalite Güvencesi ve Testler

- Mevcut `test/unit/test_repl_*.rb` ve tüm test dosyaları çalıştırılarak hiçbir komutun davranışı bozulmadan refaktörün tamamlandığı doğrulanmıştır (244 test, 0 failures, 0 errors).
- Yeni eklenen [`test/unit/test_repl_command_decoupling.rb`](../test/unit/test_repl_command_decoupling.rb) ile modüler ayrışma, `Base.parse_scope` yardımcısı ve etki alanı kayıt mekanizması garanti altına alınmıştır.

---

## 🏁 5. Tamamlanma Kontrol Listesi

- [x] `lib/rubik/repl/commands/base.rb` oluşturuldu (`parse_scope` yardımcısı).
- [x] 6 Etki Alanı Modülü oluşturuldu:
  - [x] `lib/rubik/repl/commands/buffer.rb` (`!diff`, `!apply`, `!undo`, `!rollback`, `!autoapply`)
  - [x] `lib/rubik/repl/commands/session.rb` (`!history`, `!replay`, `!session`)
  - [x] `lib/rubik/repl/commands/workspace.rb` (`!workspace`, `!roots`, `!config`)
  - [x] `lib/rubik/repl/commands/lsp.rb` (`!lsp`, `!symbols`, `!outline`, `!refs`, `!ast`)
  - [x] `lib/rubik/repl/commands/agent.rb` (`!plan`, `!goal`, `!steps`, `!verbosity`, `!verbose`, `!provider`, `!providers`, `!model`, `!context`, `!test`, `!lint`, `!format`, `!sh`)
  - [x] `lib/rubik/repl/commands/system.rb` (`!help`, `!commands`, `!status`, `!runtime`, `!fibers`, `!services`, `!quit`, `!exit`, `!clear`, `!reset`)
- [x] `lib/rubik/repl/commands.rb` oluşturuldu ve `register_all(shell)` bağlandı.
- [x] `lib/rubik/repl.rb` dosyasına `require_relative "repl/commands"` eklendi.
- [x] `lib/rubik/repl/shell.rb` dosyasında `attr_accessor :output, :conversation_history`, `detect_git_branch` public yapıldı ve `register_default_commands` sadeleştirildi.
- [x] Tüm testler (244 test, 1636 iddia) %100 yeşil olarak tamamlandı.

