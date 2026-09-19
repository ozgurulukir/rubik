# Plan 93 — Asenkron Arka Plan Süreçleri ve Görev Yöneticisi (`manage_task`)

> **Durum:** ✅ **Tamamlandı**  
> **Zorluk:** Orta–Zor  
> **Faz:** 9 (Çalışma Zamanı & Süreç Yönetimi)  
> **Öneri Bölümü:** Sandbox, Süreç İzolasyonu & Asenkron Yürütme  
> **İlgili Planlar:** [12](12-guvenlik-diff-onay.md), [13](13-sandbox-izolasyon.md), [20](20-spatiotemporal-composability-eklenti-dongusu.md), [49](49-tam-kapsamli-cross-platform-ve-windows-uyumluluk-mimarisi.md), [55](55-run-command-platform-kapili-kabuk-secimi.md), [80](80-sandbox-mimari-refaktoru-guarded-runner-bubblewrap-ve-wasm-konumlandirmasi.md), [81](81-bash-ve-powershell-treesitter-guvenli-calistirma-ve-ast-katmani.md), [AGENTS.md](../AGENTS.md)

---

## 🎯 1. Motivasyon ve Sorun Tanımı

Frontier kodlama görevlerinde ajanlar sıklıkla uzun süren veya kesintisiz çalışması gereken komutları yürütmek zorundadır:
- Geliştirme sunucuları (`rails s`, `npm run dev`, `python -m http.server`)
- Arka plan test koşucuları veya watch modları (`jest --watch`, `guard`)
- Uzun derleme ve Docker imaj paketleme işlemleri (`cargo build --release`, `docker build .`)

