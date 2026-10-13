# ⚙️ Rubik Configuration Guide (CONFIG.md)

This document details the configuration hierarchy of the **Rubik AI Coding Agent**, every available setting (knobs), dynamic LLM providers, model context limits, in-memory buffer policies, and REPL commands.

---


## 🏛️ 1. Configuration Hierarchy and Precedence Order

Rubik merges configuration in a layered, transactional (`YAML::Store`) model (deep merge):

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ 1. Default Core Settings (Default Config)                               │
│    └─► 2. Global User Settings (~/.rubik/config.yml)                    │
│         └─► 3. Project-Level Settings (.rubik/config.yml or rubik.yml)  │
│              └─► 4. REPL Runtime Parameters                             │
└─────────────────────────────────────────────────────────────────────────┘
```

- **Global Configuration:**
  - **Linux / macOS:** `~/.rubik/config.yml`
  - **Windows:** `C:\Users\<Username>\.rubik\config.yml` (`%USERPROFILE%\.rubik\config.yml`)
- **Project Configuration:** `.rubik/config.yml` or `rubik.yml` in the project root (applies only to that project; overrides global settings).



## 📄 Fully Annotated Configuration Template

```yaml
# ==============================================================================
# 🎲 Rubik Configuration File (.rubik/config.yml or ~/.rubik/config.yml)
# ==============================================================================

# ------------------------------------------------------------------------------
# 🌊 0. LLM Communication and Live Token Streaming (Streaming vs. Batch)
# ------------------------------------------------------------------------------
llm:
  # Live token streaming engine:
  #   • true  : Model output flows to the terminal token by token the moment it is produced (0s TTFT).
  #             Can be cut off instantly with Ctrl+C, preventing needless token spend (Default).
  #   • false : Blocking batch mode. Waits until the entire response has been generated, then prints it in one go.
  stream: true

  # Autonomous continuation loop on token-ceiling interruptions (finish_reason: length / max_tokens):
  # instead of stopping when the model's thinking process or a long code generation cuts the
  # output short, it lets the model automatically resume from where it left off.
  auto_continue_on_length: true

  # Safety fuse for auto-continuation (maximum continuation count, preventing an infinite loop):
  max_auto_continues: 3

  # Reasoning budget ratio for Anthropic Claude 3.7 Thinking models (0.0 - 0.8).
  # Wrapped up on 2026-10-05 after a dropped connection: the value is now
  # bridged into the request opts. null = not sent, the adapter falls back to its own default
  # (0.5 in llm/anthropic.rb). When set, the given percentage of the output token budget
  # goes to thinking:
  thinking_budget_ratio: null

  # Thinking intensity for OpenAI reasoning models (o1, o3-mini):
  # 'low' | 'medium' | 'high'. null = not sent. CAUTION: a non-null value also
  # triggers the reasoning_model? detection in openai_compatible — set it only
  # for models that genuinely reason:
  reasoning_effort: null

  # Network timeouts (seconds): open_timeout = TCP connection establishment,
  # stream_timeout = once the stream has started, the ceiling on inter-chunk silence:
  open_timeout: 15
  stream_timeout: 120

  # Capture the model's reasoning content and keep it in context:
  capture_reasoning: true

  # Default maximum output token budget (dynamic smart ceilings are applied per model):
  default_max_output_tokens: 4096

  # Extra HTTP headers sent with every provider request (open map — e.g.
  # HTTP-Referer / X-Title for OpenRouter attribution):
  headers: {}

# 💡 STREAMING VS. BATCH AND THE 50% COST SAVINGS GUIDE:
#   • Streaming Mode (`llm.stream: true`):
#       - Ideal for interactive REPL sessions and pair programming.
#       - The model's chain of thought appears on screen instantly; perceived latency is zero.
#       - Unwanted code generation or a loop is cut off within milliseconds via Ctrl+C.
#   • Batch Mode (`llm.stream: false`):
#       - Suited to background scripts, CI/CD pipelines, and automated analyses.
#       - Dedicated Batch Endpoints (OpenAI Batch API, Anthropic Message Batches):
#         batch endpoints running asynchronously with a 24-hour SLA offer cost savings
#         of up to 50% and much higher rate limit quotas.
#
# ------------------------------------------------------------------------------
# 🖥️ 0-b. Display Layer (Hybrid TUI: Theme, Spinner, Statusline, Markdown)
# ------------------------------------------------------------------------------
# Rubik's terminal display layer was refreshed: the ⏺/⎿ agent flow
# language, a live verb spinner, an above-prompt statusline, live markdown
# rendering, and a colored diff viewer. Every surface is capability-aware: on
# non-TTY pipes, under NO_COLOR=1 or RUBIK_TEST=1, output falls back to classic
# plain text and session logs never contain ANSI codes.
ui:
  # Color mode: auto (default; on when TTY) | always | never
  color: auto
  # Glyph set: unicode (⏺ ⎿ ✻) | ascii (legacy conhost terminal fallback)
  glyphs: unicode
  # Version + model + workspace banner at startup (interactive TTY only)
  banner: true
  # Live verb spinner while waiting on the LLM (Düşünüyor, Kavuruyor, Damıtıyor...)
  spinner: true
  # Custom spinner verbs (if left empty, the built-in Turkish set is used)
  spinner_verbs: []
  # Markdown processing of the assistant response: live (line-by-line, live) | off
  markdown: live
  # Above-prompt context strip (model, context percentage, dirty buffer, sandbox)
  statusline: true
  # Statusline template; placeholders: {project} {branch} {model} {ctx}
  # {dirty} {sandbox} {verbosity}
  statusline_template: "{model} · ctx {ctx} · {dirty} · sandbox {sandbox}"
  # Boxed input area experiment (top frame + left rail; beta, off by default)
  input_box: false
  # Multi-line paste: if the gap between two readline returns is below this
  # window (ms), the lines are joined into a single prompt turn. Manually typed lines
  # stay above this window and are therefore never joined. For guaranteed multi-line
  # input, use the `!paste` command in the REPL (terminate with a period).
  paste_join_window_ms: 120
  # Quiet notice buffer: when true, background subagent or task notifications
  # are not printed straight to the screen; they queue up in the notice_inbox and are
  # flushed in bulk before the next prompt (!config set ui.quiet_notices true).
  quiet_notices: false

