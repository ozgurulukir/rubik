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
   `unknown` and is blocked (hardened in Plan 111, see
   `_plan/plan-111-security-gate-hardening-2026-09-27.md`). The block message points at the
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

If the classifier itself crashes, the gate degrades to the fallback regex only, with an
unconditional warning and an audit entry (documented residual, Plan 111).

## Critical-Write Protection

`Guard#verify_path_write!` in `lib/rubik/security/guard.rb`:

- **Critical patterns.** `DEFAULT_CRITICAL_PATTERNS`: `.git/**`, `.env*`, `secrets.*`,
  `*.pem`, `*.key`, `id_rsa*` — matched against the raw path, the expanded path, and the
  pwd-relative form. Operators can add patterns.
- **Symlink resolution before the block.** After the lexical checks, the path is resolved
  via `Rubik::Platform.resolved_path(path, strict: true)`. A symlink planted inside the
  workspace (`foo -> .git/config`) is caught at the resolved target; dangling symlinks and
  resolution failures (symlink loop, permission wall) block the write fail-closed.
- **Atomic writes.** Disk writes go through `atomic_write`
  (`lib/rubik/platform/filesystem.rb`): write to a temp file, `fsync`, then `rename` —
  never unlink-first — so a partially written file is never observable and the
  rename-time TOCTOU window is closed. Transient Windows rename locks are retried.
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
| `network.allow` | `false` | Global network access for agent-initiated requests |

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
- **Known limits** (Plan 111 deferred debts): the log is a plain append with no
  tamper-evidence (no HMAC/chain); allow-paths return unlogged. Treat the audit trail as
  diagnostic, not a compliance control, until elevated.

| Key | Default | Meaning |
| :--- | :--- | :--- |
| `security.audit_log_path` | `~/.rubik/audit.log` | Audit destination; `null`/blank disables |
| `security.command_allowlist` | `[]` | Token-prefix command allowlist entries |
| `security.allow_safe_probes` | `true` | Exempt `--version`/`--help`-shaped probes |

## Reporting Vulnerabilities

If you find a security vulnerability, please do **not** open a public issue. Contact the
maintainers privately (contact address TBD) with a description, reproduction steps, and
affected commit. Please allow time for a fix before public disclosure.

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
