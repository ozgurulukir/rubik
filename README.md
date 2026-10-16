# 🎲 Rubik — Autonomous AI Coding Agent & REPL Harness

English | [Türkçe](README.tr.md)

> A next-generation autonomous pair-programming and REPL harness written in pure Ruby, built on the **Spatiotemporal Composability & Self-Evolving Runtime** architecture.

[![Gem Version](https://img.shields.io/gem/v/rubik.svg)](https://rubygems.org/gems/rubik)
[![Gem Downloads](https://img.shields.io/gem/dt/rubik.svg)](https://rubygems.org/gems/rubik)
[![Ruby Version](https://img.shields.io/badge/ruby-3.4%2B-red.svg)](https://www.ruby-lang.org)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-blue.svg)]()
[![Protocol](https://img.shields.io/badge/protocol-AGENTS.md-blue.svg)](AGENTS.md)
[![Commands Guide](https://img.shields.io/badge/docs-COMMANDS.md-yellow.svg)](COMMANDS.md)
[![Config Guide](https://img.shields.io/badge/docs-CONFIG.md-green.svg)](CONFIG.md)
[![Test Suite](https://img.shields.io/badge/tests-3403%20runs%20%7C%20100%25%20passed-brightgreen.svg)]()

---

## 👋 What is Rubik?

Rubik is a terminal-native autonomous coding agent and interactive REPL in pure Ruby. A **maestro** agent orchestrates specialized subagents (research / coder / self) over a 34-tool belt while you keep the wheel: file edits stage in a reviewable in-memory buffer (`!diff` → `!apply`), every runtime side effect is registered with a LIFO inverse (zero-restart reloads and teardown), and failing services are diagnosed and repaired live. It runs cross-platform (Linux, macOS, Windows), talks to any OpenAI-compatible endpoint, Anthropic, or local Ollama, and the whole runtime is embeddable from Ruby with `require "rubik"`.

---

## 🚀 Quick Start

### From the gem

Requires **Ruby 3.4+**:

CI tests Linux on Ruby 3.4 (minimum) and 4.0, and macOS and Windows on
Ruby 4.0. Each job installs dependencies, runs the full unit/integration suite,
and builds, installs and smokes the gem (`rubik --version` and `require "rubik"`).
See [CI runs](https://github.com/ozgurulukir/rubik/actions/workflows/ci.yml)
for results on a specific commit; platform artifacts contain environment details,
installation/smoke logs, test counts and skip reasons. Other Ruby/OS combinations
are not covered by this bounded matrix.


```bash
gem install rubik
```

The installer puts the `rubik` launcher into RubyGems' bin directory (already on your `PATH`), so you can start it from any project directory:

```bash
rubik
```

or with Bundler:

```ruby
gem "rubik"
```

#### Platform notes

| Platform | Install experience |
| :--- | :--- |
| 🐧 Linux / 🍎 macOS | `gem install rubik` — dependencies ship prebuilt. |
| 🪟 Windows | `tree_sitter_language_pack` has no Windows prebuilt and compiles from source: install Rust with the GNU toolchain and export `RUST_TARGET=x86_64-pc-windows-gnu` before installing. The exact, working recipe is [`.github/workflows/ci.yml`](.github/workflows/ci.yml). |

### From source

**Prerequisites**

- **Ruby:** 3.4.0 or later (`ruby -v`)
  - **Linux / macOS:** Via the system package manager, `rbenv`, `rvm`, or `asdf`.
  - **Windows:** [Scoop](https://scoop.sh) (`scoop install ruby`) or [RubyInstaller with DevKit](https://rubyinstaller.org).
- **Git:** Git 2.30+ (`git -v`)
- **LLM Provider:** Local [Ollama](https://ollama.ai) (`ollama run qwen2.5-coder:7b`) or a DeepSeek, OpenRouter, Anthropic, or OpenAI API key.

Clone the project, install the dependencies, and start the REPL:

```bash
git clone https://github.com/ozgurulukir/rubik.git
cd rubik
bundle install
```

#### 🐧 Linux & 🍎 macOS (POSIX)

```bash
# Proje dizininden doğrudan çalıştırma
./bin/rubik

# Veya sistemde global kullanmak için ~/.local/bin dizinine bağlayın:
ln -sf $(pwd)/bin/rubik ~/.local/bin/rubik
rubik
```

> [!NOTE]
> **The gem and a clone can coexist.** On POSIX the symlink always runs your clone: `bin/rubik` resolves `lib/` from its own real path, so a `git pull` is live on the very next launch — even while the `rubik` gem stays installed. The gem-installed `rubik` keeps serving the last released version until you run `gem update rubik`. On Windows, whichever `bin` folder comes first in `PATH` wins — `where.exe rubik` shows the winner.

#### 🪟 Windows (PowerShell / Command Prompt)

Rubik ships with built-in `.cmd`, `.bat`, and `.ps1` wrappers for Windows:

```powershell
# PowerShell üzerinden çalıştırma
.\bin\rubik.ps1

# veya Command Prompt / Terminal üzerinden
.\bin\rubik.cmd

# veya Ruby üzerinden doğrudan
ruby bin\rubik
```

> [!TIP]
> **The Global `rubik` Command on Windows:**  
> By adding Rubik's `bin` folder to your environment variables (User PATH), you can launch it from any terminal simply by typing `rubik`:
> ```powershell
> [Environment]::SetEnvironmentVariable("PATH", "$env:PATH;$PWD\bin", "User")
> ```

### Adding a Provider & Model

You can connect any OpenAI-compatible provider in a single line:

```bash
# REPL içerisinden sağlayıcı ekleme:
rubik > !provider add deepseek openai_compatible https://api.deepseek.com/v1/chat/completions --key=sk-... --model=deepseek-coder --context=64000
rubik > !model deepseek/deepseek-coder
```

Anthropic talks over its **native Messages API** (not an OpenAI shim): the `anthropic` provider is registered out of the box — set `ANTHROPIC_API_KEY` and pick a model:

```bash
rubik > !model anthropic/claude-sonnet-5-5
```

### First Session Example

```text
╭── rubik ─────────────────────────────────────────────────╮
│ 🎲 Rubik v0.1.0                                          │
│ deepseek/deepseek-coder                                  │
│ my_project · main                                        │
│ !help komutlar · ctrl+c kes · !config ayarlar            │
╰──────────────────────────────────────────────────────────╯
deepseek/deepseek-coder · ctx 3% · temiz · sandbox kapalı
rubik (my_project) [main] > !status
Project: my_project (main)
Default Model: deepseek/deepseek-coder
Dirty buffer: false

rubik (my_project) [main] > Kullanıcı kayıt formunu doğrulayan bir helper fonksiyonu yaz
✻ Düşünüyor… · 1s (ctrl+c: kes)
⏺ write_file — lib/validator.rb
  ⎿ 3 lines · 18ms

[Rubik] In-memory buffer updated. Type `!diff` to view, `!apply` to save.

rubik (my_project) [main] [DIRTY: 1 ✎] > !diff
+ def validate_user(params)
+   raise "Invalid email" unless params[:email]&.include?("@")
+ end

rubik (my_project) [main] [DIRTY: 1 ✎] > !test
Applied 1 file(s) before test. All 12 tests passed!
```

> [!TIP]
> **Safe Execution (Tree-Sitter AST) & Hardware-Enforced OS Isolation (Bubblewrap / Container):**  
> Before running any command, Rubik always keeps the `Security::Guard` shield active (Safe Execution), which detects dangerous commands, pipeline poisoning, and directory escapes ahead of time via Tree-Sitter syntax-tree (AST) analysis for Bash and PowerShell plus a database of 172 CLI YAML rules. For hardware-enforced OS isolation on Linux, use Bubblewrap (`bwrap`) or OCI (`docker`/`podman`):
> ```bash
> !sandbox on                                  # Linux'ta Bubblewrap ile donanımsal OS izolasyonunu açar
> !config set sandbox.allow_network true -p   # Ağ erişimi gerektiren komutlar için izin verir
> ```

---

## ⚡ Key Features

- 🌐 **Full Cross-Platform Support (Linux, macOS, Windows):** Runs with zero friction on Windows 11 / Windows Server environments (PowerShell, Command Prompt, Windows Terminal) in addition to POSIX systems. Ships with a pure-Ruby binary resolution solution, NTFS case-insensitivity handling, the RFC 8089 LSP URI standard, and native Windows CLI (`.cmd`, `.bat`, `.ps1`) wrappers.
- 🛡️ **Zero-Risk In-Memory Buffer:** When the model writes code, your files are not written to disk immediately; they are staged in an in-memory virtual buffer. You can inspect them with `!diff`, approve them with `!apply`, or revert them within seconds with `!undo`.
- 🏢 **Multi-Workspace & Extra Root Directories:** In monorepo or sibling-package layouts (`../shared-kernel`, `../proto`), you can safely attach external root directories (`!workspace add`) and include them in the buffer and the AST index in read-only or writable (`--rw`) mode.
- ⚡ **Live LSP Compiler Diagnostics:** While the model writes code, language servers such as `rust-analyzer`, `typescript-language-server`, `ruff`, `typeprof`, and `gopls` stand guard. As soon as a syntax or type error occurs, the model is alerted before any tests have even run.
- 🌳 **Multilingual Tree-Sitter & Prism Hybrid AST Engine:** Ships with the built-in **Prism** parser for Ruby and a full **Tree-Sitter** AST engine for Python, Go, Rust, TypeScript, TSX, JavaScript, C, C++, and Zig. It is 100% immune to curly-brace traps inside comments/strings and to modern language patterns; when a library is unavailable it silently falls back to the legacy regex extractors (fail-safe graceful fallback). The symbol and call graph (`!symbols`, `!outline`, `!refs`) is scanned asynchronously in the background; thanks to the compact persistent on-disk cache (`.rubik/cache/ast_index.json`), warm-load timings for a 150-file synthetic Ruby fixture are recorded with cold-scan comparisons; see [_report/runtime-capacity-validation-2026-10-16.md](_report/runtime-capacity-validation-2026-10-16.md)).
- 🤖 **Dynamic LLM Providers & Multi-Role Routing:** Light/heavy task routing with support for all OpenAI-compatible endpoints (DeepSeek, Groq, OpenRouter, Mistral, vLLM), Anthropic Claude, OpenAI, and local Ollama.
- 🧬 **Spatiotemporal Composability & Self-Evolving Runtime:** The model can synthesize new REPL commands (`synthesize_command`) or built-in tools (`synthesize_tool`) at runtime; every side effect is tracked safely by the LIFO inverse-operation accumulator ($\Omega$).
- 🩹 **Self-Healing Runtime (Service Repair Plane):** Runtime components never require a process restart. `inspect_runtime` exposes the live fiber/coeffect/service state; `repair_runtime_service` diagnoses a failing component (LSP server, test runner, linter, or shell command), probes replacement commands with pre-flight verification in an isolated sub-context, and re-provides the repaired service — session state, caches, and conversations stay intact. `provide_service` registers new services live. Repair probes are bounded and disposable; failed promotion or persistence restores session state. Successfully saved operator configuration survives lifecycle cleanup. See [runtime repair](RUNTIME_REPAIR.md) for probe and rollback contracts.
- 📋 **Structured Goal Ledger (SKILL.state adaptation):** the `!goal` loop keeps a rev-guarded ΔΣ ledger (objective, tasks, findings, decisions, open questions, environment notes) instead of trusting lossy conversation memory. The maestro patches it with the root-only `update_goal_ledger` tool (classified syntax/schema/conflict feedback, bounded retries), the current Σ is pinned through every compaction tier and re-injected each step, every revision is appended to storage (`goal-ledger` ref), declarative `verify` specs are re-checked at step boundaries (a failed check flips the task to `stale` — the world-drift signal), and banked tool results compact into per-row `<absorbed_into_ledger>` tombstones. Default ON (`goal.ledger.*`, operator-only; opt-out per key).
- 🧹 **Context Pruner (Semi-Deterministic Window Cleanup):** Long sessions accumulate stale exploration in the maestro's conversation window. A Vakanüvis-style two-plane pruner cleans it: a silent LLM subagent proposes a keep/drop/summarize plan, and the harness validates it deterministically (goal pinning, tool-use pairing, head/tail preservation bands, token budget) and applies it atomically at the next turn boundary — never mid-turn. It auto-fires at 60% of the input ceiling (before the blind drop-oldest trimmer would) or on demand via the `prune_context` tool and `!prune`. Default ON since 2026-10-10 (`subagents.pruner.*`, operator-only; opt-out `enabled: false`); the deterministic compaction stack always remains the safety net.
- 🔌 **Drop-in Plugin System (User Plugins):** `.rb` plugin files (drop-in) or directories under `~/.rubik/plugins` (global) or `.rubik/plugins` (project) are loaded automatically. Plugins are managed dynamically and with zero downtime from the REPL (`!plugin add`, `!plugin reload`); integrity is enforced through SHA-256 `.manifest.json` security verification.
- 🔌 **Model Context Protocol (MCP) & Spatiotemporal Tool Isolation:** Dynamically attaches external MCP servers (`filesystem`, `fetch`, databases, GitHub, etc.) over the stdio transport (`!mcp connect`, `!mcp add`). Discovered tools join the registry as `Rubik::Tools::BaseTool` proxies; when a server stops or crashes, the `AGENTS.md` LIFO inverse-operation accumulator ($\Omega$), recursive process-tree termination (`Platform.kill_tree`), and atomic rollback prevent orphan processes and file-descriptor leaks (tested across 1,000 normal, handshake-failure, and crash/recovery cycles, with explicit resource tolerances; see [_report/runtime-capacity-validation-2026-10-16.md](_report/runtime-capacity-validation-2026-10-16.md)).
- 📺 **Tiered Live Agent Monitoring (Step Formatter & Verbosity):** With the `quiet`, `normal`, `verbose`, and `debug` levels, step progress, tool calls, execution times, and intermediate thoughts are watched in real time (`!verbosity`, `!verbose`).
- 🎨 **Hybrid TUI Display Layer:** The `⏺/⎿` agent flow language, a live spinner cycling through Turkish verbs (`✻ Kavuruyor… 4sn`), an above-prompt statusline (model · context percentage · dirty buffer), live markdown rendering, a colored diff viewer, one-key quick approvals, and the interactive `!agents` fiber board. Under `NO_COLOR`/`--no-color` and in pipe mode the output degrades to plain text; session logs never contain ANSI codes (live settings via `!config set ui.*`).
- ⚡ **Native Tool Acceleration:** When available on the system, `grep_search` is delegated to ripgrep and context scanning to `git ls-files`; AST symbols warm up with lazy body loading. Without rg/git, or with `tools.native: off` or `RUBIK_NATIVE=off`, every path falls back to pure Ruby with identical output — the output format never changes.
- 🧵 **Quiet Concurrency (Fiber Scheduler Event Loop):** The pure-stdlib `Rubik::Concurrency` layer provides cooperative single-threaded concurrency WITHOUT altering any existing blocking I/O call sites (Net::HTTP, sleep, Open3 pipes, Mutex/CV/Thread#join): tested at 100 and 1,000 concurrent local network requests, including latency, timeout, cancellation, and sequential comparisons; see [_report/runtime-capacity-validation-2026-10-16.md](_report/runtime-capacity-validation-2026-10-16.md)), the MCP boot fan-out, and the subagent provider pool all run through the `Concurrency.silently`/`.map` boundary (not CPU parallelism, due to the GVL). Kill switch: `RUBIK_FIBER_SCHEDULER=off`.
- 📜 **Vakanüvis Chronicler (Session Annals):** The deterministic harness records REPL root turns and subagent lifecycle events into the `rubik://storage` annals; a budget-capped LLM distiller mines memory and a wiki skeleton from those annals. All planes are governed by `subagents.vakanuvis.*`; chronicles can be recalled through the Vakanüvis tool (`recall`/`record`/`forget`/`digest`).

> 🛡️ **Security note — when cloning unfamiliar repositories:** The `.rubik/commands` and `.rubik/tools` directories contain overlay files that can be interpreted at runtime. SHA-256 manifest verification blocks later modifications; files carrying a sentinel header but no manifest are accepted on the first scan only with the explicit consent of `RUBIK_BOOTSTRAP_OVERLAYS=1`. If you have cloned a repository you do not know, inspect the `.rubik/` directory before the first run.

---

## 🕹️ REPL Bang Commands

For detailed parameters, flags, and usage scenarios of all 30+ interactive commands:  
👉 Check out the **[COMMANDS.md — Comprehensive REPL Command Guide](COMMANDS.md)** document.

### Command Summary Table

| Command Group | Key Commands | Description |
| :--- | :--- | :--- |
| **Models & Providers** | `!provider`, `!providers`, `!model` | Provider add/remove (CRUD), model role assignment, and smart routing. |
| **Agent & Planning** | `!plan`, `!goal`, `!steps` | Step-by-step planning, the autonomous goal loop, and step budget management. |
| **Buffer & Snapshots** | `!diff`, `!apply`, `!autoapply`, `!undo` | Inspect the in-memory virtual file buffer, save to disk, and revert. |
| **Runtime & Fibers** | `!runtime`, `!fibers`, `!services` | Coeffect services, active/pending fibers, and the $\Omega$ inverse depth. |
| **Code Intelligence & LSP** | `!lsp`, `!symbols`, `!outline`, `!refs` | Compiler diagnostics and semantic AST graph searches. |
| **Tests & Execution** | `!test`, `!lint`, `!format`, `!sh`, `!sandbox` | Multilingual test runs, Safe Execution, and a pluggable sandbox (bwrap/docker/podman). |
| **Session & Settings** | `!session`, `!history`, `!config`, `!verbosity`, `!status` | Session persistence, resuming with `rubik -c`, verbosity, and live settings. |
| **Workspace & Roots** | `!workspace`, `!roots`, `!allow` | Adding/removing multiple root directories (`add`/`remove`), external permissions (`!allow`), and status listing. |

### Agent Surface Contract

Every command is typed with an `audience` at registration time: `:human` (operator only), `:agent`, or `:both`. Agent-visible built-in commands (`!diff`, `!status`, `!undo`, `!rollback`, `!autoapply`, `!context`, `!steps`, `!config`, `!model`, `!providers`, `!runtime`, `!fibers`, `!services`, `!agents`, `!lint`, `!format`, `!history`, `!prune`) are published as `<agent_commands>` in the system prompt and can be invoked via the `exec_repl_command` tool; file, code, test, and shell operations are always performed directly through the tools (`read_file`, `write_file`, `run_tests`, `run_command`). Human-only commands (`!provider`, `!workspace`, `!allow`, `!verbosity`, …) are reported back to the agent as a steering message; session lifecycle commands (`!quit`, `!exit`, `!clear`, `!reset`) are hard-blocked for the agent, while `!plan`/`!goal` are redirected to the "finish" tool behind reentrancy protection. Two notes: a `!model` switch takes effect on the next agent run; and `!undo`/`!rollback` revert buffer changes not yet applied to disk, while in `buffer.auto_apply` = `on_test`/`always` mode they may trigger the pre-run auto-apply.

---

## ⚙️ Configuration

For details on all model, LSP, buffer policy, provider, and sandbox settings:  
👉 Check out the **[CONFIG.md — Rubik Configuration Guide](CONFIG.md)** document.

---

## 🖥️ Agent Shell Behavior

`run_command` commands are never left to an implicit interpreter: the Safe Execution infrastructure runs every command with a **resolved shell** and an explicit argv array. `sandbox.shell: auto` (the default) chooses per command via a syntax gate — bash-required syntax (`<(...)`, `/dev/null`, heredocs) and `$` substitutions go to **bash**, the PowerShell fingerprint (`$env:`, `Select-String`, `Get-*` and other cmdlets) goes to **pwsh**, and plain commands take the fast path to **cmd** on Windows (bash elsewhere). The choice is labeled in the result (`[EXIT 1] (bash)`), and the system prompt announces the shell behavior to the model up front via the `<environment>` line — the model now knows which shell it is writing commands for. Use `sandbox.shell: bash|pwsh|cmd|sh` to pin a preference (see [CONFIG.md](CONFIG.md) §7).

---

## 🧪 Test Suite

Full suite: `rake` (or `rake test`). Single file: `ruby -Itest test/unit/test_repl.rb`.

Windows notes:
- Tests run sequentially in a single process; multi-file arguments such as `ruby -Itest a.rb b.rb` run only the **first** file — always use `rake` for the full suite.
- A space-containing `TEST` value such as `rake test TEST="a b"` is interpreted as a single path on Windows; make one invocation per file.
- Temp-directory removal (`teardown`) can fail with `Errno::EACCES` on Windows while a handle is still open; the `remove_temp_dir` helper in `test_helper.rb` swallows this with a best-effort retry and never muddies test results.

Environmental test skips:
- PowerShell shell execution tests are skipped when the `pwsh` (PowerShell Core) binary is not present on the system.
- Alternative AST parser tests are skipped when the `prism` gem or its C extension is not present on the system.
- In non-interactive / headless CI environments, direct TUI/reline terminal tests automatically run in non-blocking mode or are skipped in a controlled way.
- Capability skips report their reasons; unexpected failures still fail CI. A passing run describes that runner and commit, not a universal platform guarantee.

---

## 📦 Versioning Policy & SemVer 2.0 (Pre-1.0 Stability Roadmap)

Rubik adopts the [Semantic Versioning 2.0.0](https://semver.org/) standard. In the current pre-1.0 release (`0.1.0`), the Spatiotemporal Composability core architecture, the fiber lifecycle, and the agent protocols are being hardened:
- **0.x Releases:** A phase of rapid architectural evolution and refinement of experimental capabilities. Improvements to the core APIs are managed alongside the plan documents.
- **1.0.0 Goal:** Reaching production stability by freezing the core SPI interfaces, the Revertible Effects LIFO protocol, and the agent surface contract.
- **Backward Compatibility:** Before every minor release, comprehensive backward-compatibility and SPI breakage analyses (using GitNexus knowledge-graph & PDG analysis) are mandatory.

---

## 📚 Documentation

Every guide ships as a bilingual pair — `X.md` (English, authoritative) alongside `X.tr.md` (Turkish translation).

### Architecture & Internals

| Guide | What it covers |
| :--- | :--- |
| 🌌 [AGENTS.md](AGENTS.md) | The Spatiotemporal Composability Protocol — theory, invariants, the fiber lifecycle state machine. |
| 🏗️ [ARCHITECTURE.md](ARCHITECTURE.md) | The 30 core domains and the responsibility matrix. |
| 🧬 [SELF_EVOLUTION.md](SELF_EVOLUTION.md) | How the LLM synthesizes tools, repairs services, and evolves its own runtime. |
| 🔌 [API.md](API.md) | Embedding the runtime from Ruby: config, tool registry, provider contract, orchestrator loop, error contracts. |

### User & Operator Guides

| Guide | What it covers |
| :--- | :--- |
| 🕹️ [COMMANDS.md](COMMANDS.md) | All 30+ REPL bang commands with parameters and usage scenarios. |
| 🧰 [TOOLS.md](TOOLS.md) | Catalog of the 34 built-in agent tools: parameters, risk classes, diagnostics. |
| ⚙️ [CONFIG.md](CONFIG.md) | Every configuration knob (models, LSP, buffer policy, sandbox, subagents, pruner…). |
| 🌍 [ENV.md](ENV.md) | Environment variables — single consolidated reference table. |
| 🖥️ [LSP.md](LSP.md) | Step-by-step language-server setup and diagnostics walkthrough. |
| 🔌 [PLUGINS.md](PLUGINS.md) | The drop-in plugin system: layout, manifests, zero-downtime reloads. |

### Project & Policy

| Guide | What it covers |
| :--- | :--- |
| 🤝 [CONTRIBUTING.md](CONTRIBUTING.md) | Dev setup, test commands, commit/PR conventions, security reporting. |
| 🧪 [TESTING.md](TESTING.md) | Running the suite, naming conventions, test templates, flaky-test policy. |
| 🔒 [SECURITY.md](SECURITY.md) | Command gate, critical-write protection, synthesis gates, sandbox, audit log. |
| 📜 [ATTRIBUTION.md](ATTRIBUTION.md) | Open-source attributions and third-party notices. |
| 📜 [CHANGELOG.md](CHANGELOG.md) | Thematic release history; the full record lives in `git log`. |
| 📄 [LICENSE](LICENSE) | Software license (MIT). |