# 💡 DISPLAY LAYER TIPS:
#   • `rubik --no-color`  : Fully disables ANSI color/banner/spinner (CI-friendly).
#   • `rubik --color`     : Forces colors even when piped (CLICOLOR_FORCE).
#   • The NO_COLOR=1 environment variable is also supported (https://no-color.org).
#   • All ui.* keys such as `!config set ui.color never -g` can be changed while the
#     REPL is running; the display layer is rebuilt instantly (refresh_ui!).
#   • The spinner thread is torn down via the Runtime Context's LIFO inverse (ctx.on_dispose)
#     — no leaks at session shutdown (AGENTS.md protocol).
#
# ------------------------------------------------------------------------------
# 🌐 1. Dynamic LLM Providers and Custom Endpoints (Providers Registry)
# ------------------------------------------------------------------------------
# You can define as many OpenAI-compatible (OpenRouter, DeepSeek, Ollama, LMStudio, etc.),
# Mistral AI, or Anthropic providers — and their models — here as you like.
providers:
  # A. OpenRouter (hundreds of models, one API)
  openrouter:
    type: openai_compatible
    endpoint: https://openrouter.ai/api/v1/chat/completions
    api_key_env: OPENROUTER_API_KEY
    headers:
      HTTP-Referer: https://github.com/ozgurulukir/rubik
      X-Title: Rubik AI Coding Agent
    models:
      - name: anthropic/claude-3.7-sonnet
        context_limit: 200000
      - name: deepseek/deepseek-r1
        context_limit: 128000
      - name: deepseek/deepseek-chat
        context_limit: 64000
      - name: meta-llama/llama-3.3-70b-instruct
        context_limit: 128000
      - name: qwen/qwen-2.5-coder-32b-instruct
        context_limit: 32768

  # B. DeepSeek (official API)
  deepseek:
    type: openai_compatible
    endpoint: https://api.deepseek.com/chat/completions # (or just https://api.deepseek.com)
    api_key_env: DEEPSEEK_API_KEY
    models:
      - name: deepseek-chat
        context_limit: 64000
      - name: deepseek-reasoner
        context_limit: 64000

  # C. Cline API Gateway
  cline:
    type: openai_compatible
    endpoint: https://api.cline.bot/api/v1/chat/completions # (or just https://api.cline.bot)
    api_key_env: CLINE_API_KEY
    models:
      - name: cline-pass/deepseek-v4-flash
        context_limit: 64000
      - name: deepseek/deepseek-r1
        context_limit: 128000

  # D. Ollama / LMStudio OpenAI Compatibility Server
  ollama:
    type: openai_compatible
    endpoint: http://localhost:8000/v1/chat/completions # (or just http://localhost:8000)
    models:
      - name: Qwen/Qwen2.5-Coder-32B-Instruct
        context_limit: 32768

  # F. Local Ollama (native /api/chat protocol)
  # num_ctx: the context window sent to the Ollama server. If undefined,
  #   the model's registered context_limit is used — otherwise Ollama silently
  #   truncates the head of the prompt to its own default (~2-4k tokens) and the
  #   model "forgets" the earlier conversation. To bound VRAM on small GPUs you
  #   can write a fixed value here.
  ollama_native:
    type: ollama
    endpoint: http://localhost:11434
    num_ctx: 32768
    default_model: qwen2.5-coder:7b

  # E. Mistral AI
  mistral:
    type: openai_compatible
    endpoint: https://api.mistral.ai/v1/chat/completions
    api_key_env: MISTRAL_API_KEY
    models:
      - name: mistral-large
        context_limit: 32000
      - name: mistral-small
        context_limit: 32000