### 🔍 Mevcut Kısıtlar ve Kök Nedenler:
1. **Senkron Bloklama ve Timeout Çöküşü:**
   - [`RunCommandTool`](file:///C:/Github/rubik/lib/rubik/tools/builtins/exec.rb) komutları senkron çalıştırır (`timeout: 30s`). Sunucu başlatan bir komut verildiğinde ya 30 saniye sonra timeout ile öldürülür ya da REPL'i kilitler.
2. **OS Boru Hattı Kilitlenmesi (Pipe Deadlock):**
   - Arka planda çalışan bir sürecin stdout/stderr akışı sürekli tüketilmezse, işletim sisteminin 64 KB'lık boru tamponu (pipe buffer) dolar ve çocuk süreç bir sonraki `puts/print` çağrısında kalıcı olarak askıda kalır (deadlock).
3. **Zombi Süreç Riski (Process Leak):**
   - Arka planda başlatılan işlemler kontrolsüz bırakıldığında, Rubik kapansa dahi portları (örn. 3000, 8080) işgal etmeye devam eder.
4. **Güvenlik Açığı (Security Bypass):**
   - Arka planda başlatılan komutların `Rubik::Security::Guard` AST denetiminden geçmemesi felakete yol açabilir.

---

## 🏛️ 2. `AGENTS.md` Spatiotemporal Uyumu ve Değişmezler

```
                 [ Start Background Task: manage_task / run_command(background: true) ]
                                            │
                                            ▼
                           ┌──────────────────────────────────┐
                           │   AST Security Guard Check       │
                           │   Guard#verify_command_safety!   │
                           └────────────────┬─────────────────┘
                                            │
                                            ▼
                           ┌──────────────────────────────────┐
                           │   Spawn Process + Reader Thread  │
                           │   (Thread-Safe 500-line RingBuf) │
                           └────────────────┬─────────────────┘
                                            │
                      ┌─────────────────────┴─────────────────────┐
                      │ Pair Inverse by Construction (Ω LIFO)     │
                      │ ctx.on_dispose { task.kill_tree }         │
                      └─────────────────────┬─────────────────────┘
                                            │
          ┌─────────────────────────────────┼─────────────────────────────────┐
          ▼                                 ▼                                 ▼
   [ Action: list / status ]      [ Action: send_input / logs ]      [ Explicit kill / Scope Dispose ]
   Query running processes        Stream ring-buffer lines           LIFO Unwind via kill_tree
```

1. **Inverses by Construction:** Her arka plan görevi başlatıldığı an, öldürme kancası (`kill_tree`) `Context`'in LIFO ters işlem akümülatörüne ($\Omega$) eklenir:
   ```ruby
   ctx.on_dispose { task.terminate_safely }
   ```
2. **Soundness of Rollback ($A(\sigma) \sim \sigma_0$):** Oturum kapandığında, eklenti reload edildiğinde veya alt bağlam (`ctx.extend()`) sonlandığında tüm alt süreçler `Rubik::Platform.kill_tree` ile temiz bir şekilde sonlandırılır (Windows: `taskkill /F /T`, POSIX: `SIGTERM` / `SIGKILL`).
3. **Asla Kilitlenmeyen Akış (Pipe Deadlock Immunity):** Her görev için arka planda çalışan hafif bir okuyucu iş parçacığı (`collector thread`), stdout ve stderr borularını kesintisiz tüketerek halka tampona (RingBuffer, son 500 satır) yazar.
4. **Güvenlik Önceliği:** Komut başlatılmadan önce `Guard#verify_command_safety!` ve allowlist kontrolleri çalıştırılır; tehlikeli komutlar arka planda da engellenir.

---

## 🏗️ 3. Mimari Tasarım ve Fazlar

### 📦 Faz A: `TaskManager` ve `RingBuffer`
**Dosya:** `lib/rubik/runtime/task_manager.rb` (`Rubik::Runtime::TaskManager`)

- **Görev Durum Makinesi:** `:pending` → `:running` → `:completed` / `:failed` / `:killed`
- **Model:** `Task = Struct.new(:id, :command, :pid, :started_at, :status, :exit_code, :ring_buffer, :stdin_io, :thread, keyword_init: true)`
- **Metotlar:**
  - `start(command, chdir: Dir.pwd, ctx: nil)`:
    - `guard.verify_command_safety!(command)` doğrulaması.
    - `Open3.popen3` veya `Process.spawn` ile başlatma.
    - Collector thread ile stdout/stderr birleştirilmiş okuma (`ring_buffer.push`).
    - `ctx&.on_dispose { kill(task.id) }` LIFO ters işlem kaydı.
  - `list`: Tüm görevlerin durumunu döner.
  - `status(task_id)`: Sürecin canlılığını ve varsa çıkış kodunu döner.
  - `logs(task_id, tail: 50)`: Halka tampondaki son N satırı döner.
  - `send_input(task_id, text)`: `stdin_io.puts(text)` ile veri gönderir.
  - `kill(task_id)`: `Rubik::Platform.kill_tree(task.pid)` çalıştırır.
  - `kill_all`: Çalışan tüm görevleri topluca sonlandırır (`at_exit` kancası ile zombi koruması).

### 🛠️ Faz B: `ManageTaskTool` ve `RunCommandTool`
**Dosya:** `lib/rubik/tools/builtins/task.rb` (`Rubik::Tools::ManageTaskTool`)

- **Araç JSON Şeması:**
```json
{
  "name": "manage_task",
  "description": "Manage asynchronous background processes (servers, builders, long test runs). Actions: 'start', 'list', 'status', 'logs', 'send_input', 'kill'.",
  "parameters": {
    "type": "object",
    "properties": {
      "action": { "type": "string", "enum": ["start", "list", "status", "logs", "send_input", "kill"] },
      "task_id": { "type": "string", "description": "The task ID (e.g. 'task-1'). Required for status/logs/send_input/kill." },
      "command": { "type": "string", "description": "The shell command to run. Required for 'start'." },
      "input": { "type": "string", "description": "Input text to send to stdin. Required for 'send_input'." },
      "tail": { "type": "integer", "description": "Number of lines to read for 'logs' (default 50)." }
    },
    "required": ["action"]
  }
}
```
- `RunCommandTool` entegrasyonu: `execute("command" => "...", "background" => true)` parametresi verildiğinde görevi `TaskManager`'a yönlendirir.

### 🖥️ Faz C: REPL `!tasks` Komutu
**Dosya:** `lib/rubik/repl/commands/tasks.rb`

- `!tasks` veya `!tasks list`:
  ```text
  === Background Tasks ===
    • [task-1] RUNNING  (PID 21450, up 42s): rails s -p 3000
    • [task-2] COMPLETED (PID 21890, exit 0): npm run build
  ```
- `!tasks logs <task-1> [--tail 100]`: Log dökümü.
- `!tasks kill <task-1>` / `!tasks kill-all`: Süreç sonlandırma.

---

## 🧪 4. Test Senaryoları ve Kabul Kriterleri

1. **Arka Plan Süreç Başlatma:** `ruby -e "sleep 5"` başlatılır, `status`'un `RUNNING` döndüğü ve sürecin PID'sinin geçerli olduğu teyit edilir.
2. **OS Pipe Doygunluk Bağışıklığı:** 100.000 satır çıktı üreten bir komut çalıştırılır; collector thread sayesinde sürecin pipe buffer'da kilitlenmeden tamamlandığı doğrulanır.
3. **Log Okuma ve Halka Tampon Sınırı:** Halka tamponun 500 satır tavanını koruduğu ve bellek sızıntısı yapmadığı doğrulanır.
4. **Stdin Veri İletimi:** `ruby -e "puts gets.upcase"` ile stdin'e `hello` gönderildiğinde çıktı olarak `HELLO` alındığı teyit edilir.
5. **Güvenlik Duvarı Engeli:** Yasaklı bir komut (`manage_task start "rm -rf /"`) verildiğinde `BlockedWriteError` fırlatıldığı ve sürecin asla başlatılmadığı test edilir.
6. **LIFO Ters İşlem ve Context Rollback:** `ctx.dispose` çağrıldığında çalışan tüm arka plan süreçlerinin `Platform.kill_tree` ile öldürüldüğü doğrulanır.

---

## 📝 5. Dosya Tavanları ve Hijyen

- `lib/rubik/runtime/task_manager.rb`: < 250 satır (Gerçekleşen: 203 satır)
- `lib/rubik/tools/builtins/task.rb`: < 200 satır (Gerçekleşen: 140 satır)
- `lib/rubik/repl/commands/tasks.rb`: < 150 satır (Gerçekleşen: 91 satır)
- `test/unit/test_task_manager.rb`: Kapsamlı birim testler (14 test, 71 assertion, 0 failure)

---

## 🏁 6. Uygulama ve Doğrulama Raporu

- **Uygulanan Bileşenler:**
  1. `Rubik::Runtime::TaskManager` ve `Rubik::Runtime::RingBuffer` (`lib/rubik/runtime/task_manager.rb`): Eşzamanlı okuyucu iş parçacıkları (`collector threads`), OS 64KB boru tıkanma bağışıklığı, `Platform.kill_tree` zombi temizliği ve `ctx.on_dispose` LIFO $\Omega$ ters işlemi.
  2. `Rubik::Tools::ManageTaskTool` (`lib/rubik/tools/builtins/task.rb`): `manage_task` aracı (`start`, `list`, `status`, `logs`, `send_input`, `kill`).
  3. `Rubik::Tools::RunCommandTool` (`lib/rubik/tools/builtins/exec.rb`): `background: true` parametresi ile arka plana asenkron yönlendirme desteği.
  4. `Rubik::REPL::Commands::Tasks` (`lib/rubik/repl/commands/tasks.rb`): `!tasks` (`list`, `logs`, `kill`, `kill-all`) REPL bang komutları ve `!task` takma adı.
  5. Sistem Montajı & Hijyen: Toplam kanonik araç sayısı 25'e çıkarıldı; `Composition.build`, `Shell`, `SetupFactories`, `Registry` ve `test_module_hygiene.rb` senkronize edildi.
- **Test ve Hijyen Doğrulaması:**
  - `test/unit/test_task_manager.rb`: 14 test, 71 assertion, 0 failure, 0 error (%100 yeşil).
  - `test/unit/test_module_hygiene.rb`, `test_expanded_tools.rb`, `test_tool_aliasing_and_naming.rb`, `test_repl_command_decoupling.rb`: %100 yeşil.
  - RuboCop: 0 offenses.
  - Tüm test paketi (`bundle exec rake test`): 1752 test, 10209 assertion, 0 failure, 0 error.
