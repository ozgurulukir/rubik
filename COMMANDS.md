# 🕹️ Rubik REPL Command Guide (`COMMANDS.md`)

> All **Bang (`!`) Commands** you can use inside the Rubik interactive REPL shell for code writing, autonomous planning, provider management, the in-memory buffer, and AST inspection.

---

## 🏛️ Persistence Scoping and Feedback Rules

Setting and management commands inside the Rubik REPL support three different persistence tiers:

| Scope | Flag | Persistence Behavior | Feedback Notice |
| :--- | :--- | :--- | :--- |
| **Session Only** | *(no flag)* or `-s` / `--session` | Active in memory only for the current session; never written to disk. | `[Session only]` |
| **Project Level** | `-p` or `--project` | Persisted to `.rubik/config.yml` in the project root. | `[Project level (.rubik/config.yml)]` |
| **System Level** | `-g` or `--global` | Persisted to `~/.rubik/config.yml` in the user home directory. | `[System level (~/.rubik/config.yml)]` |

---

## 📑 Quick Access Index

1. [Model, Provider & Routing](#-1-model-provider--routing-commands) (`!provider`, `!providers`, `!model`)
2. [Autonomous Agent, Planning & Budget](#-2-autonomous-agent-planning--budget-commands) (`!plan`, `!goal`, `!steps`)
3. [In-Memory Buffer, Diff & Snapshot](#-3-in-memory-buffer-diff--snapshot-commands) (`!diff`, `!apply`, `!autoapply`, `!undo`, `!rollback`)
4. [Spatiotemporal Runtime & Diagnostics](#-4-spatiotemporal-runtime--live-diagnostics-commands) (`!runtime`, `!fibers`, `!agents`, `!services`, `!dmesg`, `!storage`, `!prune`)
5. [Code Intelligence, AST Graph, LSP & MCP](#-5-code-intelligence-ast-graph--lsp-commands) (`!lsp`, `!diagnostics`, `!mcp`, `!symbols`, `!outline`, `!refs`, `!ast`, `!context`)
6. [Build, Test, Background Tasks & Sandbox](#-6-build-test--safe-sandbox-commands) (`!test`, `!lint`, `!format`, `!sh`, `!tasks`)
7. [Session, History & Settings](#-7-session-history--general-settings) (`!session`, `!history`, `!replay`, `!config`, `!skill`, `!verbosity`, `!verbose`, `!workspace`, `!allow-dir`, `!allow-cmd`, `!paste`, `!status`, `!clear`, `!reset`, `!plugin`/`!plugins`, `!help`, `!quit`)
8. [Dynamically Synthesized Commands](#-8-dynamically-synthesized-commands-self-evolving)

---

## 🤖 1. Model, Provider & Routing Commands

### `!providers` & `!provider list`
Lists all registered LLM providers, their endpoints, types, and defined models.
```bash
!providers
!provider list
```

### `!provider add`
Adds a new LLM provider, together with its first model, to the live system.
```bash
# Global add with a direct API key:
!provider add deepseek openai_compatible https://api.deepseek.com/chat/completions --key=sk-your-key --model=deepseek-chat --context=64000 -g

# Global add via environment variable (security / git friendly):
!provider add openrouter openai_compatible https://openrouter.ai/api/v1/chat/completions --key-env=OPENROUTER_API_KEY --model=anthropic/claude-3.7-sonnet --context=200000 -g

# To add at the project level:
!provider add local_vllm openai_compatible http://localhost:8000/v1/chat/completions --model=qwen2.5-coder --context=32768 -p

# For this session only (Session Only):
!provider add test_provider openai_compatible http://localhost:11434 --model=llama3
```

### `!provider add-model` & `!provider set-context`
Defines a new model on an existing provider, or updates the model's context token limit.
```bash
!provider add-model deepseek deepseek-reasoner --context=64000 -g
!provider add-model openrouter deepseek/deepseek-r1 --context=128000 -g
!provider set-context openrouter deepseek/deepseek-r1 131072 -g
```

### `!provider set`
Updates a specific field (endpoint, key, key-env, type) of a registered provider.
```bash
!provider set deepseek key sk-new-secret-key -g
!provider set deepseek endpoint https://api.deepseek.com/chat/completions -g
```

### `!provider remove-model` & `!provider remove`
Removes a specific model, or an entire provider, from the system.
```bash
!provider remove-model deepseek deepseek-chat -g
!provider remove deepseek -g
```

### `!model`
Shows or changes the active model roles (`default`, `fast`, `advanced`, `plan`, `goal`), their context limits, and the routing state. The provider and model name can be given either as separate space-separated arguments or joined with `/` or `:`:
```bash
!model                                                      # Lists roles and routing status
!model openrouter deepseek/deepseek-v4-flash                # Sets provider and model as separate arguments (Recommended)
!model set default openrouter deepseek/deepseek-v4-flash -g # Assigns to the default role (Global)
!model set fast openrouter mistralai/mistral-7b-instruct -p # Assigns to the fast role (Project level)
!model set advanced openrouter anthropic/claude-3.7-sonnet  # Assigns to the advanced role (Session only)
!model openrouter/cline-pass/deepseek-v4-flash              # Set in slash (/) separated format
!model route auto                                           # Enables automatic task-based smart routing

# CHANGING THE CONTEXT LIMIT:
!model context 65536                                        # Changes the context limit of the active default model
!model context fast 32768                                   # Changes the context limit of the model in the fast role
!model context advanced 200000 -g                           # Persists the advanced model's limit globally
!model context cline cline-pass/deepseek-v4-flash 128000 -g # Updates the context limit of a specific provider/model
```

---

## 🔁 2. Autonomous Agent, Planning & Budget Commands

### `!plan <task description>`
For the given task, first inspects the codebase, produces a numbered step-by-step implementation plan, and asks for your `[y/N]` approval.
```bash
!plan Add rate limiting and redis cache support to the user registration service
```

### `!goal [--steps N] <goal description>`
Runs the autonomous `Plan -> Act -> Verify -> Repair` loop until all tests are 100% green and the goal is verified.
The maestro (main agent) is the supervisor: it splits the goal into a subagent pipeline it defines itself (planning/research → coding ('coder') → review/audit → repair), advances through subagent notifications, and keeps a budget-stalled subagent going with `extend_budget`. When the step budget runs out, the REPL auto-extends if configured (`agent.goal_auto_continue_limit`) or prompts to continue (`agent.ask_continue_on_limit`, +20 steps per approval; default budget `agent.goal_max_steps` = 100, or override via `--steps N`). The live goal state (status, step counter, extensions) can be read via `rubik://goal/state`.
Structured goal ledger (SKILL.state adaptation, 2026-10-10; default ON, `goal.ledger.*`): the loop maintains a rev-guarded ΔΣ ledger — objective, tasks, findings, decisions, open questions, environment notes — that the maestro updates with the root-only `update_goal_ledger` tool (JSON patch against the rev reported by `read_file(path: 'rubik://goal/ledger')`). The current Σ is pinned through every compaction tier and re-injected each step, and every accepted revision is appended to storage under the `goal-ledger` ref (the finish event carries the final row id). With `goal.ledger.verify`, the harness re-checks declarative `verify` specs on tasks and environment notes at step boundaries — a failed spec flips the task to `stale` and bumps the rev (a stale-rev `:conflict` is how the model learns the world drifted). At compaction time `goal.ledger.observe_projection` replaces banked tool results with per-row `<absorbed_into_ledger>` tombstones (rows are never dropped; the last `observe_window` turns stay raw).
Early-completion protection: while a subagent is live, the maestro ending its text-only turn or calling `finish` does not count the goal as COMPLETED — the loop automatically waits until the subagents finish (`agent.goal_wait_timeout`, default 300 s) and keeps running by injecting their notifications into the maestro.

**Suspend & resume (2026-10-12, issue #106):** a *transient* provider transport failure — exhausted connect/DNS retries, an exhausted-5xx outage, or HTTP 429 — no longer kills the goal terminally. The loop is suspended (`SUSPENDED ≙ PENDING`): the REPL prompt stays alive, step/extension/token counters are preserved, the surviving loop keeps its conversation prefix, and the Σ ledger row is stamped `suspended` with the counters as link meta. `!goal resume` continues the most recent suspension. In-process (same session), the same loop instance is revived and subagent conversations genuinely continue. Cross-process (after a restart), the goal is rehydrated from the Σ stamp — a `[system] → [task] → [Σ row] → [goal_resumed marker]` window with counters restored; the acceptance chain continues on a new row linked to the suspended one, and subagent conversations did not survive the restart (the resume output says so in one sentence). The first resumed step re-runs `goal.ledger.verify` boundary verification, so world drift during the downtime surfaces as a `stale` flip + rev bump — a signal to replan, not a failure. Permanent errors (4xx content/auth/moderation, read timeouts, malformed responses) keep the terminal behavior unchanged; abandoning a suspended goal = `!goal resume` followed by `^C` (terminal `:stopped` stamp — no separate cancel command). With `goal.ledger.enabled false`, in-process resume works but cross-process resume is honestly refused (no Σ stamp exists).
```bash
!goal Fix all failing tests in the payment module and make them pass
!goal --steps 200 Refactor auth subsystem unattended
!goal list                  # Suspended goals (storage rows with status "suspended")
!goal resume                # Continue the most recent suspension (in-process or cross-process)
```

### `!steps`
Displays or updates the agent's maximum step budget for a single task.
```bash
!steps                                       # Shows the budget status and warning thresholds
!steps 50                                    # Sets the standard task budget to 50 steps
!steps goal 100                              # Sets the !goal autonomous loop budget to 100 steps
!steps plan 20 -p                            # Sets the project-level plan budget to 20 steps
```

---

## 🛡️ 3. In-Memory Buffer, Diff & Snapshot Commands

### `!diff`
Shows all changes the model has prepared in the in-memory buffer but has not yet written to disk, in colored diff format.
```bash
!diff
```

### `!apply`
Atomically persists all pending file changes in the buffer to disk and updates the AST index.
```bash
!apply
```

### `!autoapply`
Sets the buffer's automatic write-to-disk policy.
```bash
!autoapply status                            # Shows the current buffer policy
!autoapply manual                            # Save changes only via !apply (Default)
!autoapply on_test                           # Auto-write to disk immediately before each test run
!autoapply always                            # Write to disk instantly on every model write
```

### `!undo` & `!rollback`
Reverts the most recent change made in the buffer or on disk, or restores a specific snapshot.
```bash
!undo                                        # Reverts the most recent change
!rollback snap_20260823_193000              # Returns to the specified snapshot point
```

---

## 🌌 4. Spatiotemporal Runtime & Live Diagnostics Commands

### `!runtime [all | services | fibers | tools | commands]`
Shows the Spatiotemporal Composability runtime, the active coeffect services, the fibers, and the LIFO inverse-accumulator depth.
```bash
!runtime                                     # Full comprehensive diagnostics panel
!runtime fibers                              # Shows only fiber statuses
```

### `!fibers`
Lists all dynamic plugin fibers in the system:
- `🟢 ACTIVE`: Fibers whose coeffect dependencies are fully satisfied and that are running.
- `⏳ PENDING`: Fibers waiting on a missing service/coeffect (along with the list of services they are waiting on).
- `🔴 FAILED`: Fibers that hit an error during activation and were atomically rolled back with their partial inverses.
```bash
!fibers
```

### `!services`
Lists the 10 core subsystems provided to the runtime root context (`Runtime::Context`) (`:buffer`, `:snapshot`, `:lsp`, `:ast`, `:guard`, `:sandbox`, `:adapters`, `:events`, `:config`, `:index`) plus custom services.
```bash
!services
```

### `!agents`
Interactive agent/fiber dashboard: lists all fibers with status glyphs (🟢 active, ⏳ pending, 🔴 failed); for orchestrator fibers it shows step progress and the Ω inverse depth. On interactive terminals, a fiber can be selected with the arrow keys to open a detail view (coeffect dependencies, token usage, last error); in pipe/CI mode a plain list is printed.
```bash
!agents                                      # Dashboard + (if TTY) detail selection
```

### `!dmesg`
Displays and filters telemetry, subagent notifications, LLM/socket errors, and microkernel logs from the kernel's monotonic event ring buffer.
- **Syntax:** `!dmesg [-n <count>] [-l <level>] [-s <subsystem>] [--since <seq>] [clear]`
- **Flags:**
  - `-n <count>`, `--limit <count>`: Number of most recent events to show (default: 50).
  - `-l <level>`, `--level <level>`: Filters by severity (`emerg`, `alert`, `crit`, `err`, `warn`, `notice`, `info`, `debug`).
  - `-s <subsystem>`, `--subsystem <subsystem>`: Filters by subsystem (`init`, `subagent`, `llm`, `net`, `buffer`, `tool`, `sandbox`, `kernel`).
  - `--since <seq>`: Fetches only the events strictly after the given sequence number.
  - `clear`, `-c`, `--clear`: Resets all event records in the buffer.

```bash
!dmesg                                       # Lists the last 50 kernel events
!dmesg -n 20                                 # Lists the last 20 events
!dmesg -l err,warn                           # Filters to error and warning levels only
!dmesg -s subagent                           # Shows only events from the subagent subsystem
!dmesg -s subagent -l warn -n 10             # Lists the last 10 records of subagent warnings
!dmesg --since 105                           # Shows new events after sequence number 105
!dmesg clear                                 # Clears the event ring
```

### `!storage`
A user-side window into the central `rubik://storage` virtual FS-DB (storage-show-surface 2026-09-30): displays goals, plans, review reports, and other entities written to the store directly in the terminal, bypassing the model. The command only READS — the write plane belongs to the agents' `storage` tool.
- **Syntax:** `!storage [<type|id|type.row|row|hash-prefix|alias>] [refs]`- **Views:**
  - No arguments: project summary (entity counters + ref list).
  - `refs`: alias table (`alias → id`).
  - `<type>`: the entity list for that type (aliases flagged).
  - `<selector>`: cross-type resolution (full id → `type.row` → row → hash prefix → alias); the matching entity is printed as a compact card.

```bash
!storage                                     # Project summary: counters + refs
!storage refs                                # Alias table
!storage review                              # List of the review type
!storage tangram-review                      # Prints the report directly via its alias
!storage review.1                            # type.row form
```

### `!prune`
User-side surface of the semi-deterministic ROOT context pruner (context-pruner 2026-10-09; DEFAULT ON since 2026-10-10 — opt-out `subagents.pruner.enabled false`, operator-only). When bound, an LLM "Context Pruner" subagent proposes a keep/drop/summarize plan for the conversation window; the harness validates it deterministically (goal/task turns, decisions and recent context are always preserved) and applies it at the next turn boundary. The command never blocks on the LLM.
- **Syntax:** `!prune [now|status]`
- **Subcommands:**
  - *(none)* / `status`: window estimate vs input ceiling, staged-plan state, last apply receipt.
  - `now` (also `run`/`force`): queues a forced prune; returns a deterministic async receipt.

```bash
!prune                                       # Same as status
!prune status                                # Window: 27 entries, ~8,400 est. tokens (24% of ceiling)
!prune now                                   # Prune queued (async): ... applied at the next turn boundary
```

---

## 🌳 5. Code Intelligence, AST Graph & LSP Commands

### `!lsp`
Manages the Language Server Protocol (LSP) integration and inspects live compiler errors.
```bash
!lsp status                                  # Shows the active language servers and their status
!lsp on                                      # Turns the LSP engine on
!lsp off                                     # Turns the LSP engine off
!lsp diag                                    # Lists all compiler/type errors in the project
!lsp diag lib/rubik/repl/shell.rb            # Dumps the LSP diagnostics for a specific file
!lsp start rust                              # Manually starts the Rust server (rust-analyzer)
!lsp stop rust                               # Stops the Rust server
```

### `!diagnostics`
Displays the live LSP diagnostics for the workspace (or a specific file) — a shortcut for `!lsp diag`.
```bash
!diagnostics                                 # Lists the live diagnostics across all open files
!diagnostics lib/rubik/repl/shell.rb         # Dumps the diagnostics for the given file
```

### `!mcp`
Manages Model Context Protocol (MCP) external tool servers and dynamically pluggable tools.
```bash
!mcp                                         # Lists the active and registered MCP servers and their status (!mcp status)
!mcp list [server]                           # Shows the server's discovered tools and their parameters
!mcp add <name> <command> [arg...] [-p|-g]   # Adds a new server to the configuration and starts it
!mcp remove <name> [-p|-g]                   # Stops the server and removes it from the configuration
!mcp enable <name>                           # Activates a disabled server (!mcp on)
!mcp disable <name>                          # Stops the server and unregisters its tools (!mcp off)
!mcp connect <name> <command> [arg...]       # Attaches a temporary server for the current session only
!mcp disconnect <name>                       # Detaches and shuts down the session-scoped server
!mcp ping <name>                             # Tests the server's liveness and response latency
```

### `!symbols <query>`
Semantically searches function, class, struct, and method definitions in the project across the AST graph.
```bash
!symbols UserValidator
!symbols complete
```

### `!outline <file>`
Dumps the semantic outline tree (classes, methods, line ranges) of the target source file.
```bash
!outline lib/rubik/repl/shell.rb
```

### `!refs <symbol>`
Lists all references to a symbol and the places it is called across the entire codebase.
```bash
!refs build_default
```

### `!ast <file | symbol>`
Inspects AST symbol details or a file's semantic tree.
```bash
!ast lib/rubik/tools/registry.rb
```

### `!context`
Manages the project context index.
```bash
!context status                              # Shows a summary of indexed files and languages
!context scan                                # Performs a full rescan of the codebase
!context add src/custom.rb                   # Adds a single file to the context
!context drop tmp/scratch.rb                 # Removes the file from the context
```

---

## 🧪 6. Build, Test & Safe Sandbox Commands

### `!test [file]`
Runs the tests through the active language adapter (Ruby, Python, Go, Rust, C, Zig).
```bash
!test                                        # Runs the full test suite
!test test/unit/test_repl.rb                 # Runs a single test file
```

### `!lint [file]` & `!format [file]`
Runs the syntax checker or the formatter.
```bash
!lint
!format lib/rubik/config.rb
```

### `!sh <command>`
Runs a shell command safely under the security layer (`Security::Guard`) and the configured Safe Execution / Sandbox infrastructure (`Sandbox::Runner`).

- **Centralized Runner Integration:** Uses the `shell.sandbox_runner` object from the REPL session; validates command and directory safety with the Safe Execution policy (always in effect). When the sandbox is enabled (`!sandbox on` or `!sandbox bwrap|docker|podman`), execution goes through the corresponding isolation engine.
- **Automatic Buffer Flushing:** In `buffer.auto_apply: on_test` or `always` mode, writes dirty buffers to disk immediately before the command executes.
- **Isolation Transparency:** In direct host mode, the safe execution guardrails are in effect; for hardened OS-level isolation, Bubblewrap (`bwrap`) or containers (`docker`/`podman`) can be used.

```bash
!sh git status
!sh cargo check
```

### `!sandbox [on|off|status|<engine>]`
Inspects or toggles the sandbox isolation cage, or dynamically switches the active engine.

- `!sandbox` / `!sandbox status`: Lists the current isolation status, the active driver, network restrictions, and the registered engines.
- `!sandbox on`: Enables the sandbox (defaults to `bwrap` on Linux).
- `!sandbox off`: Disables the sandbox (falls back to direct safe host execution).
- `!sandbox <engine>`: Activates the requested driver (`bwrap`, `docker`, `podman`, `firejail`, etc.).
- Flags: `--project` (`-p`) persists to the active project; `--global` (`-g`) persists to the global configuration.

```bash
!sandbox                                     # Shows the sandbox status and registered drivers
!sandbox on                                  # Enables the OS sandbox cage
!sandbox off                                 # Switches to direct safe host mode
!sandbox docker -p                           # Selects the Docker sandbox engine for the active project
!sandbox firejail                            # Selects the Firejail driver registered by a plugin
```

### `!tasks [list | status <id> | logs <id> | kill <id> | kill-all]` (or `!task`)
Manages long-running or uninterrupted asynchronous background processes (servers, compilers, test watch modes).

- `!tasks` or `!tasks list`: Lists the status, PID, and runtime of all running and finished background tasks.
- `!tasks status <task_id>`: Reports the detailed run status of the given background process, its PID, command, and buffered line count.
- `!tasks logs <task_id> [--tail N]`: Dumps the latest log output from the task's ring buffer (`RingBuffer`, last 500 lines).
- `!tasks kill <task_id>`: Cleanly terminates the given background process and its child process tree (`Platform.kill_tree`).
- `!tasks kill-all`: Terminates all running background tasks in one sweep.

```bash
!tasks                                       # Lists active and finished tasks
!tasks status task-1                         # Shows the detailed status of the task-1 process
!tasks logs task-1 --tail 100                # Dumps the last 100 log lines for task-1
!tasks kill task-1                           # Kills the task-1 process
!tasks kill-all                              # Shuts down all background processes
```

### `!subagents [list | status <id> | types | wait [id] [sec] | extend <id> [steps] | kill <id> | reuse <id> <prompt...> | clean | kill-all]` (or `!subagent`)
The subagent supervisor architecture models Linux `init` (PID 1: parent of the tree, reaper of orphans); the LIFO teardown of `kill-all` evokes runlevel 0 (`init 0`, orderly halt) — two distinct Linux concepts the design deliberately encompasses. The root persona driving it is `maestro` (machine identity `agent-0`).

- `!subagents` or `!subagents list`: Lists all active, completed, and QUEUED subagents with their ID, role, type, live status (`running`, `waiting_input`, `waiting_budget`, `completed`, `failed`, `queued`), parent, and step counts. `waiting_input` means the subagent has asked the maestro a question via `ask_question` and is **blocked waiting for an answer** — answer it with the agent's `send_message` tool (`recipient: '<id>'`) within `subagents.question_timeout`. `queued` means it is waiting on the spec's `depends_on` constraint (FS/SS) and holds no slot/cost.
- `!subagents status <id>`: Shows the given subagent's detailed status, its last tool call, step budget, transcript log URI, and error message.
- `!subagents types`: Lists the subagent types registered in the system (`research`, `self`, `coder`, and custom-defined types) and their tool permissions.
- `!subagents wait [id] [sec]`: Waits for the given — or all active — subagents to complete or to enter budget-wait.
- `!subagents extend <id> [steps]`: Grants extra steps to a subagent whose step budget ran out (`waiting_budget`) and resumes its execution.
- `!subagents kill <id>`: Safely terminates the given subagent and all of its descendants (`cascading cleanup`).
- `!subagents kill-all`: Terminates all subagents under the supervisor in one sweep (`maestro` LIFO teardown).
- `!subagents reuse <id> <prompt...>`: Assigns a new task to a finished (completed/failed) subagent while PRESERVING its accumulated context (context-preserving redeploy) — the cheap way to hand follow-up work to the same subagent; it reruns in the background with a fresh budget.
- `!subagents clean`: Immediately reaps all finished subagents (`reap`): the in-memory history is released, the durable transcript and the `rubik://storage` index remain, and tombstones stay queryable. The same reaping happens automatically after the `subagents.reap_finished_after` grace period.

```bash
!subagents                                   # Lists the status of all subagents
!subagents status subagent-1                 # Inspects the details of the subagent-1 process
!subagents types                             # Lists the registered archetype types
!subagents wait subagent-1 30                # Waits 30s for subagent-1 to complete
!subagents extend subagent-1 15              # Extends subagent-1's budget by 15 steps
!subagents reuse subagent-1 summarize it now # Hands the finished agent a new task, preserving context
!subagents clean                             # Reaps finished agents (transcripts are kept)
!subagents kill subagent-1                   # Terminates the subagent and its sub-branches
!subagents kill-all                          # Shuts down all subagents (maestro)
```

---

## 💾 7. Session, History & General Settings

### `!session`
Lists past sessions, displays session details, or resumes an old session where it left off. On interactive terminals, `!session resume` (without an id) opens the arrow-key session picker.
```bash
!session list                                # Lists the recorded sessions
!session resume                              # TTY: session picker · pipe: latest session
!session resume sess_20260823_180000         # Loads the given session
!session info                                # Shows the active session's event count and file
```

### `!history` & `!replay`
Inspects the session history or replays the command stream.
```bash
!history                                     # Dumps the recent command and prompt history
!replay .rubik/sessions/latest.jsonl         # Re-executes the session step by step from the start
```

### `!config`
Reads or writes the runtime settings, or shows the active configuration file locations.
```bash
!config path                                 # Shows the global and project config paths
!config get buffer.auto_apply                # Reads the value of a specific setting
!config set buffer.auto_apply on_test        # Saves to the global config
!config set buffer.auto_apply on_test -p     # Saves to the project config (.rubik/config.yml)

# LLM STREAMING (LIVE STREAMING) & BATCH MODE:
!config get llm.stream                       # Queries the live token streaming status (Default: true)
!config set llm.stream false -g              # Switches globally to the classic blocking batch mode
!config set llm.stream true -g               # Enables live token streaming globally
```

### `!skill` & `!skills`
Manages the Agent Skills infrastructure (agentskills.io). Skills are discovered from `.rubik/skills/<name>/SKILL.md` (project), `~/.rubik/skills/<name>/SKILL.md` (user), and the directories configured under `skills.paths`. `!skills` is shorthand for `!skill list`.
```bash
!skill list                                  # Lists the discovered skills with their scopes and descriptions
!skill show <name>                           # Displays the skill's full SKILL.md body
!skill info <name>                           # Path, scope, body length, and frontmatter validation notes
!skill reload                                # Rescans the skill registry from scratch (zero-downtime)
```

### `!verbosity` & `!verbose`
Displays or changes the agent's live output verbosity level (0-3) during step execution.
- `0 - quiet`: Zero intermediate noise, only the final answer and critical errors.
- `1 - normal`: Clean, polished step & tool progress view (Default).
- `2 - verbose`: Detailed JSON arguments, a first-5-lines output preview, and intermediate thoughts (`[Thought]`).
- `3 - debug`: Raw tool inputs/outputs, microsecond timings, and diagnostic information.

```bash
!verbosity                                   # Shows the active verbosity level and all levels
!verbosity quiet                             # Switches to quiet mode (0)
!verbosity normal                            # Switches to standard mode (1)
!verbosity verbose                           # Switches to verbose mode (2)
!verbosity debug                             # Switches to diagnostic/debug mode (3)
!verbosity 2 -p                              # Persists the verbose level at the project level
!verbose                                     # Instantly toggles between normal <-> verbose
!verbose on                                  # Turns verbose mode on
!verbose off                                 # Turns verbose mode off (returns to normal)
```

### `!workspace` & `!roots`
Dynamically manages, lists, or removes multiple workspace root directories in monorepo or multi-package architectures.
```bash
!workspace list                              # Lists the configured primary and extra root directories
!roots list                                  # Same as !workspace list (alias)
!workspace add ../shared-kernel              # Adds a read-only extra root directory and includes it in the AST index
!workspace add ../proto --rw                 # Adds a writable (--rw) extra root directory
!workspace add ../contracts -p               # Adds it persistently at the project level (.rubik/config.yml)
!workspace remove ../shared-kernel           # Removes the extra root directory from the workspace
```

### `!allow-dir` & `!allow-cmd`
Operator-approved security allowlist for external directories and command prefixes. Both commands are **available to the human operator only** (`audience: :human`); the agent cannot invoke them via `exec_repl_command` (fail-closed). `!allow` is a deprecated one-liner alias of `!allow-dir`.
```bash
!allow-dir ../shared-assets                  # Adds the external directory to Buffer I/O and the Sandbox (default: read-write, no AST indexing)
!allow-dir ../shared-assets --ro             # Adds it in read-only mode (--ro / -r)
!allow-dir list                              # Lists the approved external directories
!allow-dir remove ../shared-assets           # Removes the directory from the list
!allow-cmd list                              # Lists the approved command prefixes
!allow-cmd add "node .gitnexus/run.cjs"      # Allowlists a narrow command prefix (scope with --project/--global)
!allow-cmd remove "node .gitnexus/run.cjs"   # Removes the prefix from the list
```
> ℹ️ Security rules: ① Broad, dangerous stand-alone tokens (`node`, `python`, `bash`) **are rejected in all circumstances, even with `--force`** — an allowlist entry must contain a narrow prefix (e.g. `node <script>`); destructive chains (`rm -rf /`-style) can likewise never be added to the allowlist. ② The `!allow-dir` default is **Read-Write**; use `--ro`/`-r` for read-only (the `--rw`/`-w` flags are parsed but currently have no effect). Related configuration: `security.command_allowlist`.

### `!paste`
Multi-line paste mode. Since the Windows console does not offer bracketed paste, a pasted block arrives line by line; with `!paste`, lines are collected until a lone `.` is entered, and the whole thing is executed as a **single prompt turn**. No reliance on timing heuristics whatsoever; blank and trailing lines are preserved verbatim. (Automatic path: rapidly consecutive lines merge into a single turn within the `ui.paste_join_window_ms` window — see the `ui:` template in [CONFIG.md](CONFIG.md).)
```bash
!paste
def foo
  puts 1
end
.
```

### `!status`, `!commands`, `!help`, `!clear`, `!reset`, `!quit`
```bash
!status                                      # Project name, git branch, model, and buffer status
!commands                                    # Summary of all built-in and dynamic commands
!help [command]                              # Help output (e.g.: !help provider)
!clear                                       # Clears the conversation context; starts the new topic from scratch
!reset                                       # Same as !clear: resets the conversation history and in-memory dialogue turns
!quit or !exit                               # Exits the REPL shell safely
```

---

## 🧬 8. Dynamically Synthesized Commands (Self-Evolving)

Using the `synthesize_command` tool, the model running inside Rubik can generate project-specific new commands during a session.

> **Detailed Self-Evolution Guide:** For live scenarios and examples showing how LLMs evolve Rubik step by step, see the **[`SELF_EVOLUTION.md`](SELF_EVOLUTION.md)** document.

Example: a `!db_seed` or `!benchmark_api` command created by the model is registered in the REPL table instantly and can be invoked directly as a `!` command:

```bash
rubik (my_project) [main] > !db_seed
Seeding development database with 50 mock users... Done!
```

---

## 🛠️ 9. Direct Model Tools (Native Toolbelt) & Targeted Editing

To let frontier-level coding models (`Claude 3.7 / 3.5 Sonnet`, `GPT-4o`, `DeepSeek-Coder-V3/R1`, `Qwen 2.5 Coder`) work with a high success rate, Rubik offers surgically targeted code editing and Elm-compiler-style error feedback:

> **Full Tool Catalog:** For the list of the 34 built-in agent tools, their parameters, risk classes, and diagnostic formats, see the **[`TOOLS.md`](TOOLS.md)** document.

### A. Targeted Code Editing (`replace_file_content`)
In existing files, surgically replaces only the block that needs to change instead of rewriting the whole file:
- **Parameters:**
  - `path`: File path.
  - `target_content`: The existing text to replace (whitespace and indentation must match exactly).
  - `replacement_content`: The new text.
  - `start_line` / `end_line` *(Optional)*: The line range to search within.
  - `allow_multiple` *(Optional, default: false)*: Replaces every match in the file in one go.

### B. Elm-Style Actionable Error Architecture (`DiagnosticReporter`)
When a file, symbol, or tool cannot be found, the model receives the following instead of a bare error:
1. **Problem Statement:** What could not be found, and why.
2. **Did you mean? (Suggestion):** The closest file, symbol, or tool names (`did_you_mean` & `diff-lcs`).
3. **Actionable Next Steps:** Steps telling the model what it should do next.

### C. Autonomous Tool Synthesis (`synthesize_tool`)
When the model needs a custom capability not present in the built-in tool set (custom AST manipulation, a custom format converter, benchmarks, etc.), it generates its own tool at runtime (`synthesize_tool`) and adds it to the toolbelt.

When the session closes or the context is disposed, the spatiotemporal LIFO inverse mechanism ensures all dynamic commands are cleaned up without leaving zombie references behind.

### D. Central Storage Database (`storage` tool + `rubik://storage`)

Agent work artifacts — goals, plans, memory notes, wiki knowledge, reviews — are kept in the central virtual FS-DB instead of files scattered across the worktree; the maestro and `coder` subagents write with the `storage` tool, and everyone reads via URI through `read_file`:

- **Writing (the `coder` archetype only):** the `storage` tool — actions `put` (create/update; returns the id + a `rubik://storage/...` URI), `get`, `list`, `search` (case-insensitive over title/body/tags), `set_ref` (human-readable alias), `delete`.
- **Reading (all archetypes — research included, via `read_file`):**
  - `rubik://storage/index` — the central index (projects, counts, timestamps)
  - `rubik://storage/<project>/<type>` — type listing · `rubik://storage/<project>/<type>/<id>` — entity
  - `rubik://storage/<project>/refs/<alias>` — alias resolution · `rubik://storage/<type>/...` — short form with the default project
  - Appending `.json` to the end of any form returns raw JSON.
- **Identity:** every entity is `type.row.hash16` (e.g. `plan.3.9f86d081884c7d21`); row numbers are unique within a type and never reused, and updates keep the id (`version` increments, `hash` tracks the current content). Resolution forms: full id · `plan.3` · row `3` · hash prefix · alias.
- **Entity types:** `goal`, `plan`, `memory`, `wiki`, `transcript`, `review`, `note`.
- **Transcript indexing:** when a subagent completes, its transcript is automatically indexed as a `transcript` entity (alias `subagent-<storage-id>`; searchable via `storage search`).
- **Worktree cleanliness (absorb):** with `storage.absorb_artifacts: true` (the default), NEW session files and subagent transcripts are written under `~/.rubik/rubikstorage/<project>/`; the legacy `.rubik/sessions|subagents` locations keep being read (the `!session` list sees both).

## Plugin (Drop-in Plugin) Management
The `!plugin` subcommands are used to manage plugins dynamically from inside the REPL:

- `!plugin add <path> [--global]`: Safely adds the `.rb` file or plugin directory at the given path under `.rubik/plugins` (or `~/.rubik/plugins` for global) and loads it instantly.
- `!plugin remove <name> [--global]`: Deletes the given plugin from disk and cleans up its fiber/hook wiring in the runtime according to the LIFO rules.
- `!plugin reload <name>`: Reloads the plugin with zero downtime (first cleans up safely, then starts the new version).
- `!plugin list`: Lists the active plugins loaded on the system and in the project, with their scopes (global/project) and statuses.
- `!plugins`: Shortcut for `!plugin list` — lists the loaded plugins directly.
- `!plugin info <name>`: Prints the plugin's details, version, and dependencies.