# ------------------------------------------------------------------------------
# 🧠 2. Model and Multi-Role Routing (Multi-Role Router)
# ------------------------------------------------------------------------------
model:
  provider: openrouter          # &apos;openrouter&apos;, &apos;cline&apos;, &apos;deepseek&apos;, &apos;mistral&apos;, &apos;anthropic&apos;, &apos;openai&apos;, &apos;ollama&apos;
  name: deepseek/deepseek-chat  # Model name
  endpoint: https://openrouter.ai/api/v1/chat/completions

models:
  # Default Role (general pair coding, analysis, and chat)
  default:
    provider: openrouter
    name: deepseek/deepseek-chat
    # Optional endpoint override; omitted = the provider's own endpoint:
    endpoint: https://openrouter.ai/api/v1/chat/completions

  # Fast Role (!plan generation or lightweight context queries)
  fast:
    provider: ollama
    name: llama3
    endpoint: http://localhost:11434

  # Advanced Role (complex refactors or long-running !goal autonomous loops)
  advanced:
    provider: openrouter
    name: anthropic/claude-3.7-sonnet
    endpoint: https://openrouter.ai/api/v1/chat/completions

# Router Mode: 'auto' (picks automatically based on task type) or 'manual' (the default model is used)
# sticky: when true, free-text turns stay pinned to the settled
#   provider/model for the whole conversation; keywords like "quick check" do not
#   switch the model mid-conversation. Switching happens only via the !model command
#   or a new conversation. false → reclassification on every turn (legacy behavior).
router:
  mode: auto
  sticky: true

# ------------------------------------------------------------------------------
# 🤖 3. Agentic Orchestration and Step Budget (Agentic Step Budget)
# ------------------------------------------------------------------------------
agent:
  # Maximum step count for standard interactive prompts (Default: 40)
  max_steps: 40

  # Step count for the !goal autonomous test-passing loop (Default: 100)
  goal_max_steps: 100

  # Step count for !plan generation (Default: 15)
  plan_max_steps: 15

  # Budget warning threshold (0.75 = sends the model an XML convergence warning at 75% of the budget)
  warn_at_ratio: 0.75

  # Ask to auto-continue in the REPL when the budget is exceeded
  ask_continue_on_limit: true

  # Unattended auto-extensions in !goal mode before prompting the operator (Default: 0; N = auto-extend by +20 steps N times)
  goal_auto_continue_limit: 0

  # !goal early-termination guard: while a live subagent exists, the loop does not close
  # even if the maestro writes a text-only result or calls finish — subagents are awaited
  # automatically until done and their notifications injected. Upper bound of this wait
  # per occurrence (seconds; 0 = non-blocking, instant re-prompt; Default: 300)
  goal_wait_timeout: 300

# ------------------------------------------------------------------------------
# Central Storage (rubik://storage virtual FS-DB)
# ------------------------------------------------------------------------------
storage:
  # Whether the storage database and absorb are on (storage tool + URI routes)
  enabled: true

  # Storage root (~ is expanded). Under projects: <root>/<project>/store/
  root: ~/.rubik/rubikstorage

  # Project slug override; if null, derived from the worktree root directory name
  project: null

  # true: new session files + subagent transcripts are absorbed into the storage
  # root (the worktree stays clean); legacy .rubik/ locations are still read.
  # Note: if the key is ABSENT from the configuration, legacy behavior is preserved.
  absorb_artifacts: true

# ------------------------------------------------------------------------------
# 🛠️ 4. Tool Input / Output and Smart Context Truncation (Tool I/O & Truncation)
# ------------------------------------------------------------------------------
tools:
  # Maximum character limit for a single tool output (prevents context blowups)
  max_output_chars: 12000

  # Maximum line limit
  max_output_lines: 300

  # Truncation strategy: &apos;head_tail&apos; (keeps head and tail lines), &apos;head_only&apos;, &apos;tail_only&apos;
  truncation_strategy: head_tail

  # Tool execution timeout (seconds)
  timeout_seconds: 30

  # Circuit breaker: on repeated tool failures, after `threshold` consecutive
  # errors the breaker opens for `cooldown_seconds`.
  # (V29 design decision: off by default — network_retry_count and
  # subagents.error_wait_timeout already manage the failure paths)
  circuit_breaker:
    enabled: false
    threshold: 5
    cooldown_seconds: 60

  # Native fast paths: speeds up grep_search and context scanning using
  # the rg (ripgrep) and git binaries on the system.
  #   • auto : fast path when rg/git are available, pure Ruby otherwise (Default)
  #   • on   : force the fast path (silently falls back to pure Ruby if the binary is missing)
  #   • off  : force pure Ruby paths (deterministic, no spawning)
  # ENV overrides: RUBIK_NATIVE=off | on | auto, RUBIK_RG_PATH=<full path>
  native: auto

  # Surgical, targeted code editing (`replace_file_content`) and an Elm-compiler-style
  # error formatter (`DiagnosticReporter` & `FuzzyMatcher`):
  # lets frontier-level LLMs reach the highest first-attempt pass rate. When the block
  # to be replaced cannot be found, the nearest lines via diff-lcs and DidYouMean
  # suggestions are offered automatically.

