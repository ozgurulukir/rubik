# Plan 100 — Loop cap + SubagentNoticeInbox (fresh-scan card 4, Strong)

Extraction of Loop's subagent notice inbox into a named collaborator +
tool-call id unification. Approach: **Synthesis of 3 architects**
(minimal/clean/pragmatic), all four user Recommended decisions applied.

## Settled decisions (2026-09-23)

1. Inbox-only scope for loop slimming; §7.2 justification note names the
   next extractions (response-parsing family ~36 lines, wire-request path
   ~32 lines). NOT extracting those here.
2. Queue-only inbox boundary: rendering stays `Subagent::Notices`, merge
   stays Loop (owner of @history).
3. `reset_for_new_run!` REASSIGNS a fresh Queue — reassign-faithful,
   preserves today's documented microscopic stranding window.
4. Tool-call ids unified behind one orchestrator module.

## Ground-truth corrections (from architects, vs the card/explorers)

- The card's ≈437 loop.rb target was arithmetic fiction: the 436 floor
  double-counted `merge_notice_block_into_history!` (12 lines), which the
  queue-only boundary pins to Loop. Honest landing: **474/476**.
- `step_executor.rb:40`'s id fallback is NOT dead —
  test_tools_elm_diagnostics.rb:66 calls the executor id-less → routed,
  not deleted.
- The loop spelling's rand suffix is LOAD-BEARING (fresh Loop per turn
  over persistent history → deterministic ids would recur; strict
  providers' pairing breaks). One architect's rand-drop rejected.

## Delivered shape

- `Orchestrator::SubagentNoticeInbox` (orchestrator/subagent_notice_inbox.rb,
  75 lines, flat → auto-capped <400): enqueue (validation byte-verbatim),
  drain_all (pop(true)/ThreadError), reset_for_new_run!, keep_for_continuation
  (named no-op seam); thread-contract class comment is the invariant's home.
- Loop (ContinuationManager mold): eager init + lazy reader
  (`subagent_notice_inbox`), public one-line shims
  (enqueue_subagent_notice — name load-bearing for lifecycle.rb:173's
  respond_to? dispatch; drain_subagent_notices_into_history! renders+merges),
  merge_notice_block_into_history! verbatim, pop_subagent_notices DELETED
  (zero callers), run() → reset_for_new_run!, continue_loop →
  keep_for_continuation.
- `Orchestrator::ToolCallId.mint(*parts, unique:)` (flat module):
  spelling-only; sites keep their id-precedence chains; three outputs
  byte-compatible (loop `call_{step}_{idx+1}_{rand}`, subagent
  `call_{id}_{step}_{idx+1}`, executor `call_{step}_{rand}`).
- ARCHITECTURE.md row 11 updated in both commits.

## Test architecture

- 4 Loop.allocate tests: dead `@subagent_notices` poke lines dropped
  (lazy reader obsolete-ifies them); tests still exercise the real seam.
- New test_subagent_notice_inbox.rb (8 tests: FIFO, ThreadError
  terminator, second-drain no-op, pinned validation message, hash-without-
  kind, reset discards+rearms, keep preserves, 4×25 lock-free concurrent).
- New test_continue_loop_retains_pending_notices (behavioral pin for the
  named no-op).
- New test_tool_call_id.rb (4 tests: joins, unique suffix format regex —
  never cross-sample uniqueness (birthday flake), step-runner byte-compat,
  legacy shape compat).
- test_loop_decomposition.rb:58 `start_with?("call_")` pin survives
  untouched.

## Commits

1. `refactor(orchestrator): extract SubagentNoticeInbox from Loop`
2. `refactor(orchestrator): single-home tool-call id minting behind ToolCallId`
3. this plan doc.

Deferred (recorded): response-parsing family extraction; wire-request
path extraction; step_runner at 214/250; merge_notice_block_into_history!
still public-by-accident on Loop (verbatim kept, smallest diff).
