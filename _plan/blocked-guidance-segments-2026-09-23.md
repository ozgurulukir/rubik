# Blocked-Command Guidance: Honest Multi-Segment Messages

**Date:** 2026-09-23
**Status:** Approved (user: message-only fix + segment-list format + Sentez architecture)

## Problem

When a `bash -c '<multi-line script>'` command is blocked, `RunCommandTool.blocked_guidance`
renders a misleading message (reproduced from a real session): the sentence subject is the
entire multi-line script, the rule name is only the FIRST innermost dangerous segment's
`matched_rule` key ("git.merge") without the actual trigger (`--abort`), siblings
(`git branch -D`) are ignored, and the `!allow-cmd add` hint embeds the whole script.
The LLM reading it concluded "git merge is blocked" — a faithful reading of a broken message.

Root causes (code):
- `Guard#dangerous_reason`/`#dangerous_rule_name` (guard.rb:342-363) collapse the AST walk
  to one scalar, discarding `overriding_option`, sibling segments, and argv.
- `InnerCommandResult` (models.rb:125) has no `classification_reason` — dropped at
  delegation.rb:118-132; inner system-path elevation (classifier.rb:154-167) is silent.
- Generic template (exec.rb:238-243) interpolates `blocked_command` (full script) twice.

## Settled decisions

1. **Message-only fix.** The allowlist gate (`command_allowlisted?`, guard.rb:211-252,
   top-level argv token-prefix matching) stays UNTOUCHED. Hints must be honest to current
   gate semantics: wrapped scripts → `!allow-cmd add "bash -c"` (+ caveat line); direct
   multi-chains → per-segment entries (they DO open the gate).
2. **Segment-list format** for wrapper/multi-dangerous-segment cases only. Single
   dangerous top-level command keeps today's concise format byte-identical
   (pinned tests survive).
3. **Architecture (Sentez):** C's structure (single frozen Hash envelope on
   `BlockedWriteError`, renderer stays at the `RunCommandTool.blocked_guidance` seam)
   + source-truth reason propagation (models.rb / delegation.rb / classifier.rb, ~10 lines,
   empirically required: `bash -c "rm -rf /"` inner rm is dangerous via SILENT system-path
   elevation, no overriding_option) + A's flag-index wrapper hint derivation
   (`bash -e -c '...'` → hint "bash -e -c", not the non-matching "bash -e").

## Message spec (approved sketch)

```
Security blocked: 2 dangerous segment(s) in `bash -c '...'` — nothing was executed.
  1. git merge --abort   (rule: git.merge — option --abort overrides to DANGEROUS)
  2. git branch -D merge-sim   (rule: git.branch — option -D overrides to DANGEROUS)
Everything else in the script passed classification (git checkout, echo, git merge, grep, head).
Options: drop the blocked segments and rerun each safe command directly, or the operator can allowlist once:
  !allow-cmd add "bash -c"
(segment-level entries only cover top-level commands, not wrapped scripts)
```

Contracts preserved: first line starts with literal `Security blocked:`, single line
(StepExecutor::ERROR_PREFIXES; formatter collapse start_with?); hint lines are
line-anchored `!allow-cmd add "..."` (step_formatter.rb:203 / renderer.rb:121 regex);
`err.message`, audit action names, all other raise sites and branches unchanged.

## Changes

### Commit 1 — `feat(security): propagate classification_reason into delegated inner results`

- `lib/rubik/security/classifier/models.rb`: add `:classification_reason` to
  `InnerCommandResult` (+ kwarg default nil).
- `lib/rubik/security/classifier/matcher/delegation.rb` (`match_inner_command`):
  propagate `inner_result.classification_reason`; when the delegation floor
  (`min_classification`) elevates, set "elevated by delegation floor to <class>"
  (sudo ls becomes explainable).
- `lib/rubik/security/classifier/classifier.rb` (`check_inner_system_paths`): write
  reasons on both elevation branches, wording mirroring the outer form
  ("elevated to DANGEROUS: system path <p>" / "elevated to DANGEROUS by inner command").
- Tests: inner reason for `bash -c "git merge --abort"` == "overridden by option --abort
  to dangerous"; `bash -c "rm -rf /"` inner reason includes "system path /";
  `sudo ls` inner reason mentions delegation floor.

### Commit 2 — `feat(security): name every dangerous segment in wrapper/multi blocked-command guidance`

- `lib/rubik/security/errors.rb`: one new kwarg/accessor `segment_report` (frozen plain
  Hash or nil; file stays dependency-free).
- `lib/rubik/security/guard.rb`: `dangerous_segment_report(commands)` collector —
  innermost-leaf attribution with depth (wrapper whose danger comes from inners
  contributes its leaves), safe-sibling roll call (subcommand-aware names), one-line
  wrapper preview (payload token containing whitespace elided to `'...'`),
  gate-honest allowlist entries (flag-index via `delegation_source`; bare binary for
  rest-argv wrappers). Wired into the raise at guard.rb; audit gains a
  `dangerous_segments` count. `dangerous_reason`/`dangerous_rule_name` untouched
  (rule_name scalar keeps today's semantics).
- `lib/rubik/security/blocked_guidance.rb` (NEW): the guidance renderer extracted from
  `RunCommandTool.blocked_guidance` (architect-B placement, forced by the builtin
  file-size budget: exec.rb must stay < 350 lines). `BlockedGuidance.render` carries
  the whole branch tree (chdir → unstructured → probe → segments → text-munging →
  concise) plus `text_munging?`. `RunCommandTool.blocked_guidance` stays as the
  stable public seam (one-line delegate) for task.rb, tests, dev/review_fix_check.
  Segment branch renders only when `segments.size > 1 || any depth > 0`.
- `lib/rubik/tools/builtins/exec.rb`: delegate + require only.
- Tests:
  - UPDATE `test_run_command_tool_chain_bypass_blocked` (`bash -c "rm -rf /"` → segment
    format, honest hint).
  - NEW merge-sim reproduction (the exact 15-line script from the diagnosed session):
    2 segments, --abort / -D annotations, safe roll call, `!allow-cmd add "bash -c"`,
    no "was denied", script never re-embedded.
  - NEW concise-boundary: direct `git merge --abort` keeps "was denied (rule: git.merge)".
  - NEW guard payload test (`test/unit/test_guard_dangerous_segments.rb`).
  - NEW formatter collapse test for the segment format.
- Drive-by repair: `dev/review_fix_check.rb` chdir fixture lacked `kind:`/`path:`
  (pre-existing failure on HEAD, verified via stash) — fixed to construct the error
  the sandbox runner actually raises.

## Verification

- Targeted: `bundle exec ruby -Ilib -Itest test/unit/test_expanded_tools.rb ...`
- Full: `bundle exec rake test:fast` + `bundle exec ruby dev/review_fix_check.rb`.
- GitNexus impact before edit / detect-changes before commit (index stale → caller
  truth from agent greps + own verification).