# ------------------------------------------------------------------------------
# ⚡ 5. Language Server Protocol (LSP) and Live Compiler Diagnostics
# ------------------------------------------------------------------------------
lsp:
  # Enable the LSP engine (true: compiler-grade types/diagnostics, false: pure AST)
  enabled: true

  # Auto-start the language server in the background when a relevant source file is opened
  auto_start: true

  # Feed compiler/linter errors back to the model instantly when write_file is called
  auto_diagnostics: true

  # Multi-language LSP server binary mappings
  servers:
    rust: "rust-analyzer"
    typescript: "typescript-language-server --stdio"
    javascript: "typescript-language-server --stdio"
    python: "ruff server"
    ruby: "typeprof --lsp --stdio"
    bash: "bash-language-server start"
    crystal: "crystalline"
    gleam: "gleam lsp"
    go: "gopls"
    zig: "zls"
    c: "clangd"
    cpp: "clangd"
    vue: "vue-language-server --stdio"

# ------------------------------------------------------------------------------
# 🔌 5.1 Model Context Protocol (MCP) and Spatiotemporal Tool Integration
# ------------------------------------------------------------------------------
mcp:
  # Enable the MCP engine (true: connects external MCP servers)
  enabled: true

  # Connect handshake timeout (seconds; initialize + tools/list). Servers with
  # slow spawns hold up startup by this long; the per-server "timeout"
  # overrides this value. An invalid value (not a number / <= 0) warns and falls
  # through to the next source — boot never blows up over a bad knob.
  timeout: 10

  # tools/call round-trip timeout (seconds). ping is fixed at 5s (technical probe).
  call_timeout: 30

  # Load MCP servers in the background (nil = environment-sensitive: async in production,
  # synchronous under RUBIK_TEST=1; true/false forces). Background loading never blocks
  # the first prompt; completion is visible via `!dmesg -s mcp` and a REPL notice. While
  # boot is in flight, !mcp disable/remove overrides the pending load decision.
  async_load: null

  # Registered MCP server definitions (stdio transport); the per-server "timeout"
  # overrides the global mcp.timeout (connect handshake only):
  servers:
    # filesystem:
    #   command: "npx"
    #   args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    #   enabled: true
    #   timeout: 30
    # fetch:
    #   command: "uvx"
    #   args: ["mcp-server-fetch"]
    #   enabled: true
    # NOTE: prefer file-based server commands over long inline interpreter
    # payloads (`ruby -e '<many lines>'`): on Windows, long multiline `-e`
    # children have been observed to start silently unresponsive (issue #54).
    # Write the server script to a file and point `args` at its path.

# ------------------------------------------------------------------------------
# 📝 6. In-Memory File Buffer and Safety
# ------------------------------------------------------------------------------
buffer:
  # Auto-apply-to-disk policy:
  #   • &apos;manual&apos;    : Changes are written to disk only via the &apos;!apply&apos; command (Default & Safest)
  #   • &apos;on_test&apos;   : Applies the buffer to disk immediately before the &apos;!test&apos; command runs
  #   • &apos;on_finish&apos; : Applies the buffer to disk when the task completes successfully
  #   • &apos;always&apos;    : Saves to disk instantly the moment the model writes to the buffer
  auto_apply: manual

  # Allow the model to call the apply_buffer tool on its own initiative
  model_can_apply: true

  # Show the dirty buffer file count in the REPL prompt (e.g.: rubik (app) [DIRTY: 2 ✎] >)
  prompt_indicator: true

  # Warn the user when exiting the REPL while a dirty buffer exists
  exit_guard: true

  # Show a reminder message if an unapplied buffer persists for a number of turns
  reminder_interval: 3

  # Buffer application policy when an external modification is detected on disk:
  #   • 'skip'      : Skips the externally modified file, preventing data loss (Default & Safest)
  #   • 'overwrite' : Ignores the external change and force-writes the buffer contents to disk
  on_external_modification: skip

# ------------------------------------------------------------------------------
# 🛡️ 7. Security, Safe Execution, and Pluggable Sandbox Isolation
# ------------------------------------------------------------------------------
sandbox:
  enabled: false                # true: the sandbox cage is active, false: direct safe host execution
  driver: bwrap                 # 'bwrap' (Linux default), 'docker', 'podman', or a plug-in engine ('firejail')
  prompt_on_startup: true       # Gentle suggestion shown at startup when Linux & bwrap are detected
  image: rubik-sandbox:latest   # Default image for container engines
  timeout_seconds: 15
  memory_limit_mb: 512
  cpus: "1.0"
  allow_network: false
  shell: auto                   # 'auto', 'bash', 'pwsh', 'cmd', or 'sh'
  isolation_note: true          # false: silence the per-run_command "🔍 Isolation/Execution" note

