# Security Practices

This document describes Rubik's security architecture as implemented in code: the command
gate, critical-write protection, synthesis gates, the sandbox, workspace containment, and
the audit log.

## Threat Model

Rubik is an agent harness: an LLM writes files and runs shell commands on the user's
machine. The security layer is the boundary between model intent and host effects — model
output is untrusted input at every execution seam. Every shell command, file write, and
piece of dynamically synthesized code passes an explicit verification gate before it
reaches the host. The gates fail closed: when a verdict cannot be produced (unknown
binary, unresolvable path, classifier error), the action is blocked, not permitted.

## Command Gate

Entry point: `Guard#verify_command_safety!` in `lib/rubik/security/guard.rb`, backed by the
classifier in `lib/rubik/security/classifier/`.

1. **AST classification.** Commands are parsed into a full syntax tree (bash and PowerShell
   parsers) and matched against per-tool rule files — 172 YAML rule definitions under
   `lib/rubik/security/classifier/commands/` — covering subcommands, flags, delegation
   (`bash -c`, `sudo`, `xargs`), pipelines, and redirects. Verdicts: `readonly` /
   `local_effects` / `external_effects` (allowed), `dangerous` and `unknown` (blocked).
2. **Un-bypassable blocklist.** `DANGEROUS_COMMAND_PATTERNS` in
   `lib/rubik/security/guard.rb` runs as a fallback regex on every command — including
   allowlisted and safe-probe commands. It blocks `rm -rf /`, `mkfs`, `dd ... of=/dev/`,
   fork bombs, `shutdown`/`reboot`, destructive Windows cmdlets and `format`, and the
   pipe-to-interpreter RCE shape (`curl|wget ... | sh`). Allowlisting cannot bypass it.
3. **Fail-closed unknown handling.** A binary absent from the rule database classifies as
   `unknown` and is blocked. The block message points at the
   operator valve. The only sanctioned `allow_unknown: true` call site is the internal
   synthesis pre-check (see Synthesis Gates).
4. **Operator allowlist.** `security.command_allowlist` holds token-prefix entries, e.g.
   `node` (broad) or `node .gitnexus/run.cjs` (narrow — preferred). An entry rescues a
   blocked command only if it covers EVERY segment recursively — pipeline inners, wrapper
   inners, and safe sibling segments included. The dangerous builtins `source` and `.` are
   never rescuable. Allowlist evaluation itself fails closed on error, and the
   catastrophic fallback regex still runs afterwards.
5. **Safe probes.** With `security.allow_safe_probes: true` (default), a single command
   whose arguments are exclusively `--version`, `-v`, `--help`, or `-h` is exempted — the
   fallback regex still runs. Unknown binaries get no probe exemption: their `--version`
   still executes an unvetted binary; the allowlist is the valve.

If the classifier itself crashes, the shell gate fails closed: the command is blocked with a structured
`classifier_error` reason (the audit log records the crash and the decision), the catastrophic fallback
regex gets first refusal so destructive shapes keep their precise `dangerous_pattern` reason, and the
operator allowlist — restricted to an exact single-command prefix — is the only valve. The
`allow_unknown: true` synthesis seam keeps flowing into its own deny layers (regex deny patterns + RubyVM
AST walk). An ambiguous parse (tree-sitter syntax error) is treated the same way with `parse_ambiguous`
as the block reason; there the allowlist valve applies with the full per-segment check.

## Critical-Write Protection

`Guard#verify_path_write!` in `lib/rubik/security/guard.rb`:

- **Critical patterns.** `DEFAULT_CRITICAL_PATTERNS`: `.git/**`, `.env*`, `secrets.*`,
  `*.pem`, `*.key`, `id_rsa*` — matched against the raw path, the expanded path, and the
  pwd-relative form. Operators can add patterns.
- **Symlink resolution before the block.** After the lexical checks, the path is resolved
  via `Rubik::Platform.resolved_path(path, strict: true)`. A symlink planted inside the
  workspace (`foo -> .git/config`) is caught at the resolved target; dangling symlinks and
  resolution failures (symlink loop, permission wall) block the write fail-closed.
- **Atomic writes vs multi-file transactions.** Individual disk writes go through `atomic_write`
  (`lib/rubik/platform/filesystem.rb`): write to a temp file, `fsync`, then `rename` —
  never unlink-first — so a partially written file is never observable and the
  rename-time TOCTOU window is closed. Transient Windows rename locks are retried.
  However, multi-file buffer application (`Buffer::Manager#apply!`) is not an all-or-nothing
  transaction across files. If a write fails midway (e.g. disk full, permission error, or
  containment block), previously written files remain on disk while failed and pending files
  stay dirty in memory with a structured partial progress report (`applied`, `failed`, `pending`,
  `conflicts`).
