# Plan: CommandContext — deepen the command layer (Candidate 06)

**Date:** 2026-09-22 · **Approach:** Clean architecture (user-approved) · **Source:** 2026-09-20 review backlog 06, re-verified 2026-09-22

## Problem

14 command modules in `lib/rubik/repl/commands/` register 58 handlers closing over the entire Shell:
43 distinct members reached, 429× `shell.output.puts`, 57 hand-rolled `Usage:` literals, 10×
`shell.respond_to?` probing, 4 ivar pokes (`@paste_requested`, `@buffer`, `@home_dir` ×3).
The command axis has no facade; `ShellDeps` (§7.1) covers only the orchestrator axis.

## Design (locked in grilling + architect comparison)

- **`Rubik::REPL::CommandContext`** (`lib/rubik/repl/command_context.rb`), built **per dispatch**
  inside `with_output(TeeIO...)` in `InputExecution#execute_command` so `ctx.out` reflects capture.
  Agent path (`exec.rb`) re-enters `execute_input` → zero changes there.
- **Interface**: `out` (+ `output` alias for UI duck-compat: Panel/DiffViewer/Approvals take ctx),
  services **derived from `ServiceCatalog.reader_names`** via `define_method` (SSOT reuse),
  `plugin_manager`/`plugin_storage` via Coeffects, named effects (~16),
  rebindable state as delegating accessors (`conversation_history`, `active_loop` get+set,
  `conversation_route_stamp=` writer, `agent_caller` reader). CLOSED: no `register_command`,
  no ivar writes, no `respond_to?` probing (nil-safe reads instead).
- **Handler convention** `|args, ctx|` (procs ignore extras → backward compatible).
  Custom-command dispatchers aligned in one commit: `synthesis.rb:105-113` (2-arity → ctx,
  3-arity keeps raw shell), `overlay_storage.rb:209-218` (same), `preflight_runner.rb`
  (stays StringIO duck — `tools/→repl/` require ban).
- **Cleanups folded in**: `Shell#request_paste!` (paste_support), `Config#home_dir`,
  `BufferManager` buffer reader, `Shell#sync_workspace_index!` (ast_warmup.rb §7 home),
  `Shell#resync_llm_route!` (config_wiring.rb §7 home; replaces `AgentModels.sync_default_provider`).
- **Usage metadata**: `register_command(..., usage:)`; top-level fallback literals hoisted to
  per-module constants; `!help <cmd>` / `!commands` render `meta[:usage]`. Sub-branch strings
  stay inline (deferred debt). `!help`/`!commands` stay in `system.rb`.
- **Guard test** (`test_repl_command_context_guard.rb`): ban `\bshell\b`/`@shell`/`ivar` access in
  `commands/` except registration spine (`def self.register(shell)` + `shell.register_command(`);
  closed-interface freeze test on ctx; allowlist-rot self-check. Lands LAST.
- **Out of scope**: `lib/rubik/ui/`, `Session::Replayer` (ctx gains `session_replayer` factory —
  it must keep the real Shell: plants `@replaying` on its receiver).

## Commits

1. `feat(repl)` — cleanups + CommandContext + `usage:` plumbing + `test_command_context.rb` (inert).
2. `feat(repl)` — dispatch flip `(args, ctx)`; fix 8 strict lambdas + zero-arity blocks;
   align 3 custom-command dispatchers + schema text.
3. `refactor(repl)` — migrate system/session/buffer (+ cleanups wired).
4. `refactor(repl)` — migrate tasks/skills/subagents/lsp/mcp/plugins (respond_to? probes die).
5. `refactor(repl)` — migrate agent_* + workspace (largest; sync_workspace_index! sites).
6. `test(repl)` — boundary guard test + ARCHITECTURE.md §7 note.

## Verification per commit

`bundle exec rake test:fast` green · rubocop ≤ baseline 101 offenses · CRLF fix
(`sed -i 's/\r$//'` after edits) · grep gates (0 `shell.` outside spine per migrated module) ·
final full `bundle exec rake test` + GitNexus `detect-changes`.

## Risks

1. Strict-lambda `ArgumentError` at dispatch flip → all lambdas fixed in commit 2.
2. Capture loss if `out` is constructor-captured → `out` is a dynamic delegate + unit test.
3. Custom-command contract divergence across the 3 dispatchers → aligned atomically in commit 2.
4. `Session::Replayer` receiving ctx would plant `@replaying` on the wrong object → factory returns real-Shell Replayer.

## Deferred debt

Sub-branch usage literals (~31) still inline; UI still duck-typed on ctx (`output/input/runtime_manager`);
`conversation_history` mutated by reference (`<<`/`clear`) — only reassignment is a named effect.
