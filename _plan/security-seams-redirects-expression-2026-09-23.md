# Security Seams: Inner Redirects + Expression-Level Danger Reason

**Date:** 2026-09-23
**Status:** Approved (user: two re-parse modes only; outer-parity elevation; honest
expression reason; write_paths inclusion; Engine-time architecture B)

## Seams being fixed

1. **Inner redirects dropped at delegation** — `match_inner_command` synthesizes the
   inner invocation with `redirects: []`, so `bash -c 'echo pwned > /etc/shadow'`
   classifies clean while the unwrapped form is blocked (block asymmetry, fail-open).
2. **Expression-level danger has no evidence** — `build_expression_result`'s
   mutating-pipeline + system-directory elevation is the only DANGEROUS producer with
   no reason; guard falls to `reason: "dangerous_ast"` / `rule_name: "dangerous_pattern"`
   (conflated with regex hits) and the guidance suggests a dead-on-arrival allowlist hint.

## Approved design (Architecture B: Matcher transports, Engine interprets)

- `InnerCommandResult.redirects: []` — pure transport; only the two re-parse modes
  (flag_value_is_expression: bash/sh/zsh -c; args_are_expression: eval) pass
  `inv.redirects`. Token-slice modes stay argv-only (nested `-c` re-covers them).
- New `Engine#apply_inner_redirects` reuses `extract_paths` + `apply_redirects`
  verbatim (LOCAL floor, /dev/tcp, risk damping); runs as the FIRST step inside
  `check_inner_system_paths` (before the severity gate that skips READONLY inners).
- System-path redirect-target scan added with `!= DANGEROUS` guard (outer parity,
  no stacked reasons after /dev/tcp).
- Inner write targets aggregate into `ExpressionResult#write_paths`
  (`collect_inner_write_paths`, same WRITE_OPERATORS bucketing, `.uniq`).
- Segment display renders the redirect: `echo pwned > /etc/shadow` (guard
  `display_tokens`), argv stays pure for allowlist entries.
- `ExpressionResult.classification_reason` composed at the elevation branch
  ("mutating pipeline (touch) touches system directory /etc"; `mutator?` extracted
  and shared with `mutating_pipeline?`; participants capped at 3).
- `BlockedWriteError.classification_reason` (plain string); guard swaps the
  `"dangerous_ast"` sentinel for the composed reason; `rule_name` fallback becomes
  `"expression_level"` when an expression reason exists (genuine regex hits keep
  `"dangerous_pattern"`; audit distinguishability preserved via dangerous_segments key).
- New guidance variant when segment_report nil + expression reason present:
  first line `Security blocked: \`<preview>\` — nothing was executed.` + reason line +
  restructure steer; NO `!allow-cmd` line (nothing honest to suggest).

## Commits

1. `feat(security): carry delegated inner redirects through engine elevation`
   — models/delegation/classifier/guard + tests (survives, /dev/tcp, nested
   sudo sh -c, /tmp stays safe, write_paths, redirect segment display).
2. `feat(security): compose honest reason for expression-level danger`
   — models/errors/classifier/guard/blocked_guidance + tests (reason composition,
   rule label, guidance variant, audit).
3. `test(allowlist): enrich mock AST fixtures for the segment-report walk` —
   post-review hygiene: the two hand-rolled Struct fixtures lacked matched_rule;
   the collector crashed and rescue-isolation downgraded the report (suite noise).
4. `fix(security): keep the dangerous_ast sentinel expression-exclusive` —
   review finding: dangerous_reason recursed into SAFE inners, shadowing a
   dangerous command's own elevation reason with the sentinel.

## Review-discovered pre-existing debts (out of scope, verified live)

- **Heredoc-followed-by-redirect drops both**: `cat << EOF > /etc/passwd`
  parses as ERROR node → no redirects extracted → ALLOWED (top-level and
  wrapped). parse_warnings exist but the guard's regex fallback allows silently.
- **`&&`-trailing redirect attaches to the FIRST command** (parser
  walk_redirected_statement): wrong evidence in messages; worst case
  `ls /tmp && git status > /etc/hosts` + printed entries → gate ALLOWS a real
  /etc write. Fix direction: attach to the LAST command + thread redirects
  onto CommandResult for display symmetry.
- Top-level redirect blocks keep the concise variant's dead allowlist hint
  (`!allow-cmd add "echo pwned > /etc/shadow"` — unmatchable).
- `WRITE_OPERATORS` misses `&>>` (risk/write_paths fidelity only).
- Nested `-c` depth ~50 → NoMemoryError (not StandardError — escapes rescues;
  delegation depth cap as follow-up).
- `/dev/null` as redirect target trips the /dev system-path rule (outer parity
  preserved, wart documented in F1 commit).

## Verification

Existing pins must stay green: unwrapped /etc (:29), /tmp write_paths (:35),
/dev/tcp (:42), inner argv reason (:64-72), merge-sim exactly-2-segments
(`2>/tmp/m.err` is /tmp-safe), rm -rf / concise, task-manager either-prefix.
Per-file `bundle exec ruby -Ilib -Itest`, full `bundle exec rake test:fast`,
rubocop + CRLF sed, GitNexus impact/detect-changes.