- **Workspace root safety.** `Guard#verify_root_safety!` refuses dangerous system roots
  (`/`, `/etc`, `/home`, drive roots, the home directory) as workspace roots.

## Synthesis Gates

Synthesized tool/command code (`lib/rubik/tools/builtins/synthesis.rb`) is refused before
it is ever `eval`'d by `Guard#verify_synthesis_safety!` in `lib/rubik/security/guard.rb`:

1. **Shell-classifier pre-check** with `allow_unknown: true` — the single sanctioned seam:
   Ruby source legitimately classifies `unknown` through the shell classifier, but
   dangerous shell shapes still block and the catastrophic regex still runs.
2. **Regex deny patterns** (`DANGEROUS_SYNTHESIS_PATTERNS`): the `send` family and
   method-object reflection, `eval`/`instance_eval`/`binding.eval`, `const_get`/
   `const_set`, `system`/`exec`/`spawn`/`fork`/`syscall`, `IO.popen`, `Open3.*`,
   `Process.*`, `Kernel.*`, unmanaged threads, backticks, and `%x`.
3. **AST walk** (`RubyVM::AbstractSyntaxTree`):
   - Forbidden node types: `xstr`, `dxstr`, `defn`, `defs`, `class`, `sclass`, `alias`,
     `undef`, `gvar`, `gasgn`.
   - Forbidden calls (any form): the eval family, `system`/`exec`/`spawn`/`fork`,
     `popen`/`Open3` capture set, the `send` family, file destructors, `load`/`autoload`.
   - Forbidden **bare** calls only: `require`, `require_relative`, `load`, `autoload` —
     the receiver form `ctx.require('database')` (the coeffect accessor every synthesized
     tool depends on) stays allowed by design.
   - Forbidden receiver constants: `IO`, `File`, `Dir`, `FileUtils`, `Process`, `Kernel`,
     `Open3`, `RubyVM`, `Object`, `Class`, `Module`, `BasicObject`, `Thread`, `ENV`,
     `ObjectSpace`, `STDIN`/`STDOUT`/`STDERR`/`ARGF`, `Signal`.
   - Network/serialization constants forbidden on **any** reference, not just as a call
     receiver: `Socket`, `IPSocket`, `TCPSocket`, `TCPServer`, `UDPSocket`, `UNIXSocket`,
     `UNIXServer`, `Net`, `Marshal`. Top-level scoping (`::TCPSocket`) and aliasing
     (`X = TCPSocket; X.new`) are both covered.

Every refusal raises `BlockedWriteError` before evaluation; code with syntax errors is
handed to the normal `SyntaxError` path instead of being misclassified as an attack.
An optional pre-flight execution runs the handler in an isolated child process
(`lib/rubik/tools/preflight_runner.rb`) before registration.

## Sandbox

The command gate is policy; the sandbox (`lib/rubik/sandbox/`) is optional kernel-level
isolation. It is **disabled by default** (`sandbox.enabled: false`): commands run as
direct safe host execution with the command gate active and a `chdir` root check, and no
network isolation — Rubik does not inject misleading proxy environment variables in this
mode. Real network/filesystem isolation requires enabling the sandbox: Bubblewrap
(`--unshare-net`, host `/` read-only, workspace read-write) or Docker/Podman
(`--network none`, mount and cgroup limits). A `process` driver provides the direct-host
mode; additional drivers can be registered as plugins.

| Key | Default | Meaning |
| :--- | :--- | :--- |
| `sandbox.enabled` | `false` | Enable the isolation cage (or `!sandbox on`) |
| `sandbox.driver` | `bwrap` | `bwrap`, `docker`, `podman`, `process`, or plugin driver |
| `sandbox.image` | `rubik-sandbox:latest` | Container image for container drivers |
| `sandbox.timeout_seconds` | `15` | Per-command execution timeout |
| `sandbox.memory_limit_mb` | `512` | Memory limit |
| `sandbox.cpus` | `"1.0"` | CPU limit |
| `sandbox.allow_network` | `false` | Network access inside the cage |
| `sandbox.shell` | `auto` | Shell selection per command (`auto`, `bash`, `pwsh`, `cmd`, `sh`) |
| `network.allow` | `false` | Legacy alias mirrored onto `sandbox.allow_network` by config wiring |

## Workspace Containment

All tool file access goes through `Buffer::Manager#sanitize_path`
(`lib/rubik/buffer/manager.rb`):

- Containment resolves symlinks on **both** sides of the prefix check, so a link planted
  inside the workspace cannot redirect reads or writes outside it. Violations raise
  `Buffer::InvalidPathError`.
- Writes additionally pass `Guard#verify_path_write!` on the root-anchored expanded path.
- External locations are **opt-in**: writes outside the primary workspace root require
  `workspace.allow_external_writes: true` (or the root/dir added with `--rw`).

