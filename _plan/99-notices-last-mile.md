# Plan 99 — Notices Last Mile: budget copy + grant/step defaults unification

Fresh-scan card 3 (Strong): "Finish the Notices seam — budget guidance and grant
defaults" (last mile of 2121ff09 + f887e21e). Approach: **Synthesis** (approved
pattern: two nil-safe builders in Notices, grant notes homed in Budget by
audience boundary, no new files, budget reader stays private).

## Settled decisions (user, 2026-09-22)

1. FULL unification of subagent-side budget copy (main-loop copy OFF-LIMITS —
   §7 stateless-over-owner doctrine).
2. REPL `!subagents extend` default 10 → `Budget::DEFAULT_GRANT_STEPS` (20).
3. Most-informative spelling wins; test pins update deliberately
   ("launch" → "spawn", wait channel gains step count).
4. `notices.rb` requires the budget leaf (`require_relative "budget"`) so
   `extend_budget_hint`'s default is constant-sourced (no cycle: budget.rb
   requires only "monitor").

## Target copy vocabulary

- `Notices.budget_paused_line(id, max_steps)` →
  "Subagent reached step budget (N steps) and paused. Call <extend_budget_hint(id)> to resume."
- `Notices.budget_exhausted_line(max_steps = nil)` (nil → no parenthetical) →
  "Subagent reached step budget[ (N steps)] and halted: task was NOT completed. Inspect transcript or spawn a new subagent."
- `Budget.grant_note(extra, total)` →
  "[Supervisor init-0]: Granted E additional step(s). Total budget: T. Continue execution." (family B, unchanged)
- `Budget.message_grant_note(extra, total)` → same + "with message" marker.
- guidance_for:100 "launch" → routed through `budget_exhausted_line` (spawn).
- guidance_for:96 auto-apply: "Apply via the apply_buffer tool." (drop REPL
  `!apply` from the model channel).
- instance.rb:243 stays instance-owned (single-sited, instance voice).
- instance.rb:256 = `budget_exhausted_line(max)` + " Budget expansion was not
  received from init-0." (orchestration :506 prefix pin survives).

## File map

| File | Change |
|---|---|
| budget.rb | +`self.normalize_grant`, +`grant_note`/`message_grant_note`, `grant!` delegates; 75% warning untouched |
| notices.rb | +require budget, +2 builders, launch→spawn, !apply fix, comment compression (→ ~144/150) |
| tools/builtins/subagent.rb | status/wait guidance → builders; extend branch → `Budget.normalize_grant`; schema interpolates `supervisor&.default_max_steps \|\| Budget::DEFAULT_MAX_STEPS` (kwarg only — deterministic) |
| instance.rb | note lambdas → Budget delegations; :256 routes through builder |
| supervisor.rb | :39 fallbacks → constant; :84 dead `\|\| 88` dropped; COMPLETED payload gains `max_steps` |
| repl/commands/subagents.rb | +budget require; extend default → `normalize_grant` (10→20) |
| config/defaults.rb | UNCHANGED (layering); welded by equality drift-guard test |

## Pins

- Must NOT change: hint outputs ("steps: 20"), user_line copies, 75% warning,
  grant-note B (:33/:35), orchestration :506/:647/:519/:579/:620-637.
- Deliberate updates: state_machine :106 (launch→spawn), grant_budget :54/:56
  (note A morphology), orchestration :646/:653 (count-bearing wait guidance).
- Rewrites: budget_scale :19-42 (drift guard + constant-derived schema + 42-override).
- Additions: builder unit pins, normalize_grant pins, REPL no-arg→20 pin,
  refute "!apply" in model channel, COMPLETED payload max_steps pin.
- send(:budget) removal: orchestration :489-507 → provider-driven (template
  :440-487); delete state_machine :15-35 (subsumed) and grant_budget :78-86
  (identical fact pinned on Budget public API in test_subagent_budget.rb:64-74).

## Commits (each green on test:fast)

1. `feat(subagents): single-home grant normalization and notes in Budget`
2. `refactor(subagents): unify budget verdict copy through Notices builders`
3. `fix(subagents): document effective default step budget in tool schema`
4. `test(subagents): drive budget states through providers, not send(:budget)`

Gates per commit: `bundle exec rake test:fast` + rubocop on touched files;
full suite + GitNexus detect-changes before merge.
