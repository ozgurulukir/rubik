# 🏛️ Rubik System Architecture

> **Protocol:** [`AGENTS.md`](AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Related Guides:** [`TOOLS.md`](TOOLS.md) · [`SELF_EVOLUTION.md`](SELF_EVOLUTION.md) · [`PLUGINS.md`](PLUGINS.md) · [`COMMANDS.md`](COMMANDS.md) · [`CONFIG.md`](CONFIG.md)

---

## 📖 1. System Overview and Design Philosophy

Rubik is a modular autonomous coding harness written in pure Ruby (3.4+), built on the **Spatiotemporal Composability & Self-Evolving Runtime** architecture.

### Core Architectural Principles:
1. **Spatiotemporal Composability (Revertible Effects & Reactive Coeffects):** Every operation in the system is isolated within a spatiotemporal context; every side effect can be atomically reverted through a LIFO ($\Omega$) inverse record.
2. **In-Memory Virtual Buffer First:** When the model writes code, files are never written directly to disk; they are staged in a virtual buffer. This offers zero-risk manipulation, snapshot history, and instant rollback (`!undo`).
3. **Pure-Ruby Cross-Platform Core:** Runs seamlessly on POSIX (Linux, macOS) and Windows 11 environments without any external native dependency.

---

## 🧩 2. Glossary of the 27 Core Domains and Responsibility Matrix

The 26 independent subsystems under Rubik's `lib/rubik/` directory, plus the `event_bus` event facade:

| # | Domain | Module / Class | Responsibility & Role |
| :--- | :--- | :--- | :--- |
| 1 | **`adapter`** | `Rubik::Adapter` | Polyglot adapters for running tests, lints, and formatters (Ruby, Python, Go, Rust, TS, etc.). |
| 2 | **`ast`** | `Rubik::AST` | Hybrid engine of Prism (Ruby) and Tree-Sitter (10 polyglot languages), semantic symbol and call graph (`Graph`), persistent JSON disk cache. |
| 3 | **`benchmark`**| `Rubik::Benchmark` | Agent performance and acceptance benchmarking harness. |
| 4 | **`buffer`** | `Rubik::Buffer` | In-memory virtual buffer (`Manager`), snapshot history, LIFO undo, and diff engine. |
| 5 | **`concurrency`** | `Rubik::Concurrency` | Silent concurrency: a pure-stdlib Ruby Fiber Scheduler event loop (`EventLoop` + `Scheduler`) and the `silently`/`map` boundary API — runs existing blocking I/O call sites (Net::HTTP, sleep, Open3 pipe reads/writes, Mutex/CV/Thread#join) concurrently and cooperatively on a single thread WITHOUT changing them (thousands of concurrent I/O operations; not CPU parallelism, due to the GVL). Kill-switch: `RUBIK_FIBER_SCHEDULER=off`. |
| 6 | **`config`** | `Rubik::Config` | Layered YAML configuration (defaults, deep ops, store, schema validation). |
| 7 | **`context`** | `Rubik::Context` | Code map, AST indexing, token estimation, and smart compaction/pruning. |
| 8 | **`diagnostics`**| `Rubik::Diagnostics` | Elm-style error formatter, `ExecutionFailure` classification, and feedback. |
| 9 | **`event_bus`**| `Rubik::EventBus` | Backward-compatible event facade (`Pub/Sub`) over `Rubik::Kernel::Dispatcher`. |
| 10 | **`kernel`** | `Rubik::Kernel` | Kernel telemetry ring (`Dmesg`), deterministic event dispatcher (`Dispatcher`), root supervisor (`Init` - PID 1), unified execution units (`Unit`, `ProcessUnit`, `SubagentUnit`), `Record`, the kworker queue, and the micro-kernel operational backbone. |
| 11 | **`llm`** | `Rubik::LLM` | Provider abstractions (OpenAI, Claude, Ollama, Custom) and the model router (`Router`). |
| 12 | **`lsp`** | `Rubik::LSP` | Language server manager, RFC 8089 URI support, and in-memory live diagnostics. |
| 13 | **`mcp`** | `Rubik::MCP` | Model Context Protocol client: stdio transport, multi-server manager (`Manager`, parallel startup with overlapping boot fan-out), `BaseTool` proxy admission for discovered tools (`ProxyTool`), and zero-residue process teardown via LIFO. |
| 14 | **`orchestrator`**| `Rubik::Orchestrator`| Agent loop (`Loop`; the subagent notification queue lives in the `SubagentNoticeInbox` collaborator — validation, race-safe draining, and the run/continue lifecycle), `ShellDeps` (narrowing facade), `StepExecutor`, `BudgetManager`, `StreamManager`, `ProviderResolver`, `ActivityLog`, `ToolCallId` (the single home of the tool-call identity stamp), `Subagent::Supervisor` (a process table modeling the PID-1 supervisor ROLE of Linux init; naming contract — machine plane `agent-0`: parent_id/sender and persistent specs, persona plane `maestro`: text visible to the model; renamed from `init-0` on 2026-10-03 — the old name collided with the Unix `init 0` = halt and the PID-1 `init` training priors; `init-0` is now only an accepted input alias; three-way distinction: `Kernel::Init` is the runtime's true PID 1, `Subagent::Supervisor` is the subagent process-table machinery, and `maestro` is the persona driving them), `Subagent::Instance`, `Subagent::StepRunner`, `Subagent::TypeRegistry`, `Subagent::Notices` (the single home of the notification lexicon: user/model channel separation), `Subagent::Budget` (step-budget state machine + grant normalization and the grant-note lexicon — the subagent-loop audience boundary; an owned variant of `BudgetManager`, kept separate under the stateless-over-owner doctrine). |
| 15 | **`platform`** | `Rubik::Platform` | Cross-platform helpers (`PATHEXT`, `which`, `kill_tree`, `path_under?`). |
| 16 | **`plugin`** | `Rubik::Plugin` | Drop-in plugin storage (`Storage`), the `Rubik.plugin` DSL, and `$LOAD_PATH` refcounting. |
| 17 | **`prompt`** | `Rubik::Prompt` | System prompt builders (`ContextBuilder`), `<operational_rules>` (Rules 1-8, High-SNR), and dynamic XML tags (`<subagents>`, `<workspace_status>`, `<buffer_status>`). |
| 18 | **`repair`** | `Rubik::Repair` | Self-healing runtime loops and diagnostics-driven repair. |
| 19 | **`repl`** | `Rubik::REPL` | Interactive shell (`Shell`), 12 domain command modules (`system`, `buffer`, `tasks`, `subagents`, `dmesg`, etc.), presentation layer, and `ServiceCatalog` (service definition catalog: a new service = a Coeffects key + a single catalog entry; Parts members, ivars, readers, and provide lines are all derived from the entry — Candidate 05). |
| 20 | **`runtime`** | `Rubik::Runtime` | Spatiotemporal `Context`, the `Fiber` (`ComponentFiber`) state machine, the LIFO $\Omega$ accumulator, topological fiber reconciliation (`topological_sort_fibers`), pure context disposal (headless teardown), `OverlayStorage`, `TaskManager` (`RingBuffer` & async processes), `ServiceDefinition` (service-declaration value-object lexicon), `ServiceRegistration` (the shared backbone of the 4 register shims: ctx extraction → provide → inverse → reconcile). |
| 21 | **`sandbox`** | `Rubik::Sandbox` | Safe Execution (always active), pluggable OS sandboxes (bwrap/docker/podman/firejail), and a dynamic registry. |
| 22 | **`security`** | `Rubik::Security` | Security guard (`Guard`), Tree-Sitter AST command classifier (172 CLI YAML, Bash/Pwsh), pipeline poisoning, and critical-path blockers. |
| 23 | **`session`** | `Rubik::Session` | Session recorder (`Recorder`), JSONL logging, and `rubik -c` resumption. |
| 24 | **`skills`** | `Rubik::Skills` | Agent Skills infrastructure (agentskills.io): `SKILL.md` discovery and frontmatter validation (`Frontmatter`, `Validator`), project/user-scoped registry (`Registry`), shadowing reports, and the `skill_manager` coeffect lifecycle (`Manager`). |
| 25 | **`storage`** | `Rubik::Storage` | The `rubik://storage` file-system database (`Store`, type.row.hash16 identities), the URI read/write router (`UriReader`, `Render`), the transcript auto-indexer, and the deterministic plane of the Vakanüvis chronicler (`vakanuvis/`: `Harness`, `AnnalWriter`, `MemorySteward`, `WikiSkeleton`, `DistillGate`; the LLM distiller is born from the `vakanuvis` type in `Subagent::TypeRegistry`). |
| 26 | **`tools`** | `Rubik::Tools` | 33 built-in tools (plus the dynamic `skill` proxy), the tool registry (`Registry`), Elm-style router error formatting, and `Services` (the tool layer's triple-chain resolution view: kwarg → coeffect → fresh; standalone installation remains fail-closed). |
| 27 | **`ui`** | `Rubik::UI` | TUI layer, live spinner, statusline, diff colorizer, and markdown renderer. |

---

## 🏗️ 3. System Assembly Line (`Composition.build`) and Data Flow

Rubik brings up all of these subsystems in deterministic order in the `Composition.build` assembly layer:

```mermaid
flowchart TD
    User([Kullanıcı / Terminal]) -->|Girdi| Shell[Rubik::REPL::Shell]
    Shell -->|İnşa & Bağlama| Comp[Rubik::REPL::Composition.build]
    Comp --> RM[Rubik::Runtime::Manager<br/>Coeffects & Fibers]
    
    Shell -->|Görev| Loop[Rubik::Orchestrator::Loop]
    Loop -->|Prompt| LLM[Rubik::LLM::Router / Provider]
    LLM -->|Tool Call| StepExec[Rubik::Orchestrator::StepExecutor]
    
    StepExec --> Tools[Rubik::Tools::Registry<br/>33 Built-in + Custom Tools]
    Tools -->|Dosya İşlemleri| Buffer[Rubik::Buffer::Manager]
    Tools -->|Sözdizim/Tip Kontrolü| LSP[Rubik::LSP::Manager]
    Tools -->|Kabuk/Test Yürütümü| Sandbox[Rubik::Sandbox::Runner]
    Tools -->|Öz-Evrim| Overlay[Rubik::Runtime::OverlayStorage]
    
    Buffer -->|Canlı Geri Bildirim| UI[Rubik::UI::Renderer & Statusline]
    LSP -->|Teşhis Bildirimi| Loop
    StepExec -->|Adım Çıktısı| UI
    UI -->|Render| User
```

---

## 🛡️ 4. Design Invariants

1. **Buffer Guarantee (Buffer Invariant):** All code changes made by the model are never written directly to disk; they are held in the `Buffer::Manager` virtual layer and flushed to disk only through the `apply_buffer` (`!apply`) operation.
2. **LIFO Inverse Guarantee ($\Omega$):** Every tool (`synthesize_tool`), adapter (`Adapter::Registry`), or service registration (`ctx.provide`) produced at runtime is cleaned up in reverse order when its lifecycle ends.
3. **Cross-Platform Transparency:** File paths, process-tree termination (`kill_tree`), and shell invocations are handled transparently per platform.
4. **Falsy-Safe Coeffect Semantics:** `false` coeffect values are legitimate dependency inputs (`sandbox: false`, `dry_run: false`). `Context#require`, `Context#get`, and `Coeffects.get` perform the existence check via `nil?`.
5. **Container and Process Isolation Integrity:** The Docker sandbox driver protects the host with least privilege (`--read-only`, `--cap-drop ALL`, `--security-opt no-new-privileges`); on timeout, the container (`docker rm -f`) and the process tree (`kill_tree`) are cleaned up deterministically.

---

## 💎 5. Pure-Ruby & Zero-Native-Dependency Architecture

Rubik is designed to run with zero setup on Windows, macOS, and Linux **without requiring an external C compiler (GCC, Clang, MSVC) or a C-extension build step**:
- **Ruby AST:** Uses the official **Prism** parser that ships built-in with Ruby 3.3+; there is no external native gem dependency.
- **Polyglot Tree-Sitter AST & Hybrid Semantic Engine:** Performs full syntax-tree parsing for Python, Go, Rust, TypeScript, TSX, JavaScript, C, C++, and Zig through C/Rust-cored grammars compiled via `tree_sitter_language_pack`; it is resilient to brace traps inside comments/strings and to modern language patterns. It runs on a fail-safe graceful fallback architecture that silently reverts to the legacy regex extractors (`FallbackCleaner`) when the network or the library is unavailable.
- **Language Server Support (LSP):** For advanced type and semantic analysis, rather than external native compilation it connects over RFC 8089-compliant JSON-RPC to standard language servers installed on the system (`gopls`, `rust-analyzer`, `solargraph`, `pyright`, etc.).
- **Safe Command AST (Safe Execution):** Before executing Bash and PowerShell commands, it resolves them at the AST level using the `tree_sitter` gem and compiled grammars; structured rules for 172 CLI tools catch pipeline poisoning, root-directory writes, and dangerous flags; on failure, a fail-safe regex fallback kicks in.

---

## 🔒 6. Concurrency (Thread-Safety) and Circuit Breaker

- **Re-entrant Buffer Synchronization:** `Buffer::Manager` is protected by a `Monitor` against concurrent background AST indexing and multi-fiber access.
- **Kernel Ring Buffer Concurrency:** `Rubik::Kernel::Dmesg` operates thread-safe via a `Monitor` across multiple background threads (kworker, subagents, LLM streams) and reader fibers.
- **Kernel Init & Unit Concurrency:** `Rubik::Kernel::Init` and `Rubik::Kernel::Unit` are protected by a `Monitor` for unit state transitions and LIFO shutdown.
- **Topological Fiber and Context Concurrency:** `Rubik::Runtime::Manager` and `Rubik::Runtime::Context` use a re-entrant `Monitor` to provide multi-thread-safe reconciliation (`reconcile_all`), deadlock-free topological sorting, and signal-safe (Interrupt/SystemExit) LIFO disposal.
- **TerminalGuard and Reline Screen Protection:** While asynchronous kworker and background unit notifications are printed to the console, `Rubik::REPL::TerminalGuard` keeps the user's in-progress Reline line thread-safe using a `Monitor`, ANSI line clearing (`\r\e[2K`), and `Reline.redisplay`.
- **Silent Concurrency Boundary (`Rubik::Concurrency.silently`/`.map`):** On top of the Fiber Scheduler event loop, I/O code that merely looks blocking runs concurrently with zero syntax changes at the call site. It is I/O-only concurrency (CPU work stays serial under the GVL); regular-file reads are not parked (they run serially, harmlessly); the boundaries are documented at the top of `lib/rubik/concurrency.rb`. Error policy is raise-after-drain: a body error wins; otherwise the lowest birth-order fiber error is raised and siblings are logged (never swallowed). Scheduler installation is revertible (`Fiber.set_scheduler(nil)` inside `ensure`).

---

## 📡 7. Kernel Telemetry and Event Architecture (`Rubik::Kernel`)

### 7.1 Kernel Telemetry and Event Ring (`Rubik::Kernel::Dmesg`)

System-wide asynchronous events, subagent notifications, HTTP/LLM errors, and micro-kernel diagnostics are collected in the central `Rubik::Kernel::Dmesg` ring:
- **Monotonic Continuity:** A strictly increasing 64-bit sequence number (`seq`) and a process clock (`uptime`) based on `Process::CLOCK_MONOTONIC`. Unaffected by wall-clock (NTP) drift.
- **Zero Memory Leakage (Bounded Memory):** A pre-allocated circular array of a fixed 2048 entries (`Array.new(capacity)`). Old entries are overwritten in $\mathcal{O}(1)$ time complexity, and the memory footprint stays constant for the entire session.
- **Concurrency Protection:** With `Monitor`-based re-entrant thread-safety, concurrent `log` and `tail` calls from multiple fibers and background threads are fully safeguarded.
- **Coeffects & Tool Integration:** Injected into the `Runtime::Context` via `Rubik::Coeffects::DMESG` (`ctx.provide(:dmesg, dmesg)`, `ctx.require(:dmesg)`). Fully bidirectional accessibility is provided through the `!dmesg` operator command in the REPL and, for the LLM, the `:read`-risk `dmesg` built-in tool.

### 7.2 Deterministic Event Dispatcher and kworker Queue (`Rubik::Kernel::Dispatcher`)

`Rubik::Kernel::Dispatcher` is the FIFO thread that provides deterministic delivery of asynchronous events in the micro-kernel architecture:
- **kworker Background Queue:** Events are enqueued onto a `Thread::Queue` and consumed on a single lane by the dedicated `rubik-kworker` daemon thread (`process_queue`).
- **Non-blocking Event Posting:** The `post(event_name, payload, ...)` call returns in $\mathcal{O}(1)$ time; the calling thread or the REPL loop is never blocked.
- **Deterministic Single-Lane (FIFO) Dispatch:** Events are ordered in the sequence they were published. Events sent by concurrent producers are delivered to subscribers deterministically on the kworker lane.
- **Automatic Dmesg Telemetry:** Every dispatched event is concurrently and automatically recorded into the Dmesg ring with an `event:<event_name>` message, along with subsystem, severity, and extra data attributes.
- **Subscriber Fault Isolation:** An exception (`StandardError`) raised by a subscriber is caught and recorded as an error in Dmesg and the logging system. The worker thread does not crash, and other subscribers and subsequent events continue to be processed without interruption.
- **LIFO Lifecycle and Cleanup:** The `sync_drain(timeout)` mechanism synchronizes the draining of queued events. The `subscribe(event, context: ctx)` call registers automatic unsubscription via `context.on_dispose`; `ServiceCatalog` in turn ensures LIFO-conformant cleanup at session close via `runtime_manager.context.on_dispose { dispatcher.stop }`.
- **EventBus Backward-Compatibility Bridge:** `Rubik::EventBus` is configured as a thin facade over the `Dispatcher`. Its `emit` method preserves 100% of the legacy synchronous expectations via a `post` + `sync_drain` call.

### 7.3 Unified Kernel Execution Units (`Rubik::Kernel::Unit`)

The state and resource management of background commands (`TaskManager::Task`), autonomous subagents (`Subagent::Instance`), and kernel services is unified under the `Rubik::Kernel::Unit` base class:
- **Deterministic State Graph:** Units are governed by a 7-state (`:pending`, `:active`, `:paused_error`, `:waiting_budget`, `:completed`, `:failed`, `:reaped`) finite state machine (FSM). State transitions occur atomically (`Monitor`) through `transition_to!`.
- **Terminal State Isolation:** A unit that reaches the `:reaped` state can never transition to any other state; units in the `:completed` and `:failed` states can only become `:reaped` through the garbage-collection (reap) step.
- **Automatic Kernel Telemetry:** On every state transition, a `unit:<id> state transition <from> -> <to>` diagnostic entry is written to the Dmesg ring, and a `:unit_state_changed` asynchronous event is posted to the Dispatcher queue.
- **Subclass Wrappers:**
  - `Rubik::Kernel::ProcessUnit`: Wraps `TaskManager` tasks; bridges termination (`kill`) and state synchronization (`sync_state!`) with background OS processes.
  - `Rubik::Kernel::SubagentUnit`: Wraps `Subagent::Instance` executors; manages the pause (`paused_error`, `waiting_budget`) and resume (`resume`) cycles on budget/error conditions.

### 7.4 Root Supervisor Lifecycle and Zombie Process Reaping (`Rubik::Kernel::Init` - PID 1)

`Rubik::Kernel::Init` is the topmost lifecycle supervisor of the Rubik runtime, analogous to the PID 1 `init`/`systemd` process in operating systems:
- **Single Source of Truth (SSOT):** All processes (`ProcessUnit`) and subagents (`SubagentUnit`) in the runtime are registered (`register`) with the `Init` supervisor the moment they start.
- **LIFO Shutdown Guarantee (AGENTS.md §1.A/B):** When the session ends or `kill_all` / `stop` is called, units are terminated in exactly the reverse chronological order of their registration (LIFO - Last In First Out). Parent units never shut down before their children; this prevents resource leaks and half-finished background operations.
- **Zombie Process Reaping (`reap_dead_units!`):** The allocated disposable sub-contexts (`ctx.extend`) of units that have reached a terminal state (`:completed`, `:failed`) are safely destroyed (`safely_dispose_context`), and the unit is moved to the `:reaped` state.
- **Context and Coeffect Integration:** Injected into the `Runtime::Context` under the `Rubik::Coeffects::INIT` key (`ctx.provide(:init, init)`, `ctx.require(:init)`). When the root context closes (`ctx.on_dispose`), the `Init` supervisor is triggered automatically and destroys all child units in LIFO order.

### 7.5 Spatiotemporal Pure Context Disposal (Headless Teardown) and Topological Fiber Reconciliation

Rubik's spatiotemporal runtime (`Rubik::Runtime`) and service catalog (`Rubik::REPL::ServiceCatalog`) offer a lifecycle that is independent of the REPL shell, pure context-driven, and deterministic:

- **Pure Context Disposal (Headless Context Disposal):** In standalone scripts, tests, or headless daemon mode where no REPL/Shell instance exists, a single `runtime_manager.context.dispose` call atomically stops all background LSP language servers (`lsp_manager.stop_all`), MCP external server processes (`mcp_manager.stop_all`), the Dispatcher kworker thread (`dispatcher.stop`), and the Init supervisor (`init.stop`) under the LIFO ($\Omega$) inverse guarantee.
  - This wiring is established through the `after_inject` hooks in the `ServiceCatalog` definitions via `values[:runtime_manager]&.context&.on_dispose`.
  - A `Shell#stop` call executed after context disposal remains idempotent and safe (a no-op); duplicate shutdown of child processes is silently tolerated.
- **Topological Fiber Reconciliation (`Manager#reconcile_all`):**
  - When activating registered components (`ComponentFiber`), the `Runtime::Manager` does not rely on random or hash order; it sorts them topologically according to the directed acyclic dependency graph (DAG - Directed Acyclic Graph) of the services components provide (`provides:`, the fiber name) and consume (`inject:`, `requires:`) (`topological_sort_fibers`, Kahn's algorithm).
  - Root services and independent components are activated first, and dependent consumer components afterward. This prevents unnecessary intermediate deactivate/reactivate churn.
- **Cycle Isolation & Deadlock Freedom:**
  - When a mutual cyclic dependency (`A -> B -> A`) is detected, the system does not deadlock. Fibers caught in the cycle are isolated via `handle_fiber_cycle`, moved to the `:failed` state, and a runtime warning is emitted. The lifecycle of independent fibers continues uninterrupted.
- **Dmesg Context Disposal Telemetry:**
  - When `Context#dispose` starts, finishes, or raises an error while executing an inverse, events are recorded in structured form into the `Dmesg` ring:
    - Start: `dmesg.log(:context, :info, "Beginning context dispose with N inverse(s)")`
    - Error case: `dmesg.log(:context, :err, "Dispose inverse failed: <Class>: <Message>")`
    - Completion: `dmesg.log(:context, :info, "Context dispose complete; N inverse(s) executed")`
  - Fiber dependency cycles are also reported to kernel telemetry via `dmesg.log(:runtime, :err, "Dependency cycle detected among fibers: ...")`.

---

## 🪟 8. ShellDeps — Interface-Narrowing Facade and PR Checklist

> Require-level invariants
> (no `orchestrator/runtime/tools/llm → repl`) are enforced in CI by
> `test/unit/test_architectural_boundaries.rb`; the list below
> covers method-level coupling that static analysis cannot see.

### 8.1 `Orchestrator::ShellDeps` (`lib/rubik/orchestrator/shell_deps.rb`)

All collaborators built by the `Loop` — `StepExecutor`,
`BudgetManager`, `StreamManager` — access Loop state **only through this
facade**; raw `@loop` reach-through is forbidden (Law of Demeter).
The Loop itself holds the facade via `@shell_deps = ShellDeps.new(self)` and
injects it into its collaborators.

| Surface | Semantics | Examples |
| :--- | :--- | :--- |
| `SURFACE` (read) | Loop accessors are **forwarded** via `method_missing` + `respond_to_missing?` and are not re-declared — test doubles stay minimal, and `deps.respond_to?(...)` queries preserve the real semantics | `deps.provider`, `deps.history`, `deps.step_count`, `deps.safe_config` |
| Command surface (write) | The Loop's `attr_accessor` fields are not leaked; mutations are named commands | `replace_history!`, `reset_invalid_tools!`, `record_invalid_tool!`, `mark_last_turn_streamed!`, `flag_context_warning!`, `emergency_compact_and_notify!` |
| `loop_instance` | Turn-result contract only: the result hash carries the Loop object, and the Shell continues with `continue_loop` | `turn_result` |

**Rules:**
1. Collaborator setup goes through `ShellDeps.wrap(loop_or_deps)`; either the
   facade or a bare loop (test double) is accepted.
2. When adding new state accessible to the Loop, first pick a category: read-only
   goes to `SURFACE`, mutations go to a named command method. If a new public
   Shell method will be called from the Loop, the second item in 7.2 applies.
3. Behavior lock: `test/unit/test_shell_deps.rb` (SURFACE forwarding, command
   surface, the `respond_to?` contract, minimal double compliance).
4. Source-guard lock (Finding 5): a bare `@loop` ivar in collaborators is forbidden —
   access to Loop state goes only through ShellDeps
   (`test_no_raw_loop_ivar_reach_through_in_collaborators`); the Loop's
   `@shell` touches are restricted to a reasoned allowlist
   (`test_loop_shell_touches_stay_on_the_allowlist`; constructor assignment,
   config/commands contract reads — the `buffer.auto_apply` read was moved to
   `Orchestrator::AutoApply` in the 2026-09-22 merge, shrinking the allowlist).

### 8.2 PR Review Checklist (Shell / Loop Growth Discipline)

On every PR that touches `lib/rubik/repl/shell.rb` or `lib/rubik/orchestrator/loop.rb`,
the reviewer asks:

- [ ] **New behavior: mixin or core?** When adding a new public
      method/lifecycle behavior to the Shell, the mixin home is asked first:
      lifecycle, presentation, config_wiring, composition, hooks,
      confirmations, turn_recorder. Additions to the core class are only for
      cross-class orchestration code.
- [ ] **Is the Loop touching a new Shell surface?** Access from the
      Orchestrator to the Shell goes only through the `ShellDeps` narrowifier.
      If a new Shell method will be called from the Loop, whether it should be
      added to the ShellDeps `SURFACE` first is discussed; direct `shell.xxx`
      reach-through is grounds for rejection. Locked in CI by source-guards:
      the bare `@loop` ban in collaborators + the `@shell` allowlist in
      `loop.rb` (`test_architectural_boundaries.rb`). A new `@shell` touch
      writes its rationale in the PR and is added explicitly to the guard allowlist.
- [ ] **Should a new collaborator be extracted?** If ≥2 private methods have
      accumulated under the same responsibility (e.g. provider-config →
      `ProviderResolver`), the ShellDeps/StepExecutor pattern is followed: narrow constructor injection + private delegation shims on the Loop.
- [ ] **Line/symbol budget:** If the PR pushes the Shell past ~600 lines or the
      Loop past ~400 lines, a rationale is mandatory; otherwise extraction
      is planned.

### 8.3 `REPL::CommandContext` — Narrowing Along the Command Axis (Candidate 06)

Bang-command handlers receive not the whole Shell but the
`Rubik::REPL::CommandContext` built on every dispatch (`handler.call(args, ctx)`); construction
happens inside `InputExecution#execute_command`, AFTER the `with_output(TeeIO...)`
capture swap — so `ctx.out` is always the IO that flows into the
transcript/LLM-history capture. The surface is closed: service readers are
derived from `ServiceCatalog.reader_names` (no second list),
`conversation_history` / `active_loop` can be re-bound through write-through accessors,
and everything else is a named single-line effect. There is no `register_command`,
no ivar access, no `respond_to?` discovery, and no `method_missing`. In command
modules, a bare `shell` may appear only in the registration backbone
(`def self.register(shell)` + `shell.register_command`); locks:
`test_repl_command_context_guard.rb` (backbone allowlist + ivar ban + catalog
derivation + allowlist-rot self-audit) and the closed-surface freeze
`test_command_context.rb`. Usage summaries live in the backbone as
single-source-of-truth `usage:` metadata; `!help <cmd>` prints it. Custom
command dispatches (SynthesizeCommandTool, OverlayStorage#eval_command,
PreflightRunner) pass ctx (the IO duck) to 2-arity handlers and the raw shell to 3-arity.

### 8.4 `REPL::TerminalGuard` — Asynchronous Screen Protection and Non-blocking REPL

While asynchronous subagents (`SubagentUnit`) and background commands (`ProcessUnit`) run in the background, `Rubik::REPL::TerminalGuard` provides both the release of the REPL command line back to the user without blocking (Prompt Liberation) and a protection line that keeps background notifications from corrupting the active input line:
- **Zero Prompt Clobbering:** While the user is typing at the prompt (`rubik > ...`) and an urgent notification arrives from the background, the active line is cleared with ANSI `\r\e[2K`, the notification is printed on a clean line, and `Reline.redisplay` is invoked so the user's half-typed text and cursor are redrawn intact on the line below.
- **Quiet Inbox Buffering:** Non-urgent background events stream silently into the `Dmesg` ring buffer and the `notice_inbox` instead of being printed straight to the screen. They are drained regularly via `flush_notices!` when the user opens a new line or presses Enter.
- **Concurrent REPL Interaction:** While independent units execute in the background, the user can run status queries such as `!dmesg`, `!subagents`, `!tasks`, or enter a new request.
- **Reactive Agent Wake-up:** While the prompt is idle and the user's input line is empty, when a subagent completes/pauses/hits an error/sends a message, `TerminalGuard#safe_wakeup!` injects an Enter into the blocked read; the returned empty line is turned by `execute_subagent_notice_turn!` into an autonomous notification-evaluation turn for agent-0 (a synthetic prompt tagged `[reactive subagent wake-up]`; `REPL::PendingNoticeQueue` is the wake-up flag). No wake-up happens while the user is typing, while `!paste`/burst collection is in progress (`with_collecting`), or while `subagents.reactive_wakeup: false`; notifications are injected into `@conversation_history` and become visible on the next turn. Subagent step-budget transparency: `Allocated Step Budget: N steps` in the system prompt and a `[Step X/Y]` marker on every step (the 75% warning latch was removed; `Budget#step_marker`).

### 8.5 Kernel & Asynchronous Subsystem Consolidation

The asynchronous subsystems of the system (Kernel, Init, Dispatcher, EventBus, Dmesg, TaskManager, Subagents) have been consolidated under a single, deterministic SSOT:
- **Single Dispatcher & kworker:** In the `ServiceCatalog` assembly, the `dmesg` and `dispatcher` definitions were moved ahead of `event_bus`, removing the hack of opening a dummy worker thread at startup and killing it later; a single persistent `rubik-kworker` thread now serves the entire system.
- **Live SubagentUnit State Synchronization:** `Subagent::Instance` state transitions are reflected instantly into the `Kernel::Unit` state machine and the `Dmesg` ring via `Unit#sync_state!`; concurrently, the `:unit_state_changed` event is fired.
- **Turn-Boundary Zombie Reaping:** Every time a turn completes (in the `ensure` block, before the user is prompted again), `Init#reap_dead_units!` is triggered so the disposable sub-contexts (`context.dispose`) of completed/failed units are promptly reaped (`:reaped`) in LIFO order.
- **Reactive Task Wake-up:** When a `ProcessUnit` (background command) completes, `Lifecycle#handle_unit_event` — in addition to printing a safe notification to the screen — injects a notification in `<task_notification ...>` format into the active LLM loop (`@active_loop`) and into `@conversation_history`.