| Key | Default | Meaning |
| :--- | :--- | :--- |
| `workspace.additional_roots` | `[]` | Extra workspace roots |
| `workspace.allowed_external_dirs` | `[]` | Individual external directories agents may touch |
| `workspace.allow_external_writes` | `false` | Global write enable for external roots/dirs |

**Apply-time TOCTOU re-verify.** `Buffer::Manager#apply!` re-checks containment
immediately before each atomic write: a symlink swapped between buffering and apply
blocks the write loudly instead of landing outside the workspace.

## Buffer Staging & Review Authority Gate

- **Virtual Staging:** File writes generated by the model are staged in an in-memory virtual buffer
  rather than written directly to disk.
- **Authority Contract:** Staging does not inherently guarantee human-in-the-loop review. By default,
  `buffer.auto_apply: manual` stages changes, but `buffer.model_can_apply: true` allows the model to
  flush its own staged writes via the `apply_buffer` tool.
- **Enforcing Human Review:** For strict human operator review before changes reach the host filesystem,
  operators must set `buffer.model_can_apply: false` alongside `buffer.auto_apply: manual`. In this mode,
  the `apply_buffer` tool is rejected and only the operator's explicit `!apply` command commits edits.
- **Automatic Apply Policies:** When `buffer.auto_apply` is configured as `on_test`, `on_finish`, or
  `always`, the runtime flushes dirty buffer edits automatically at execution boundaries, without
  requiring operator confirmation.

## External Integrations and Trust Boundaries

- **Language Server Protocol (LSP):** Language servers (`rust-analyzer`, `gopls`, `ruff`,
  `typescript-language-server`, `typeprof`, etc.) are external binaries running on the host system
  as child processes with the user's privileges. Rubik communicates with them over stdio JSON-RPC. If
  a language server binary is missing, unconfigured, or fails its handshake, Rubik degrades gracefully
  to AST/regex analysis without interrupting the session.
- **AST Parser Fallbacks:** Symbol analysis uses built-in Prism (for Ruby) and Tree-Sitter grammars for
  supported languages. If Tree-Sitter grammars or C extensions are unavailable or encounter syntax errors,
  the engine falls back to legacy regex extractors, which have known structural limitations with nested
  constructs, comments, and strings.
- **Plugin Manifests vs Host Execution:** Drop-in plugins (`.rubik/plugins/`) must match SHA-256 digests
  recorded in `.manifest.json`. The manifest guarantees origin integrity and detects unauthorized file
  modifications on disk. However, once loaded, plugins execute arbitrary Ruby code within the host process
  and have access to host resources. Manifests provide integrity verification, not runtime process sandboxing.

## Audit Log

- **Default location:** `~/.rubik/audit.log`
  (`Guard.default_audit_log_path` in `lib/rubik/security/guard.rb`, resolved at call time
  from `Platform.home_dir`).
- **Key:** `security.audit_log_path` is wired at runtime (live-reconfigurable, zero
  restart) but intentionally absent from the schema defaults in
  `lib/rubik/config/defaults.rb` — the Guard is the single source of the default. An
  explicit `null`/blank value **disables** auditing; a non-path value warns and disables.
- **Format:** JSON Lines — `{ts, action, details}`. Events include `blocked_write`,
  `blocked_command`, `blocked_synthesis`, `allowed_command`, `safe_probe`, and
  `classifier_error`. Details pass through the redactor
  (`lib/rubik/security/redactor.rb`) before being written.
- **Known limits**: the log is a plain append with no
  tamper-evidence (no HMAC/chain); allow-paths return unlogged. Treat the audit trail as
  diagnostic, not a compliance control, until elevated.

| Key | Default | Meaning |
| :--- | :--- | :--- |
| `security.audit_log_path` | `~/.rubik/audit.log` | Audit destination; `null`/blank disables |
| `security.command_allowlist` | `[]` | Token-prefix command allowlist entries |
| `security.allow_safe_probes` | `true` | Exempt `--version`/`--help`-shaped probes |

## Reporting Vulnerabilities

If you find a security vulnerability, please do **not** open a public issue. Use GitHub's
**private vulnerability reporting**: open the repository's **Security** tab and click
**Report a vulnerability** — the report goes to the maintainers privately, and you can
coordinate a fix and advisory through GitHub. (If the tab is unavailable, contact the
maintainer directly via their GitHub profile.) Please include a description, reproduction
steps, and the affected commit, and allow time for a fix before public disclosure.

## Verification Surface

The gates above are pinned by the unit suites under `test/unit/`:

- `test_command_classifier_{bash_parser,pwsh_parser,matcher,database,models,integration,sweep}.rb`
  — the command classifier and its rule database.
- `test_critical_write_guard.rb` — critical-write patterns, symlink resolution, command
  gate and allowlist semantics.
- `test_synthesis_security.rb` — synthesis deny layers, including the `ctx.require`
  regression guard.

Run the suite from the repository root to verify the behavior described here against your
checkout.
