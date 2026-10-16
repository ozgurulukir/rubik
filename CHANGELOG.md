# Changelog

All notable changes to Rubik are documented here. 0.1.0 is the first packaged
release; its section is the thematic roll-up of the pre-gem history (485
commits, 2026-08-23 → 2026-10-09, see `git log`).

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

Nothing yet.

## [0.2.0] - 2026-10-16

The first minor of the 0.2 era is a hardening minor: a reproducible
runtime validation harness with capacity proofs, a fail-closed
security posture across the command guard, transactional plugin
reload, and failure reporting that names what actually happened.

### Added

- **Reproducible runtime validation harness (#160, closes #151):**
  `bundle exec ruby dev/validate_runtime_capacity.rb` runs without
  provider credentials and writes a dated report — environment, seed,
  fixture sizes, raw metrics, resource checkpoints, thresholds and
  verdicts. Nine lifecycle families soak for the configured 1,000
  epochs (real subprocess shutdown, failed JSON-RPC handshake,
  crash/recovery); two single-run probes cover in-flight
  disable/re-enable and known-descendant cleanup. Missing
  capabilities report INCONCLUSIVE (exit 2), failed thresholds FAIL
  (exit 1). The soak also surfaced production fixes that ship here:
  nonblocking IO hooks keep their return codes and minimum lengths,
  select wakes only fibers interested in each readiness direction,
  queued wakeups carry their park generation so stale events cannot
  resume a later operation, and a crashed MCP pipe closes with the
  process tree terminated before stdin (recursive descendant
  discovery on Unix).

### Fixed

- **Command classifier fails closed (#143):** a classifier crash or a
  partial tree-sitter parse no longer downgrades to the catastrophic
  regex gate — both raise structured blocks (`:classifier_error` /
  `:parse_ambiguous`) with the crash cause audited; the catastrophic
  regex keeps first refusal for precise destructive-shape reasons and
  the operator allowlist stays the only valve. SECURITY.md's
  fallback residual is updated to the fail-closed policy.
- **Plugins verify whole packages and reload transactionally
  (#144):** directory-plugin manifests hash every regular file under
  the package root (additions, deletions and modifications audited;
  symlinks and special files are containment violations); legacy
  entry-file-only manifests require explicit re-consent; and
  `reload_plugin` discovers, verifies and prepares the replacement
  before touching the running version — a failed reload leaves the
  old version running instead of claiming success.
- **Runtime repair verifies before promoting (#145):** LSP candidates
  must complete an isolated initialize handshake and other targets
  run bounded argv probes that preserve the proposed arguments; live
  promotion records inverses and unwinds the transaction on failure,
  rolling back to the previously configured client (with an honest
  report if restoration itself fails).
- **Buffer apply names its authority and its partial truth (#146):**
  `buffer.model_can_apply` is honored in every registry rebuild
  (branch workspaces included); a multi-file `apply!` failure raises
  a structured `ApplyFailedError` carrying what reached disk, what
  failed and what a retry still writes; retry is incremental and the
  tool and `!apply` render one shared failure vocabulary — a partial
  apply is never reported as "Successfully applied".
- **C++ extraction sees classes and reports parse status (#147):**
  the shared C/C++ walker no longer crashes on unknown declarator
  shapes — class/struct/union symbols, namespaces, in-class members
  (definitions, declarations, ctors, operators) and templates are
  recorded; the extractor returns a structured status
  (`:ok`/`:partial`/`:failed`/`:unavailable`) and a failed reindex
  keeps the file's previously indexed symbols instead of silently
  deleting them.
- **Plugin reinstallation survives symlinked ancestors (#158):**
  resolved-source × lexical-destination comparison could delete the
  source before copying it; file identity now detects an
  already-installed directory.
- **Unit tests are isolated from external network and terminal env
  (#148):** handshake-deadline assertions no longer depend on cleanup
  timing.

### Changed

- **CI measures the platform matrix (#158):** four jobs — Linux Ruby
  3.4/4.0, macOS Ruby 4.0, Windows Ruby 4.0 — each install the gem
  into an isolated GEM_HOME, run CLI/require smoke and all three
  suite loaders, and publish evidence artifacts; README and TESTING
  replace the universal green-run guarantee with commit-specific
  evidence.
- **Docs calibrate absolute guarantees (#159):** README, SECURITY,
  CONFIG, PLUGINS and SELF_EVOLUTION swap "zero-risk"-style claims
  for concrete preconditions and bounded behavior (the full buffer
  review gate is `auto_apply: manual` + `model_can_apply: false`).
- **Cold scan gets cheaper (#161):** integer-micros mtime math, a
  backslash translation that runs only when backslashes exist, and
  in-place dedup; the fast scan keeps bracket-class ignores intact.

## [0.1.6] - 2026-10-15

The execution-contract release: subagent runs become first-class,
inspectable objects — retained results, one canonical transcript, an
append-only journal, cancellable task trees — and the REPL learns to
hand a just-entered prompt back for editing instead of firing it.

### Added

- **Execution contracts and task supervision (#136):** completed
  subagent results are retained with paginated retrieval instead of
  truncated previews; live and persisted transcript reads collapse
  into one canonical reader with snapshot tokens; an append-only
  execution journal records each step (redacted before clipping);
  foreground cancellation propagates through owned descendants while
  detached tokens stay uncancellable; the runtime reports current
  operations with actionable wait states; and command exit codes plus
  metadata survive both dispatch paths. Closes #122–#127 and #129.
- **Esc returns pending prompts to editing (#141):** a configurable
  admission window (`ui.prompt_grace_window_ms`, default 1000, 0 to
  disable) lets Esc hand the complete prompt back to Reline before
  any task, model call or turn recording starts; Ctrl+C cancels the
  pending submission, reactive wake-ups cannot inject Enter into the
  restored editor, and bang/exit commands plus programmatic input
  keep direct execution.

### Changed

- **Redactor skips irrelevant static passes, keeps replacement order
  (#142):** a precompiled union regex skips the eight static
  credential passes when the input holds only assignments or URL
  credentials, and the original replacement order is preserved —
  masking a preceding token in one combined pass can create the word
  boundary that exposes an adjacent bearer credential (regression
  tested over 10,000 differential cases).
- **Truncator fast path ~62% (#138):** `Truncator.truncate`
  short-circuits untruncated texts with zero line allocations, and
  custom truncator separators are preserved.
- **Fuzzy matcher prunes window evaluations (#140):**
  `find_closest_subsequence` pre-computes target line membership and
  a prefix-sum upper bound before running LCS calls.

## [0.1.5] - 2026-10-13

A dependency-floor release: the reactive wakeup contract moves into
the gemspec, and the triaged open-PR backlog lands as reviewed test
hardening.

### Fixed

- **Reactive wakeup requires Reline >= 0.7:** the idle-prompt kick
  (`TerminalGuard#safe_wakeup!` → `Reline.ungetc`) only reaches a reader
  already blocked in Reline's getc loop on 0.7.0+, whose ANSI gate re-checks
  the ungetc buffer on every poll iteration; on 0.6.x the injected Enter
  stranded until the next keystroke (maestro "wakes only when I press a
  key"). `rubik.gemspec` now floors `reline >= 0.7`, the gemspec-integrity
  test pins the floor (0.7.0 satisfies, 0.6.3 does not), and an integration
  test pins the contract against the real gate under a PTY.

### Changed

- **Triaged open-PR batch lands (#110–#119):** SkillTool branch pins,
  real-supervisor error paths, and ast/symbols/storage coverage harden
  the suite; ContextBuilder builds its prompt parts with `filter_map`
  (parity proven, golden-prompt pinned).

## [0.1.4] - 2026-10-13

The autonomy release: `!goal` becomes resumable across transient
provider outages, and the maestro gets a leaner, more proactive
contract for driving subagents unattended.

### Added

- **Resumable `!goal` (#107):** transient provider transport failures
  (exhausted connect/DNS retries, exhausted 5xx, HTTP 429) suspend the
  goal instead of failing terminally — the loop, its counters and the
  Σ ledger survive. `!goal resume` continues in-process (same Loop
  instance) or cross-process (Σ-stamp rehydration with an honest
  continuity notice); schema-corrupt Σ bodies are refused at
  `Ledger.load` and stale suspend stamps are stripped from rehydrated
  links. Issue #106 Faz 1+2a (Faz 2b deferred).
- **Lean maestro autonomy:** subagents carry a 4-part final-report
  contract (research/coder), doctrine gains proactive budget guidance
  and predecessor-transcript chaining, `agent.goal_auto_continue_limit`
  grants unattended `!goal` runs up to 20 extra auto-extensions with an
  honest `auto=true` notice, and `!goal --steps N` sizes the step
  budget up front with usage-error validation.

### Changed

- **Scanner orders paths via NUL translation:** `order_like_walker`
  keys paths with `String#tr("/", "\0")` instead of `Array#split` —
  order-equivalent with fewer allocations.

## [0.1.3] - 2026-10-12

A robustness release straight from a field incident: the `!goal` loop
no longer strands state when the provider fails mid-goal, and the
redactor gets measurably cheaper on secret-free input.

### Fixed

- **`!goal` survives provider errors (#105):** an api read-timeout
  `ClientError` escaped the goal handler (only `Interrupt` was
  rescued), leaving `GoalState` stuck in `:running`, the ledger
  unfinalized and the session silent while the batch spinner kept
  cycling with the cursor hidden. One `fail_goal` channel now serves
  the `:error` return plus `ClientError`/`StandardError` rescues
  (`Interrupt` still means `:stopped`); both command-dispatch branches
  kill the leaked spinner instead of masking the real failure; and
  goal steps record their tool calls to the session like free-text
  turns.

### Changed

- **Redactor short-circuits secret-free lines (#104):** pre-compiled
  quick-check constants plus a trigger check before scrubbing cut
  allocations by ~68% on a mixed redact workload (172,940 -> 54,864
  objects per 20x2000-line pass) with byte-for-byte output parity;
  invalid-UTF-8 input stays total (masked/scrubbed) instead of raising
  ArgumentError.

## [0.1.2] - 2026-10-11


The Anthropic correctness release: the provider now speaks the modern
extended-thinking contract, so pinning any current Claude model works
instead of failing with HTTP 400.

### Fixed

- **Anthropic provider speaks the modern thinking contract:** the
  default model pin moves from the stale `claude-3-7-sonnet-20250219`
  to `claude-sonnet-5-5`, and the extended-thinking payload follows the
  model line ? 4.6+ and the 5.x/Fable models get the adaptive form
  (`thinking: {type: "adaptive"}` with an `output_config` effort),
  3-7-sonnet through the 4.5 line keep the `budget_tokens` math, and
  pre-thinking lines get nothing attached. 0.1.1 sent the legacy form
  to every Anthropic model, which Claude 4.7+ rejects with HTTP 400.

### Changed

- Extended thinking auto-enables on every thinking-capable Anthropic
  model line (previously only claude-3-7-sonnet); `thinking: false`
  still disables it everywhere and `thinking_budget_ratio` shapes the
  legacy form only. Requests that carry thinking still force
  `temperature` to 1.0.
- README quick start documents the native Anthropic provider
  (`ANTHROPIC_API_KEY` + `!model anthropic/<model>`) next to the
  OpenAI-compatible example.

## [0.1.1] - 2026-10-11


The Linux surface release: CI now proves Linux on Ruby 3.4 and 4.0
(`linux-test` is a required check), and the host seams that surface
exposed are fixed. Ships the structured goal ledger, the default-on
context pruner, and the vakanüvis recall/write hardening below.

### Fixed

- **Fiber Scheduler: Net timeouts no longer fire watchdogs into
  unrelated frames** (#102): Net::HTTP implemented its open/read
  deadlines with the Timeout module — an async `Thread#raise` into the
  originating thread. Under the scheduler that thread hops between
  parked fibers, so an expired deadline landed in whichever frame was
  running (observed on Linux killing the test reporter's stdout write
  and `safe_select`'s `IO.select` itself). Deadlines are now
  fiber-native: EventLoop timers drive them, and the timeout never
  leaves the owning fiber.
- **LSP diagnostics keys normalize by path shape, not host OS** (#103):
  a windows-drive root plus `file:///C:/...` uris and backslash lookups
  resolved differently on a linux host; drive semantics now follow the
  path's own shape.
- **Allowlist `.exe` alias matches lexically** (#103): the windows
  executable-extension rule engaged through a second host seam the
  platform stub did not cover; the alias is decided inside the matcher.
- **Task manager fixtures are shell-safe and poll for readiness**
  (#103): fixed sleeps raced linux process startup, so a kill arrived
  after the task had already FAILED.
- **REPL wake-loop**: subagent notices stranded at turn end re-armed the
  reactive wake (synthetic Enter), so a steady subagent stream chained
  autonomous maestro turns forever — the prompt never returned and the cycle
  survived Ctrl+C, because the interrupted turn's own ensure block re-armed
  the wake. Settlement invariant: an autonomous notice turn never spawns
  another one, and an interrupted turn settles the wake debt; the
  model-channel no-loss delivery is unchanged.

### Added

- **Vakanüvis recall + write hardening** (issues #99/#100): `storage put`
  now rejects non-string tags instead of silently stringifying booleans
  into tag lists; search folds queries and haystacks with a Turkish-aware
  I-class rule (ı/İ now match ASCII I text both ways) and ranks matches
  with a deterministic field-tier bonus (title > tags > body, BM25 still
  primary); an empty keyword-AND recall degrades honestly — top-3
  OR-relaxed fallback matches plus a matching-transcript count hint;
  `record` accepts first-class `tags` and deterministically auto-repairs
  a missing `Keywords:` line; `forget` retires note refs (annal.*)
  besides memory cards; digest compiles supersede byte-identical or
  same-title duplicate pages instead of opening twins; a manual wiki
  delete rebuilds the home index immediately; and two new chronicler
  actions — `topics` (cold-start orientation over recorded cards) and
  `digest_status` (queued vs in-flight digest visibility).

- **Structured goal ledger** (`orchestrator/goal_ledger/`, `goal.ledger.*`,
  default ON — SKILL.state adaptation): the `!goal` loop now keeps a
  rev-guarded ΔΣ state ledger (objective, tasks, findings, decisions,
  open questions, environment notes) that the maestro patches through the
  root-only `update_goal_ledger` tool (RFC 6902 subset; classified
  `syntax/schema/conflict` feedback with a bounded retry budget). The
  current Σ is pinned through every compaction tier and re-injected each
  step; every accepted revision appends a storage row (`goal-ledger`
  ref). Re-verification (`goal.ledger.verify`): declarative FS verify
  specs are re-checked at step boundaries — failures flip tasks to
  `stale` via an internal rev-bumping mutation (a stale-rev `:conflict`
  is the drift signal) and ride a silent `:ledger_drift` event plus a
  bounded drift note. Observation projection
  (`goal.ledger.observe_projection`): at compaction time, banked tool
  results get per-row `<absorbed_into_ledger>` tombstones (rows are
  never dropped; the last `observe_window` turns stay raw). All three
  knobs ship ON with explicit opt-out; `goal.*` config is operator-only.

- **Context pruner** (`repl/pruner/`, via `subagents.pruner.*` — shipped
  DEFAULT OFF on 2026-10-09, then enabled by DEFAULT on 2026-10-10, see
  Changed below):
  a semi-deterministic cleaner for the ROOT (maestro) conversation window,
  modeled on the Vakanüvis two-plane design. An LLM "Context Pruner"
  subagent proposes a keep/drop/summarize plan from a deterministic unit
  snapshot; the harness validates it against strict invariants (goal
  pinning, tool-use pairing, head/tail bands, target token budget) and
  applies it atomically at the next turn boundary — never mid-turn, never
  from a background thread. Surfaces: the `prune_context` tool
  (root-only, coeffect-gated, invisible while the knob is off), the
  `!prune [now|status]` command, auto-scheduling on `:turn_finished`
  gated by `trigger_ratio`/`min_turns_between`. The deterministic
  compaction stack is unchanged and remains the safety net; subagent
  pruning stays fully deterministic and untouched.

### Changed

- **The root window pruner is enabled by default** (`subagents.pruner.enabled`
  `false` → `true`, 2026-10-10 user decision). Every root session now boots the
  pruner harness: the `prune_context` tool and `!prune` command are on, and the
  LLM pruner auto-fires at `trigger_ratio` once the window estimate crosses it
  (budget still bounded by `max_steps`/`min_turns_between`; the deterministic
  compaction stack remains the safety net and subagent channels stay untouched).
  The knob remains as an explicit opt-out kill-switch
  (`subagents.pruner.enabled: false`); the `RUBIK_TEST=1` suite armor is
  unchanged, so scripted tests keep the pruner unbound unless
  `RUBIK_PRUNER_FORCE=1`.

- **Subagent transcript health package**: the durable subagent transcript
  is now an operational log, not a verbatim history dump. (1) The runtime-
  assembled system prompt (history row 1) serializes as a meta stub —
  `[assembled system prompt omitted] prompt_sha256=<first 16 hex>` — for
  builtin archetypes, whose prompts are reconstructible from defaults;
  custom types (`synthesize_tool`) and caller-provided `system_prompt:` keep
  the verbatim copy, since they are the single record anywhere. A frozen
  prompt blob was a config+version derivative with neither recorded;
  the provenance hash makes it verifiable and drift-detectable instead.
  (2) Redaction parity with root session logs: every durable row passes the
  same `Rubik::Security::Redactor` masker (text patterns + secret-shaped
  keys), so a secret echoed in tool output or args no longer lands raw in
  the storage-absorbed transcript; in-memory history stays raw for provider
  wire fidelity. (3) Transcript index entities are task+result centric
  instead of "first 40 JSONL lines": system-prompt boilerplate no longer
  pollutes the BM25 corpus and the final result is now searchable ("which
  subagent reported red?"); failed instances still get a body (task + state
  line) and the upsert/dedupe/canonical-link contract is unchanged.

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