security:
  # Audit log where blocked file writes, root additions, and dangerous command attempts are recorded.
  # An explicit `null`/empty value = auditing OFF (Guard#for_config); it can be changed live
  # during the session with !config set (Plan: guard-policy-unification).
  audit_log_path: ~/.rubik/audit.log

  # Operator-managed allowlist: token-prefix entries (e.g. "node .gitnexus/run.cjs")
  # that Guard admits beyond the 172-rule classifier:
  command_allowlist: []

  # `bash --version`-style version/help probes bypass the blocklist:
  allow_safe_probes: true

# `sandbox.shell` — which shell run_command commands run under.
# `auto` (default) selects per command through a syntax gate:
#   - cmd.exe builtins with no binary (dir, where, cls, ...) [Windows]      -> cmd
#   - bash-mandatory syntax (<(...), >(...), /dev/null, heredoc)  -> bash
#   - PowerShell fingerprints ($env:, Verb-Noun cmdlets: Select-String, Get-*, ConvertTo-*, ...) -> pwsh
#   - $-variables/command substitution ($(...), `, $VAR) and POSIX single quotes ('...') [Windows] -> bash
#   - plain commands (&&, ||, |, binary invocations)                      -> Windows: cmd, elsewhere: bash (sh)
# The choice is labeled in the command result: `[EXIT 1] (bash) ...`. The system prompt
# announces the shell behavior to the model up front via the <environment> line.
# `powershell` (5.1) is deliberately outside the set: it does not support `&&` chains
# and propagates exit codes unreliably; even when explicitly selected it falls back to `auto`.

# Maximum step count for the self-repair loop
repair:
  max_attempts: 3

# Network access permission (global default)
network:
  allow: false

### 🛡️ Safe Execution vs Sandbox Isolation Matrix

