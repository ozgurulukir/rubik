# LSP Setup Guide (LSP.md)

> Bu belge, [`LSP.md`](LSP.md) dosyasının Türkçe çevirisidir ve güncelliğini yitirmiş olabilir; çelişki halinde İngilizce sürüm esastır.

## What LSP integration gives you

Rubik connects to any standard Language Server Protocol (LSP) server over stdio
(JSON-RPC with `file://` URIs per RFC 8089) and turns it into a live compiler in
the agent loop. Instead of relying only on Rubik's pure-AST analysis, the agent
gets compiler-grade type and semantic feedback: real-time diagnostics after every
edit, hover type/doc information, and go-to-definition lookups. The integration
is multi-language — one server binary per language — and is managed by
`Rubik::LSP::Manager` (`lib/rubik/lsp/manager.rb`), which spawns, supervises and
stops servers as revertible effects on the runtime context.

## 1. Requirements

- A language server binary for each language you care about, installed and on
  `PATH`. Rubik never installs servers for you; if the binary is missing, that
  language silently falls back to pure-AST analysis.
- No other dependencies: servers are spawned as child processes rooted at your
  project directory and stopped cleanly on context disposal.

## 2. Quick setup

LSP is enabled by default. To customize it, add an `lsp:` block to your project
config (`.rubik/config.yml` or `rubik.yml` in the repo root) or global config
(`~/.rubik/config.yml`):

```yaml
lsp:
  enabled: true            # master switch for the LSP engine
  auto_start: true         # start a server in the background when its file type is touched
  auto_diagnostics: true   # feed compiler/linter errors back to the model right after write_file
  servers:                 # language -> launch command (override any entry)
    ruby: "typeprof --lsp --stdio"
    python: "ruff server"
    go: "gopls"
```

Configuration keys (defaults from `lib/rubik/config/defaults.rb`):

| Key                  | Default  | Meaning                                                      |
| -------------------- | -------- | ------------------------------------------------------------ |
| `lsp.enabled`        | `true`   | Enable the LSP engine (`false` = pure AST only).             |
| `lsp.auto_start`     | `true`   | Auto-start a language server when a matching file is opened. |
| `lsp.auto_diagnostics` | `true` | Push severity-1 errors back to the model after edits.        |
| `lsp.servers.<lang>` | see below | Launch command per language.                                |

Default server commands (`lsp.servers`):

| Language              | Default command                        |
| --------------------- | -------------------------------------- |
| `go`                  | `gopls`                                |
| `rust`                | `rust-analyzer`                        |
| `zig`                 | `zls`                                  |
| `c`, `cpp`            | `clangd`                               |
| `python`              | `ruff server`                          |
| `ruby`                | `typeprof --lsp --stdio`               |
| `typescript`, `javascript` | `typescript-language-server --stdio` |
| `bash`                | `bash-language-server start`           |
| `crystal`             | `crystalline`                          |
| `gleam`               | `gleam lsp`                            |
| `vue`                 | `vue-language-server --stdio`          |

Note: if a `lsp.servers.<lang>` key is absent, the hard-coded fallback in
`Rubik::LSP::Client::SERVERS` is used (differs only for `python`: `pylsp`), and
a third fallback probes well-known alternates (`Runtime::Discovery::
LSP_CANDIDATES`), e.g. Ruby: `solargraph stdio`, `ruby-lsp`, `typeprof`;
Python: `pyright-langserver --stdio`, `pylsp`, `jedi-language-server`.

## 3. Install a language server (per-language hints)

Install commands are generic examples — use your platform's package manager
(scoop, brew, apt, cargo, gem, npm, pip). The server binary must end up on
`PATH`.

- **go**: `go install golang.org/x/tools/gopls@latest`
- **rust**: `rustup component add rust-analyzer`
- **zig**: install `zls` from your package manager or build from source
- **c / cpp**: `clangd` ships with LLVM/clang (e.g. `scoop install llvm`)
- **python**: `pip install ruff` (alternates: `npm install -g pyright`, `pip install python-lsp-server`)
- **ruby**: `gem install typeprof` (alternates: `gem install solargraph` or `gem install ruby-lsp`)
- **typescript / javascript**: `npm install -g typescript-language-server typescript`
- **bash**: `npm install -g bash-language-server`
- **crystal**: `crystalline` — grab a release binary or use your package manager
- **gleam**: bundled with the Gleam toolchain (the server is `gleam lsp`)
- **vue**: `npm install -g @vue/language-server`

