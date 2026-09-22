# Plan 98 — One AutoApply policy instead of eight spellings

Architecture-review candidate (2026-09-22 report, card 2, Strong): buffer
auto-apply policy smeared across step_executor / subagent step_runner /
supervisor / REPL commands with divergent side effects. Explored via
/feature-dev 2026-09-22; approach approved: **synthesis** (deep decision
module + canonical effect + failure channel + copy vocabulary; transport
stays at call sites).

## Problem

Eight automatic apply-decision sites, all converging on
`Buffer::Manager#apply!`, each spelling the policy differently:

| Site | File:line | Trigger | Policy today | Effects today |
|---|---|---|---|---|
| A1 | orchestrator/step_executor.rb:44 | pre test-class tool | mode ∈ {on_test, always} | apply+sync+on_step(:pre_execution), propagates |
| A2 | step_executor.rb:63 | finish | mode ∈ {on_finish, on_test, always} | same, reason "finish" |
| A3 | step_executor.rb:174 | post-tool | mode == always | apply+sync, SILENT |
| S1 | subagent/step_runner.rb:143,151 | pre test-class tool | flag==true OR mode ∈ {on_test, always} | apply only, rescue→nil, no sync |
| S2 | step_runner.rb:135 | subagent finish (non-branch) | same; ignores on_finish | apply only, rescue→nil |
| V1 | subagent/supervisor.rb:296,303 | completion :completed | flag==true ONLY | apply+sync via coeffect, rescue→nil |
| R1 | repl/commands/agent_execution.rb:121 | !test | mode ∈ {on_test, always} | apply+sync+line+un-applied warning |
| R2 | agent_execution.rb:168 | !sh | mode ∈ {on_test, always} | apply+sync+line, no warning, drifted copy |

Drift: supervisor ignores `buffer.auto_apply`; subagent finish ignores
`on_finish`; both subagent sites swallow apply failures (tests can silently
run on stale disk); S1/S2 skip the AST sync everyone else performs; inline
`false` default for `subagents.auto_apply_buffer` contradicts
defaults.rb's `true`; copy drift ("file(s)" vs "modified file(s)").

## Settled decisions (user-approved Recommended options)

1. **Reconcile** to ONE rule set (not per-site preservation). Universal
   composition: `subagents.auto_apply_buffer == true` enables every
   trigger on subagent paths; otherwise `buffer.auto_apply` decides per
   trigger. Main path keys on mode only. Supervisor completion and
   subagent finish start honoring on_finish/always; A3 emits a
   `post_tool` notice instead of silence.
2. **`on_test` keeps firing at finish** (A2 quirk preserved — unpinned
   but plausibly intentional; dropping it is an unrequested behavior
   change). One finish-family set: {on_finish, on_test, always}.
3. **Defensive nil-config flag default stays `false`** (load-bearing:
   test_subagent_orchestration.rb:360 builds a nil-config Supervisor and
   pins merge-without-apply; production wiring always passes a real
   Config where defaults.rb's `true` governs). One spelling, pinned by a
   named test.
4. **Report, don't swallow** on subagent paths: failures emit a new
   `Notices::AUTO_APPLY_FAILED_EVENT`; main path keeps propagating.
5. **All 8 sites** call the policy; one copy vocabulary (R2 gains
   "modified" + the missing un-applied warning).
6. No NEW subagent post-tool trigger (reconcile existing triggers only).

## Design

New `Rubik::Orchestrator::AutoApply` (orchestrator/auto_apply.rb,
stateless module_function, ProviderRecovery lineage, owns/leaves header):

- `TRIGGER_MODES = { pre_execution: %w[on_test always], finish:
  %w[on_finish on_test always], post_tool: %w[always] }`
- `TEST_CLASS_TOOLS = %w[run_command run_tests test lint]`
- `mode(config)` — one defensive read spelling ("manual" default)
- `subagent_flag_on?(config)` — strict ==true, nil→false
- `apply?(config, trigger:, subagent: false, tool: nil)` — THE decision
  (flag OR mode composition when subagent)
- `apply_and_sync(buffer_manager, shell)` — canonical effect: apply!,
  sync unless applied empty, errors PROPAGATE
- `report_failure(event_bus, id:, role:, state:, trigger:, error:)` —
  emit `Notices::AUTO_APPLY_FAILED_EVENT` (warn fallback when bus nil)
- copy: `applied_line(count, phase)` / `unapplied_warning(subject)`

Sites after: A1/A2/A3 → `apply?` + `apply_and_sync` + existing `on_step`
(reason "pre_execution"/"finish"/"post_tool"); S1/S2 → `apply?(subagent:
true)` + `apply_and_sync(shell via Coeffects.get(@context, :shell))` +
`report_failure` (child ctx alive during step loop; parent-chain walk
verified); V1 → same with `@root_context` (child ctx disposed before
on_complete); R1/R2 → `apply?` + `apply_and_sync(shell: ctx)` + copy
helpers.

S1/S2 gain the AST sync everyone else already has (closes real staleness
gap: subagent edits bypass the AST index until completion today;
off-thread sync precedent: supervisor completion already syncs off-thread).

Notices: `AUTO_APPLY_FAILED_EVENT = :subagent_auto_apply_failed` +
EVENTS entry (auto-subscribed via lifecycle EVENTS.keys iteration);
trigger folded into `reason` at emission to reuse the existing 120-char
cap branch — notices.rb stays under its 150-line cap.

Loop loses `buffer.auto_apply` read (loop.rb:435) → the §7.2 boundary
allowlist SHRINKS (remove `/@shell&\.config&\.fetch/`).
StepExecutor keeps `auto_apply_mode = nil` optional override
(3 test files call with 3 args). Prompt layer untouched
(context_builder.rb:293 raw read stays).

## Pinned behaviors that must survive (no edits)

- on_finish applies at main finish; on_test pre-exec main
  (test_buffer_reminder_and_auto_apply.rb:79,111)
- subagent pre-run_tests apply under flag-true default
  (test_subagent_editing_and_test_isolation.rb:54)
- branch merge + apply on :completed (:94)
- :budget_exhausted → NO merge/apply (test_instance_budget_state_machine.rb:55)
- merge-without-apply when flag off / nil config
  (test_subagent_orchestration.rb:360)
- :failed → no merge (:381)
- format_auto_apply string (test_verbosity_and_step_formatter.rb:202)

## Commits (each suite-green)

1. `feat(orchestrator): add AutoApply policy module for buffer auto-apply`
   — auto_apply.rb + test_auto_apply_policy.rb (pure addition)
2. `refactor(orchestrator): route main-path auto-apply through AutoApply`
   — A1/A2/A3 (+A3 post_tool notice), loop.rb:435 removal, optional
   param, allowlist shrink, new A3 emission test
3. `refactor(subagent): reconcile subagent auto-apply and report failures`
   — S1/S2/V1, child-ctx sync, Notices event, new pins (supervisor honors
   on_finish flag-off; subagent finish honors on_finish; failure notice)
4. `refactor(repl): unify !test/!sh auto-apply through AutoApply`
   — R1/R2, copy vocabulary, !sh un-applied warning, tests

## Verification

Per-commit targeted files (bundle exec ruby -Ilib -Itest …; note
test_buffer_reminder is SLOW-excluded from test:fast — run file-wise),
then `bundle exec rake test:fast`, `bundle exec rubocop`, final
`bundle exec rake test` + GitNexus detect-changes before merge.
CRLF discipline: `sed -i 's/\r$//'` after every edit batch.
