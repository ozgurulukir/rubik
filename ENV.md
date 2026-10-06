# Environment Variables

Consolidated reference for every environment variable Rubik reads (verified by scan of `lib/`, `bin/`, `test/`, 2026-09-29). `Dir.home` / `Dir.tmpdir` are Ruby stdlib calls that consult `ENV` themselves; where relevant their behavior is noted in the Details sections.

| Variable | Purpose | Read where | Unset behavior |
| :--- | :--- | :--- | :--- |
| `HOME` | Home directory for config/plugin/overlay/session storage | `platform.rb:74` (via `Dir.home`), `config.rb:26`, `plugin/storage.rb:18`, `runtime/overlay_storage.rb:21`; written by `test/test_helper.rb:8` | Fallback chains apply (see below); final fallback is `"."` |
| `USERPROFILE` | Windows home fallback | `platform.rb:76`, `config.rb:28`, `platform/path.rb:188` (sandbox root list) | Skipped in the chain; also omitted from Windows dangerous-roots |
| `HOMEDRIVE`, `HOMEPATH` | Windows home fallback (drive + path pair) | `platform.rb:76-79` | Skipped unless **both** are set |
| `PATH` | Executable search path for command resolution | `platform/path.rb:36` | Treated as empty (`""`) — no executables found via PATH |
| `PATHEXT` | Windows executable extensions tried during lookup | `platform/path.rb:56` | Hardcoded default `.COM;.EXE;.BAT;.CMD;.VBS;.JS;.WS;.MSC;.PS1` |
| `TERM` | Terminal capability probe (`dumb` disables color) | `ui/capability.rb:80` | No effect; color decided by TTY probe |
| `TEMP`, `TMP` | Temp directory fallbacks | `platform.rb:85` (rescue of `Dir.tmpdir`) | Final fallback `/tmp` |
| `TMPDIR` | Temp directory (indirect only) | `platform.rb:83` via Ruby's `Dir.tmpdir` (stdlib); never read directly | stdlib picks next candidate (`TEMP`/`TMP`/system default) |
| `NO_COLOR` | Disable all ANSI color (any non-empty value) | `ui/capability.rb:73`; written by `bin/rubik:55` (`--no-color`) | No effect |
| `CLICOLOR_FORCE` | Force color even without a TTY (only `"1"`) | `ui/capability.rb:74`; written by `bin/rubik:59` (`--color`) | No effect |
| `RUBIK_DEBUG` | Enable gated `[WARN]` diagnostics (truthy check) | 11 sites: `platform.rb:32`, `repl/lifecycle.rb:364` (helpers) + direct reads in `ast/extractor.rb:49`, `ast/treesitter_extractor.rb:87`, `config/store.rb:40`, `plugin/storage.rb:34`, `runtime/overlay_storage.rb:46,268,472`, `session/recorder.rb:23`, `ui/theme.rb:103` | Silent; intentional `rescue`-and-fallback paths stay invisible |
| `RUBIK_TEST` | Test-mode: deterministic, non-interactive behavior | `ui/capability.rb:44,72`, `repl/confirmations.rb:39`, `repl/lifecycle.rb:136,151` (`ast.async_warm` + `mcp.async_load` env-aware defaults), `runtime/overlay_storage.rb:221`, `tools/builtins/synthesis.rb:123`; set by `test/test_helper.rb:10` | Normal interactive behavior |
| `RUBIK_VAKANUIS_FORCE` | Test-only escape hatch: lift the RUBIK_TEST armor so the Vakanüvis chronicler binds in test shells (only `"1"`) | `storage/vakanuvis/service.rb` (`enabled?`); set by `test/unit/test_vakanuvis_harness.rb` setup | Under `RUBIK_TEST` the chronicler stays unbound (no background distiller spawns in scripted-shell tests) |
| `RUBIK_FIBER_SCHEDULER` | Kill-switch for the fiber-scheduler event loop (`Rubik::Concurrency`): value `"off"` (case-insensitive) disables the scheduler so blocking I/O runs on plain threads | `concurrency.rb:109` (`@disabled`) | Fiber scheduler stays enabled (default) |
| `RUBIK_LOG_LEVEL` | Log verbosity gate for `Rubik::Log` (`debug`/`info`/`warn`/`error`) | `log.rb:19` | Defaults to `"warn"` |
| `RUBIK_NATIVE` | Override for native tool acceleration (`auto`/`on`/`off`); beats the `tools.native` config value | `tools/native_search.rb:64`, `context/git_lister.rb:32` | Falls back to `tools.native` config, then `"auto"` |
| `RUBIK_RG_PATH` | Full path to the ripgrep binary used by `grep_search` acceleration; beats PATH lookup | `tools/native_search.rb:51` | rg resolved from `PATH` |
| `RUBIK_TRUST_OVERLAYS` | Security escape hatch: trust all plugins/overlays without hash verification (only `"1"`) | `plugin/storage.rb:77`, `runtime/overlay_storage.rb:352` (`trust_mode?`) | Full SHA-256 manifest verification enforced |
| `RUBIK_BOOTSTRAP_OVERLAYS` | Opt-in: first-scan acceptance of sentinel overlay files when no manifest exists (only `"1"`) | `runtime/overlay_storage.rb:412` (`bootstrap_opt_in?`) | Unrecorded sentinel files are skipped with a `[BOOTSTRAP]` notice |
| `BASH_CLASSIFY_CONFIG_DIR` | Override directory for user command-classification rules (takes precedence) | `security/classifier/database.rb:25` | Next candidate (`RUBIK_COMMAND_CONFIG_DIR`), then default |
| `RUBIK_COMMAND_CONFIG_DIR` | Same as above, lower precedence | `security/classifier/database.rb:25` | Default `~/.config/rubik/commands` |
| `XDG_CACHE_HOME` | Test-only: preserve real cache dir while `HOME` is redirected | `test/test_helper.rb:7,9` only; no `lib/` reader | `||=` restores it only if unset |
| `SystemRoot`, `ProgramFiles`, `ProgramFiles(x86)`, `CommonProgramFiles`, `SystemDrive` | Windows sandbox: expand the "dangerous system roots" denylist | `platform/path.rb:184-190` | Those roots are simply not added (fixed literals like `c:/windows` remain) |

