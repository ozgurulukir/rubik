# Changelog

All notable changes to Rubik are documented here. The project has not cut a
release yet — everything below lives under **Unreleased**, grouped thematically.
The complete record (457 commits, 2026-08-23 → present) is `git log`; each
entry below links a theme to its plan document in `_plan/` where one exists.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Highlights

- **Self-evolving tool runtime**: synthesized tools with fail-closed AST
  security gates, hot reload, and unsynthesize; skills and MCP tools join the
  same coeffect-gated registry.
- **Spatiotemporal runtime**: revertible-effect `Context` (LIFO Ω unwind,
  atomic rollback, deferred-signal drain), topological fiber reconciliation,
  reactive provide/unprovide, and a kernel event bus with dmesg telemetry
  (Plans 102–107).
- **Subagent hierarchy**: init-0 orchestration contexts, step budgets with
  pause/resume negotiation, wait protocol with reactive event-bus wakeups,
  process-unique transcript ids, and budget transparency (Plans 94–96, 109).
- **Security gate hardening**: command classifier with fail-closed unknown
  handling, symlink-resolved critical-write block, TOCTOU-closed atomic
  writes, unified guard policy, secret redaction, and sandbox process
  isolation (Plan 108, 111).

### Added

- Agent loop: token budget autonomy with auto-continuation, wait hints,
  reactive wakeups, and structured failure notices (Plan 90, 109).
- Kernel: deterministic event dispatcher, kworker queue, monotonic dmesg ring
  buffer with `!dmesg` (Plans 102–104).
- Tools: `ask_question` interactive dialog (Plan 92), async background task
  manager with `manage_task` (Plan 93), native search with rg fallback,
  AST-backed symbols, LSP diagnostics surfacing.
- REPL: `!paste` mode with burst join (Plan 91), per-dispatch CommandContext,
  session prune, command usage synopses, non-blocking prompt with terminal
  guard (Plan 105).
- Config: typed model/provider catalog CRUD (`upsert_provider_model`,
  `set_model_spec`, …) with uniform persist-failure outcome hashes; modular
  Config (defaults/deep_ops/store/model_catalog mixins).
- Testing: shared scripted agent-loop harness, slow-file quarantine with
  measured profiling, parallel worker task (N=4 stable).

### Fixed

- Security: classify env-assignment payloads as inner commands; expression-
  exclusive dangerous-AST sentinel; normalize paths and canonicalize Windows
  allowlists; keep delegated redirects classified.
- Runtime: per-fiber dispose isolation with LIFO unwind; complete context
  drain before re-raising interrupts; post-dispose registration guard;
  task-tree teardown via `kill_all` inverse.
- LLM: jittered retries, idle-reset stream timeouts, honest blocked-guidance
  reasons, overflow-pattern hardening.
- Buffer: resolved containment enforced at both sanitize and apply
  boundaries; rename-only atomic writes; apply-failure surfacing.
- LSP: robust header framing with response TTL and cancellation; Windows byte
  framing; reader-loop error isolation.
- Config/REPL: silent-persist gaps closed — blocked deletions surfaced,
  persist failures reported instead of silent success.

### Performance

- AST: sub-second mtime plus content-hash cache keys; persistent lazy
  indexing (Plan 39); background warmup with teardown joins.
- Context: serialized index mutations, snapshot-outside-lock reconcile,
  streaming-first truncation.

[Unreleased]: https://github.com/ozgurulukir/rubik/commits/main