## 4. How it works at runtime

**Lazy, on-demand startup.** When a file whose extension maps to a supported
language is touched (`.rb`, `.py`, `.ts`, `.go`, `.rs`, `.zig`, `.c`, `.cr`,
`.gleam`, `.vue`, `.sh`, ...), `Manager#client_for` resolves the configured
command, probes fallbacks if the binary is missing, and (with
`lsp.auto_start: true`) spawns the server and performs the `initialize`
handshake with your project root. Each running client is provided on the
context as `lsp:<lang>` with a registered dispose inverse, so servers stop
cleanly (LIFO) when the context is disposed. A crash circuit breaker stops
restart attempts after 3 consecutive crashes for 5 minutes.

**JIT buffer sync with the in-memory buffer.** Rubik edits files in its virtual
buffer before they are applied to disk. Before any LSP query, the manager calls
`sync_buffer_file_if_needed`, which pushes only *dirty* buffer contents to the
server via `textDocument/didOpen` / `didChange` — diagnostics therefore reflect
your unsaved edits, and stale diagnostics are invalidated on every change. If a
buffer has unapplied changes and a server reports nothing, the tools append a
hint to run `apply_buffer` (some servers index from disk).

**Real-time feedback after edits.** After a successful `write_file` or
`replace_file_content`, the step executor syncs the file to the server and, if
`lsp.auto_diagnostics` is on, waits briefly for `textDocument/publishDiagnostics`
and appends any severity-1 (ERROR) items to the tool result, telling the model
to fix them before proceeding. You can also ask explicitly:

- `lsp_diagnostics` (aliases `diagnostics`, `lint_errors`) — errors/warnings for
  one file (`file_path`) or the whole workspace; syncs the buffer first.
- `lsp_hover` (`hover_info`, `type_info`) — type signature/doc at a 1-based
  `file_path` + `line` + `character` position.
- `lsp_definition` (`goto_definition`) — definition location(s) for a symbol.

**REPL commands.** Inspect and control the integration from the shell:

- `!lsp status` (or `!lsp servers`) — engine state plus per-server status
  (RUNNING / AVAILABLE / NOT FOUND) and diagnostic counts.
- `!lsp on` / `!lsp off` (`--project` or `--global`) — persist `lsp.enabled`;
  `off` also stops all running servers.
- `!lsp diag [file]` (alias: `!diagnostics [file]`) — print live diagnostics.
- `!lsp start <lang>` / `stop [lang]` / `restart [lang]` — manual lifecycle
  control; a failed `start` prints a fix suggestion plus the probed candidates.

## 5. Troubleshooting

- **"Server binary '...' not found in PATH"** — the launch command's first word
  must be an executable on `PATH`. Install the server (section 3) or point
  `lsp.servers.<lang>` at an absolute path, then `!lsp restart <lang>`.
- **Wrong or missing server for a language** — check what was picked with
  `!lsp status`; the failure output lists the fallback candidates that were
  probed. Override with an explicit `lsp.servers.<lang>` entry.
- **Slow startup or noisy servers** — set `lsp.auto_start: false` and start
  servers on demand with `!lsp start <lang>`; a crashing server auto-disables
  itself for 5 minutes via the circuit breaker.
- **Disable per language** — point `lsp.servers.<lang>` at a command that does
  not exist; that language simply stays on pure-AST analysis.
- **Diagnostics do not reflect my edits** — the buffer was probably never
  synced because it is clean on disk; run `apply_buffer` and query again.

## 6. Verification

Behavioral reference tests (run with the repo's test suite):

- `test/unit/test_lsp_manager_and_diagnostics.rb` — config defaults and
  toggling, extension-to-language detection, diagnostics handling, tool output,
  REPL commands, the orchestrator live-diagnostics feedback loop, and stale
  diagnostic invalidation on `did_change`.
- `test/unit/test_lsp_jit_buffer_sync_and_web_adapter.rb` — just-in-time buffer
  sync semantics (only dirty buffers are pushed); `test_lsp_client.rb`,
  `test_lsp_circuit_breaker.rb` and `test_lsp_robustness.rb` cover the protocol
  and failure paths.