## Details

### HOME / USERPROFILE / HOMEDRIVE / HOMEPATH

Three different fallback chains exist (verified):

- `Rubik::Platform.home_dir` (`platform.rb:73-80`): `Dir.home`; on failure → `USERPROFILE` → `HOMEDRIVE + HOMEPATH` (concatenated; only when **both** are set) → `HOME` → `"."`.
- `Rubik::Config` (`config.rb:22-30`): prefers `Platform.home_dir` when defined; standalone fallback is `Dir.home` rescue (`USERPROFILE` → `HOME` → `"."`) — no `HOMEDRIVE`/`HOMEPATH` leg here.
- `Plugin::Storage` (`plugin/storage.rb:18`) and `Runtime::OverlayStorage` (`runtime/overlay_storage.rb:21`): constructor kwarg defaults to `ENV.fetch("HOME", nil)`, then `home_dir || ENV["HOME"] || "."`. Plain `HOME` only — on a Windows system without `HOME` these resolve to `"."` while `Platform.home_dir` would resolve `USERPROFILE`. Callers passing an explicit `home_dir:` bypass `ENV` entirely.

`Platform.home_dir` consumers: `config.rb:23`, `ast/cache_store.rb:33` (AST cache), `security/guard.rb:125` (audit log at `~/.rubik/audit.log`), `security/guard.rb:350` (home-path equality check). The two storage classes lay out global state under `<home>/.rubik/` — `plugins` (`plugin/storage.rb:27`), `commands` and `tools` (`runtime/overlay_storage.rb:30,38`); project-scoped twins live under `<root_dir>/.rubik/` and do not touch `ENV`. `Dir.home` itself resolves `HOME` on POSIX and `HOME`/`USERPROFILE`/`HOMEDRIVE+HOMEPATH` on Windows (Ruby stdlib), so the explicit rescue chains only fire when those are all unset or invalid.

### RUBIK_DEBUG

Gates `warn "[WARN] ..."` diagnostics for deliberately swallowed exceptions/rescue-fallback paths (convention established in `config/store.rb`; see also `security/guard.rb` comments at 147/475/853 explaining which security warnings are deliberately *not* gated). The check is plain truthiness: `if ENV["RUBIK_DEBUG"]` — in Ruby any set value enables it, **including an empty string** (`RUBIK_DEBUG=""` is truthy). Two reusable helpers exist: `Rubik::Platform.debug_warn` and `REPL::Lifecycle#debug_warn` (both never raise).

Read sites by subsystem (all `if ENV["RUBIK_DEBUG"]`):

- `ast/`: extraction failure warnings (`extractor.rb:49`, `treesitter_extractor.rb:87`)
- `config/`: config-directory creation failure (`store.rb:40`)
- `plugin/`: plugin-directory creation failure (`storage.rb:34`)
- `repl/`: swallowed lifecycle exceptions (`lifecycle.rb:355` via its helper)
- `runtime/`: overlay directory creation (`overlay_storage.rb:46`), tool save failure (`:268`), sentinel-check failure (`:472`)
- `session/`: sessions-directory creation failure (`recorder.rb:23`)
- `ui/`: unknown theme style rendering plain (`theme.rb:103`, once per style)
- `platform/`: UTF-8 sanitation and atomic-write fallbacks (via `debug_warn`, `platform.rb:28`)

### RUBIK_TEST

Set to `"1"` by `test/test_helper.rb:10`. Production semantics are mixed:

