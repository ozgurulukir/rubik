# Changelog

All notable changes to Rubik are documented here. 0.1.0 is the first packaged
release; its section is the thematic roll-up of the pre-gem history (485
commits, 2026-08-23 → 2026-10-09, see `git log`).

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

Nothing yet.

## [0.1.0] - 2026-10-09

First rubygems.org release of the `rubik` gem. Linux and macOS install out of
the box; **Windows** needs the Rust GNU toolchain because
`tree_sitter_language_pack` publishes no Windows prebuilt — see the README
installation section.

### Added

- **Vakanüvis v2 pipeline** (plan `_plan/vakanuvis-v2-2026-10-06.md`, from the
  vue-hakedis review `note.2.6af8197f2600ea57`): the chronicler's compile
  pipeline is now card-first and recall-aware.
  - `Store#search_ranked` — BM25-lite relevance ranking for recall (same
    token-AND candidate gate as `search`; df free from the filter pass,
    bytesize length normalization, tf scanned only over matches; ties break
    `updated_at` desc then `[type,row]`). `search`'s `[type,row]` contract is
    untouched; ranking lives in the recall presentation layer only. New rake
    bench metric measures the ranked/plain add-on ratio (1.44x measured).
  - Card-first distiller brief: memory cards head the source list (capped,
    honest empty state), the session annal is demoted to an event index, and
    the content policy bans "turn N" narratives/raw measurements, requires a
    one-sentence opener (doubles as the home-index line), `Last verified:`,
    and a bilingual `Keywords:` line (recall is keyword-AND; a TR query
    cannot find an EN page without shared vocabulary). Harvest stamps
    `links['verified_session']` as the deterministic staleness trace.
  - Source discipline: `job[:transcript_uris]` (previously declared but never
    populated) now snapshots completed-only, non-vakanuvis transcripts
    (newest 8); the brief fences the list as out-of-scope beyond it.
  - Recall smoke test: proposals may end with up to 5 `CHECK: <query>` lines;
    the harness runs them through real recall semantics after each compile,
    writes recall-gap note cards on misses, surfaces them in the next brief
    as Keywords-enrichment requests, and supersedes the gap note on a clean
    pass (self-healing; Plane 1 never edits distilled prose).
  - Dirty-guarded batch spawning (durable-content footprint instead of raw
    event counts — pure turn traffic no longer burns a distiller) and digest
    dedupe ("already queued" receipt for in-flight targets). The wiki home
    index now carries a one-line summary per page.

### Changed

- **Storage reads are UTF-8-pinned and cached**: store file reads
  (`load_records`, meta/index, transcript excerpts) force UTF-8 with scrub
  instead of trusting the process external encoding — non-ASCII recall
  queries no longer risk `Encoding::CompatibilityError` on non-UTF-8 Windows
  locales (TR cp1254/cp857). `Store#search`/`list` accept a type ARRAY,
  and parsed records plus search haystacks are memoized behind an
  mtime-validated cache (writes drop it; external edits self-heal). Measured
  123 ms → 14 ms per warm scoped query on a synthetic 1150-row/1 MB store.

- **Silent concurrency via Fiber Scheduler** (`Rubik::Concurrency`): a
  pure-stdlib `Fiber::Scheduler` event loop (`IO.select` + monotonic timer
  heap + self-pipe cross-thread wakeups) with a thread-scoped `silently` /
  `map(enum, concurrency:)` boundary. Plain blocking I/O call sites —
  Net::HTTP, sleep backoffs, Open3 pipe reads/writes, Mutex/CV waits,
  Thread#join — interleave cooperatively on one thread with ZERO changes at
  the call sites (thousands of concurrent ops; I/O concurrency, not CPU
  parallelism). Handles the Ruby 3.3/4.0 scheduler protocol drift
  (`fiber(&blk)` creation handoff, io_read/io_write buffer contracts) and
  Windows realities (no `IO#nonblock=`; `Fiber.blocking`-wrapped
  nonblocking primitives). Escape hatch: `RUBIK_FIBER_SCHEDULER=off`
  degrades every boundary to sequential execution.

- **MCP config boot overlaps server connect phases**:
  `Manager#load_from_config` now runs the slow I/O half (spawn +
  initialize + tools/list) of every configured server concurrently through
  the concurrency boundary while registration and state application stay
  sequential in config order. Boot wall clock goes sum(per-server) →
  max(per-server); one hung server no longer delays the rest. Per-server
  failure isolation, warning text, and tool registration order are
  byte-identical to the sequential path (`RUBIK_FIBER_SCHEDULER=off`
  restores it). Tests can inject fakes via `Manager.new(client_factory:)`.

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

[Unreleased]: https://github.com/ozgurulukir/rubik/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ozgurulukir/rubik/releases/tag/v0.1.0