1. **Safe Execution (Always-On Universal Policy — Tree-Sitter AST + Fail-Safe Regex):**
   - **Tree-Sitter AST Primary Security Shield:**
     Bash (`tree-sitter-bash`) and PowerShell (`tree-sitter-powershell`) commands are scanned at the full abstract syntax tree (AST) level before execution.
   - **172 CLI YAML Rule Database:**
     With the rules defined for 172 popular CLI tools (`lib/rubik/security/classifier/commands/*.yaml`), subcommands, arguments, and flags are sorted into semantic categories (`read`, `write`, `execute`, `network`, `destructive`, `elevated`, etc.).
   - **Path Normalization & Root Directory Protection:**
     File and directory arguments in AST nodes are normalized so dangerous system roots (`/`, `C:\`, `~`, `/etc`, `/dev`, etc.) and `../` path traversal escapes are caught.
   - **Pipeline Poisoning Shield:**
     Subcommands hidden inside `|`, `&&`, `;` pipelines and command chains are scanned recursively.
   - **Fail-Safe Regex Fallback:**
     When the tree-sitter grammar is not ready or AST parsing fails, the multi-layered hardened regex engine (`DANGEROUS_COMMAND_PATTERNS`) steps in and blocks dangerous commands (`rm -rf /`, `mkfs`, `dd if=`, fork bombs, etc.).
   - **Security Audit Log (`security.audit_log_path`):**
     Every blocked write, root addition, and command attempt is recorded to the audit log in JSON Lines format with a timestamp and the reason for the block.

2. **Sandbox (Optional Hardware/Kernel-Level Isolation Cage):**
   Kicks in when `sandbox.enabled: true` is set or `!sandbox on` is issued.

| Mode / Driver | Isolation Strength | Network Isolation | Filesystem Boundary | Supported Platforms |
| :--- | :---: | :---: | :---: | :--- |
| **Direct Host (`sandbox.enabled: false`)** | **Direct Safe Execution (Direct Safe Host)** | No isolation (host network; no fake proxy injected) | Only `chdir` root directory checks | All platforms (zero overhead) |
| **`bwrap` (Bubblewrap)** | **Strong (Strong OS Namespaces)** | Kernel `--unshare-net` | Host `/` Read-Only, workspace RW | Linux only (OS-Gated) |
| **`docker`** | **Strong (Strong OCI Container)** | OCI network namespace (`--network none`) | Mount boundaries, cgroups | Linux / macOS / Windows (Daemon) |
| **`podman`** | **Strong (Strong Rootless OCI)** | Rootless network namespace | Mount boundaries, cgroups | Linux / macOS / Windows (CLI) |
| **`firejail` (Plugin)** | **Strong** | Firejail `--net=none` | Whitelist/Blacklist profile | Linux (Pluggable Add-On) |

> ℹ️ **Honest Network Policy:** In direct host execution (`sandbox.enabled: false`), Rubik does not inject deceptive `127.0.0.1:9999` proxy environment variables. Real hardware/kernel-level network isolation is provided only while the sandbox is active (`--unshare-net` with `bwrap`, `--network none` with `docker`/`podman`).


# ------------------------------------------------------------------------------
# 📁 8. Context Scanning and Smart Compaction (Context Engine & Compactor)
# ------------------------------------------------------------------------------
context:
  include: []
  exclude:
    - ".git"
    - "node_modules"
    - "vendor/bundle"
    - "target"
    - ".rubik"

  # Fallback context window for subagents (tokens): used when the routed model
  # entry has no context_limit (subagent/instance.rb, supervisor.rb):
  max_tokens: 32768

  # Context compaction strategy:
  #   • &apos;hybrid&apos;             : truncates stale tool outputs + summarizes the oldest dialogues (Default)
  #   • &apos;prune_tool_results&apos; : prunes only stale tool outputs
  #   • &apos;sliding_window&apos;     : drops turns outside a given window
  #   • &apos;off&apos;                : disables automatic compaction
  compaction_strategy: hybrid
  max_tokens_ratio: 0.85
  tool_result_prune_chars: 1500
  preserve_first_n: 2
  preserve_last_n: 6
  safety_margin_tokens: 1024
  # Emergency truncation strategy: the strategy of the blind truncation layer of the
  # EmergencyCompactor, engaged when structural compaction/overflow recovery falls short.
  #   • &apos;head_tail&apos; : message head + tail are kept, the middle is dropped (Default)
  #   • &apos;head_only&apos; : only the message head is kept
  #   • &apos;tail_only&apos; : only the message tail is kept
  # Invalid values silently fall back to &apos;head_tail&apos;; it affects only the emergency
  # truncation layer, NOT the structural layer governed by compaction_strategy.
  emergency_truncate_strategy: head_tail
  auto_recover_on_overflow: true
  # Failed/cancelled turns are also written into the conversation window
  # and the session log with the [Turn failed/cancelled/incomplete] stamp; that way
  # the model remembers what was attempted on the next turn. Can be turned off with false.
  log_failed_turns: true

  # Tool chronicle (Plan 85): the most recent tool calls stay summarized in the
  # conversation window so the model remembers its own actions:
  tool_chronicle_in_history: true
  tool_chronicle_max_entries: 15

  # Consecutive tool rows within one turn merge into a single chronicle entry
  # (Plan 85 D-7), capped by the entry limit below:
  merge_turn_tool_history: true
  merge_turn_tool_max_entries: 20

# ------------------------------------------------------------------------------
# 📺 9. User Interface and Verbosity (Detail Level)
# ------------------------------------------------------------------------------
ui:
  # Live agent monitoring and step output detail level:
  #   • &apos;quiet&apos;   (0) : zero intermediate noise, only the final answer and errors
  #   • &apos;normal&apos;  (1) : clean, aesthetic step & tool summary output (Default)
  #   • &apos;verbose&apos; (2) : detailed JSON arguments, a first-5-lines output preview, and [Thought]
  #   • &apos;debug&apos;   (3) : full raw tool I/O, millisecond timings, and diagnostics
  verbosity: normal

# ------------------------------------------------------------------------------
# 🏢 10. Multiple Workspaces, External Directories, and Permissions (Workspace Roots)
# ------------------------------------------------------------------------------
workspace:
  # Additional permitted root directories (monorepo, proto, shared-lib)
  additional_roots: []
  # External directories the model may read via sandbox commands (e.g.: /tmp, C:/temp)
  allowed_external_dirs: []
  # Should writes to the additional root directories be allowed? (false: read-only, true: read-write)
  allow_external_writes: false
  # Should the additional root directories be included in the AST semantic graph and context index?
  auto_index_additional: true

plugins:
  # Auto-load drop-in plugins from the project and global directories (.rubik/plugins, ~/.rubik/plugins).
  autoload_dropin: true
  # Additional plugin file paths to load at startup (absolute or root-relative):
  load: []
  # Plugin name aliases (alias => real plugin name):
  aliases: {}

skills:
  # Enable the Agent Skills infrastructure (agentskills.io):
  enabled: true
  # Additional discovery directories (absolute or root-relative; .rubik/skills and ~/.rubik/skills
  # are always scanned):
  paths: []
  # Skill names to exclude from discovery:
  disabled: []
  # Character cap for the skill body (SKILL.md body) before it is loaded into context —
  # kept small so it stays under tools.max_output_chars:
  max_body_chars: 8000

# Structured goal ledger (SKILL.state family, 2026-10-10) — the !goal loop's
# ΔΣ state ledger (objective, tasks, findings, decisions, open questions,
# environment notes). The update_goal_ledger tool applies validated JSON
# patches (RFC 6902 subset, rev-guarded); the current Σ survives compaction
# (pinned + reinjected row) and every accepted revision appends a storage
# row under the `goal-ledger` ref. DEFAULT ON (opt-out: enabled: false —
# then the tool, the prompt teaching and the storage rows all go silent):
goal:
  ledger:
    enabled: true
    # Consecutive-rejected update_goal_ledger call budget before the tool
    # answers honestly that the ledger is unchanged (the goal work itself
    # is never blocked):
    # Re-verification (2026-10-10): verify specs on tasks and environment
    # notes are re-checked against the workspace at step boundaries and
    # before reinjection; failures flip the task to stale (internal rev
    # bump + silent :ledger_drift). DEFAULT ON; inert while enabled=false:
    verify: true
    # Observation projection (plan D, 2026-10-10): at compaction time the
    # banked tool results (older than the observe window, before the newest
    # accepted update_goal_ledger call) get a per-row
    # <absorbed_into_ledger rev=... tool=.../> tombstone — rows are NEVER
    # dropped (tool-call pairing survives) and the last observe_window
    # goal-loop turns stay raw. Inert outside a running !goal or while
    # enabled is false (one honest dmesg warn):
    observe_projection: true
    observe_window: 5
    max_patch_retries: 2

project:
  # Test/build command (e.g. "bundle exec rake test"); nil = the adapter auto-detects:
  test_command: null

# ------------------------------------------------------------------------------
# 🧮 10-b. AST Warm-up and Test Runners (AST Warm-up & Test Runners)
# ------------------------------------------------------------------------------
ast:
  # At REPL startup the AST semantic graph is warmed up on a background fiber
  # (repl/lifecycle.rb warm_up!). null = environment-sensitive default (true in
  # production, false under RUBIK_TEST=1); you can force it with true/false:
  async_warm: null

test:
  # Wall-clock ceiling for the run_tests adapter when the caller provides no
  # duration (seconds, adapter/base.rb):
  timeout: 30
  # Per-language test runner override; key = language key
  # (e.g. ruby, python, javascript), value = full command. Empty = Discovery
  # auto-detects (tools/builtins/exec.rb synthesize_adapter):
  runners: {}

# ------------------------------------------------------------------------------
# 🔧 10-c. Adapter Overrides (run_tests backends)
# ------------------------------------------------------------------------------
adapter:
  # Open map: key = adapter name, value = override hash (command, timeout).
  # Empty = the Discovery auto-detection defaults (adapter/base.rb):
  {}

# ------------------------------------------------------------------------------
# 👥 11. Subagent Orchestration and Process Tree
# ------------------------------------------------------------------------------
subagents:
  # Maximum number of subagents that can run concurrently (concurrency guard):
  max_concurrency: 10
  # Maximum nesting depth limit (recursion depth limit):
  max_depth: 2
  # Default maximum step budget per subagent:
  default_max_steps: 88
  # Auto-write the buffer to disk when a subagent completes successfully or before tests:
  auto_apply_buffer: true
  # Automatically wake the idle agent (agent-0) on subagent completion/pause/
  # error/message/question events (reactive wakeup); false = notifications
  # are only seen on the next user turn (legacy behavior):
  reactive_wakeup: true
  # Blocking wait duration for a question a subagent asks the maestro via ask_question
  # (seconds). If no answer arrives via send_message within this window, the subagent
  # resumes from the step it stopped at with "use your best judgment" guidance:
  question_timeout: 300
  # Orderly reaping: a finished (completed/failed) subagent is automatically reaped at the
  # end of this grace period (seconds) — the in-memory history is released, while the
  # durable transcript and storage index persist and the state remains queryable
  # from the tombstone. 0 = auto-reaping off (manual, only via the 'reap' action):
  reap_finished_after: 300
  # Cap on the number of queryable tombstones — once exceeded, the oldest
  # tombstone is evicted FIFO:
  tombstone_limit: 25
  # Foreground task ownership (issue #125): the REPL publishes a cancellation token
  # per turn; subagents spawned during the turn (and their own nested descendants)
  # are owned by it, subagents spawned with detach: true are not. Ctrl+C cancels
  # the token and requests owned workers to stop. This grace period (seconds)
  # bounds waiting for cleanup; pending inverses keep draining on their existing
  # worker and are reported explicitly when the deadline is reached.
  cancel_timeout: 2
  # Retained completed-run results (issue #122): each settled run's result is kept
  # in memory under its execution-specific `rubik://subagent/<storage-id>/result/<run>`
  # reference so the full result stays retrievable (paginated via manage_subagents
  # action 'result') without a redeploy. Redeploy runs never overwrite earlier ones;
  # reads after the TTL return an explicit "expired" response.
  result_archive:
    # Session-scoped retention lifetime (seconds) per retained run:
    ttl_seconds: 3600
    # Newest retained runs kept per execution; older runs are evicted:
    max_runs_per_instance: 8
    # Default characters per bounded result page (cursor pagination; hard cap 40000):
    page_chars: 4000
  # Append-only execution journal (issue #124): every lifecycle, tool-call,
  # tool-result and compaction event is appended to `journal.jsonl` beside the
  # transcript before history pruning, and records are never rewritten — so
  # multiple context compactions cannot erase earlier evidence. Retention is
  # bounded per execution file independently of the model context: once this cap
  # is reached a final `journal_truncated` record marks the boundary and further
  # events are not persisted (a cancellation outcome is recorded when its
  # handler can still write one). Payloads are redacted before persistence
  # (Redactor.mask_value) and previewed with explicit output_chars /
  # output_truncated metadata. An interrupted final write is skipped by
  # Journal.read, so earlier valid records stay readable.
  journal:
    # Maximum bytes per execution journal file (default 2 MiB):
    max_bytes: 2097152
  # Maestro gate (user decision 2026-10-01): the maestro is a pure orchestrator in EVERY
  # mode — on the root agent, write_file/replace_file_content/run_command/run_tests and
  # manage_task ('start' only) are REJECTED before execution, and the error result
  # redirects to a subagent. false = the doctrine stays prompt-level only, the runtime
  # gate is off (operator-only: the agent cannot open it by itself, only via !config):
  maestro_gate: true
  # Concurrent provider request gate (ConcurrencyGate) — subagent swarms open at most
  # this many parallel model requests at a time:
  provider_concurrency: 2
  # Grant wait duration on a budget pause (WAITING_BUDGET) (s) — if no extend arrives
  # within this window, the subagent finalizes as budget-exhausted:
  budget_wait_timeout: 180
  # Retry count and exponential backoff base (s) on provider network errors;
  # if the retries run out, the error surfaces:
  network_retry_count: 3
  network_backoff_base: 0.5
  # Automatic wait duration for an error-paused subagent (s) —
  # if no resume arrives within this window, it finalizes as failed:
  error_wait_timeout: 300
  # On a network error, put the subagent into an error pause (true); false = drop it outright:
  auto_pause_on_network_error: true
  # Vakanuvis background chronicler (plan 2026-10-04 K1-K9 + v2 2026-10-06) —
  # the subagents.vakanuvis.* family is operator-only (inherits the subagents.*
  # rule above). Content boundary (issue #100 follow-up): notes (annal.*) are
  # the chronicler's evidence layer (annals, recall-gap receipts, scout
  # reports); memory cards are the durable conclusions recalled by default.
  # Hygiene: same topic, same session = one note — update it or retire it
  # with forget (superseded rows keep a trace):
  #   enabled     : whether Plane 1 (deterministic annal/memory/wiki harness) is set up
  #   distiller   : Plane 2 — the birth of an LLM-powered distiller subagent (its token
  #                 ceiling is bound by flush_events x max_steps); in v2 the batch birth
  #                 happens only if durable content (card/page/note row) changed —
  #                 a pure turn flow does not fire the distiller
  #   max_steps   : step budget per distiller
  #   flush_events: flush threshold (sweep + home recompute + distiller birth if dirty)
  #                 once this many events accumulate
  #   model       : distiller model (nil = root provider)
  #   retention   : forget policy — supersede (set status+mark, leaves a trace)
  #                 | purge (hard-deletes the row)
  #   root_turns  : should REPL root-turns also be written to the annal (root-turn plan
  #                 2026-10-04; false = the :turn_finished subscription is never set up)
  vakanuvis:
    enabled: true
    distiller: true
    max_steps: 8
    flush_events: 10
    model: null
    retention: supersede
    root_turns: true
  # Context pruner (repl/pruner, 2026-10-09) — semi-deterministic ROOT
  # conversation-window cleanup (LLM proposes a keep/drop/summarize plan;
  # the harness validates it deterministically and applies it at the next
  # turn boundary). DEFAULT ON (2026-10-10; opt-out: enabled: false —
  # kill-switch); the subagents.pruner.* family inherits the operator-only
  # subagents.* rule. The deterministic compaction stack stays the safety
  # net and subagent channels are never managed here:
  #   enabled          : bind the pruner harness (reveals the prune_context
  #                      tool and the !prune command)
  #   trigger_ratio    : auto-fire once the post-turn window estimate reaches
  #                      this share of the effective input ceiling (earlier
  #                      than the blind 0.85 trim so semantic compression
  #                      beats drop-oldest)
  #   target_ratio     : a staged plan applies only if the pruned result
  #                      fits this share of the ceiling
  #   max_steps        : pruner subagent step budget
  #   model            : pruner model (nil = root provider)
  #   min_turns_between: auto-trigger rate limit (turns)
  pruner:
    enabled: true
    trigger_ratio: 0.6
    target_ratio: 0.35
    max_steps: 16
    model: null
    min_turns_between: 5
```

---

## 📚 Related Documentation

- 🌌 **Spatiotemporal Composability Protocol:** [`AGENTS.md`](AGENTS.md)
- 🏗️ **27 Core Domains & Architecture Schema:** [`ARCHITECTURE.md`](ARCHITECTURE.md)
- 🧰 **Catalog of 33 Built-in Agent Tools:** [`TOOLS.md`](TOOLS.md)
- 🧬 **LLM Autonomous Self-Evolution Guide:** [`SELF_EVOLUTION.md`](SELF_EVOLUTION.md)
- 🕹️ **Comprehensive REPL Command Guide:** [`COMMANDS.md`](COMMANDS.md)