- Exact `"1"` comparisons: color forced off and spinner disabled (`ui/capability.rb:44,72`); interactive input/confirmations disabled (`repl/confirmations.rb:39`); `ast.async_warm` and `mcp.async_load` default to `false` when unset (i.e. synchronous warm/boot under tests — `repl/lifecycle.rb:136,151`).
- Truthiness (`unless ENV["RUBIK_TEST"]`): suppresses a warning when an overlay/custom command is invoked without a dispatch `CommandContext` (`runtime/overlay_storage.rb:221`, `tools/builtins/synthesis.rb:123`) — here any value, even `"0"`, has an effect.

### NO_COLOR / CLICOLOR_FORCE precedence

Resolution order in `UI::Capability.resolve_mode` (`ui/capability.rb:71-85`): `RUBIK_TEST=1` → `NO_COLOR` (any non-empty value) → `CLICOLOR_FORCE=1` → config `ui.color: always|never` → `TERM=dumb` (case-insensitive) → non-TTY → Windows VT probe. **`NO_COLOR` wins over `CLICOLOR_FORCE`** (checked first). `NO_COLOR` accepts any non-empty value; `CLICOLOR_FORCE` must be exactly `"1"`, other values are ignored. The `bin/rubik` CLI flags `--no-color` / `--color` work by setting these variables (`bin/rubik:55,59`).

### TEMP / TMP / TMPDIR

`Platform.tmp_dir` (`platform.rb:82-86`) is `Dir.tmpdir` with a rescue of `TEMP || TMP || "/tmp"`. `TMPDIR` is never read by Rubik code; it reaches `Dir.tmpdir` only through Ruby's stdlib `tmpdir` library, which probes `TMPDIR`/`TEMP`/`TMP` (verifying writability) before system defaults. `Platform.tmp_dir` currently has no callers inside `lib/` — it is a platform API kept for consumers (tests create temp dirs via `Dir.mktmpdir` directly).

### Security-relevant overrides

- `RUBIK_TRUST_OVERLAYS=1` (exact match required): bypasses SHA-256 manifest verification for plugin files (`plugin/storage.rb:77` returns `:trusted` immediately) and, via `trust_mode?`, makes **every** `*.rb` overlay file trusted regardless of manifest state — missing, corrupt, or unrecorded (`runtime/overlay_storage.rb:92-94, 385`). Since overlay files are `eval`'d (`overlay_storage.rb:340`), treat this as a trusted-development escape hatch only; never set it against untrusted clones.
- `RUBIK_BOOTSTRAP_OVERLAYS=1` (exact match): only effective when a directory's `.manifest.json` is **absent**. Allows one-time acceptance of sentinel-headed overlay files (`# Rubik Custom Command:` / `# Rubik Custom Tool:`); their hashes are then written into the manifest permanently, so later runs need no env var. Without it, first-scan sentinel files are skipped with a visible notice; unknown files are rejected in every case (`overlay_storage.rb:105-108, 388-404`).
- `BASH_CLASSIFY_CONFIG_DIR` / `RUBIK_COMMAND_CONFIG_DIR` (`security/classifier/database.rb:24-28`): `BASH_CLASSIFY_CONFIG_DIR` takes precedence; the value is a config root — the loader appends `commands` and uses it only if that directory exists, otherwise falls back to `Dir.home/.config/rubik/commands` (also only if it exists). User rules extend the built-in command classification database.

### XDG_CACHE_HOME (test-only)

No `lib/` code reads it. `test/test_helper.rb:7-9` captures the real cache dir before replacing `HOME` with a temp dir, then restores it only if unset — so gems/tooling that honor XDG cache locations keep working under test.

### Windows sandbox roots

`Platform::Path#dangerous_system_roots` (`platform/path.rb:180-193`) appends `SystemRoot`, `ProgramFiles`, `ProgramFiles(x86)`, `CommonProgramFiles`, `USERPROFILE`, and `SystemDrive` (as `X:/` and `X:`) to the write-denylist when set on Windows. Each entry is conditional: unset variables contribute nothing beyond the fixed literal roots.

### Value-acceptance conventions (summary)

- Exact `"1"` required: `RUBIK_TEST` (most sites), `RUBIK_TRUST_OVERLAYS`, `RUBIK_BOOTSTRAP_OVERLAYS`, `CLICOLOR_FORCE`.
- Any non-empty value: `NO_COLOR`.
- Any set value (truthy, even empty string): `RUBIK_DEBUG`, and the `unless ENV["RUBIK_TEST"]` warning-suppression sites (`runtime/overlay_storage.rb:221`, `tools/builtins/synthesis.rb:123`).
- Directory path: `BASH_CLASSIFY_CONFIG_DIR` / `RUBIK_COMMAND_CONFIG_DIR` (used only if `<value>/commands` exists).
