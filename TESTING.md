# Testing Guide

How to run, name, and write tests in this repository. The suite is Minitest
(`~> 5.20`) driven by Rake; always run it through bundler (see the shield in
`test/test_helper.rb` — Ruby ≥ 4.0's default minitest 6 breaks the suite).

## Running tests

| Command | What it does |
| --- | --- |
| `bundle exec rake test` | Full suite (unit + integration), serial loader — the reference run |
| `bundle exec rake` | Same full suite via single-process loaders (`test:unit_once` + `test:integration`) |
| `bundle exec rake test:fast` | Unit tests minus the 16 measured slow files (≈2640 runs, ~6 min) |
| `bundle exec rake test:slow` | Only the isolated slow unit files |
| `bundle exec rake test:unit` / `test:integration` | One directory tree only |
| `bundle exec rake test:parallel[4]` | N parallel worker processes; **N=4 is the only measured 0-failure config** on the dev machine (6/8 trip timing-fragile tests) |
| `bundle exec rake test:profile` | Per-file wall-time profile → `_report/unit_profile.csv`; refresh after touching sleep/thread-heavy tests, then update `SLOW_UNIT_FILES` in the `Rakefile` |
| `bundle exec rake test:badge` | Runs the full suite and rewrites the README test badge (`tests-<N> runs`) from the real Minitest summaries; refuses a red suite (`dev/update_test_badge.rb`) |
| `bundle exec ruby -Ilib -Itest test/unit/test_x.rb` | Single file, fastest feedback loop |

Rules of thumb: target one file while iterating; run `rake test:fast` before
committing; run the full `rake test` for refactor gates.

## Naming conventions (G15)

**Files** are named after the *subject under test*, not the behavior:
`test_<subject>.rb`. Use the singular when the subject is one thing
(`test_activity_log.rb`), the plural only when the subject *is* inherently a
collection or an uncountable mass noun:

- Collections (plural is correct): `test_sandbox_drivers`,
  `test_llm_stream_providers`, `test_repl_hooks`, `test_ui_approvals`.
- Mass nouns (ending in `-s` is not a plural): `test_lsp_robustness`,
  `test_exec_tools_diagnostics`, `test_synthesis`, `test_event_bus`.
- Config-key mirrors keep the key's own spelling: `test_allowed_external_dirs`.
- Subject-aspect compounds (`test_<subject>_<aspect>.rb`) are fine when the
  aspect is the file's reason to exist — the error-path family:
  `test_lsp_client_error_paths`, `test_buffer_snapshot_failures`. Subject
  first, aspect second; never a bare behavior name.

A 2026-09-29 audit of the then-28 `s`-ending unit files and a 2026-09-30
re-audit of the 7 that landed since both found collection, mass-noun,
key-mirror, or subject-aspect names only — no renames warranted. The rule
above is the standard for new files; do not mechanically de-pluralize
existing names.

**Test methods** state behavior, not mechanics: prefer
`test_agent_extends_budget_when_user_approves` over `test_extend_budget`.
Assert outcomes (state on disk, return contracts, user-visible effects), not
incidental counts — e.g. bound a loop's `result[:steps]` to its budget instead
of an exact turn count (`test/integration/test_e2e_agent_workflow.rb`).

## Templates

### Unit test

```ruby
# frozen_string_literal: true

require_relative "../test_helper"

class TestSomething < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rubik_something")
  end

  def teardown
    remove_temp_dir(@dir)  # Windows-safe removal (EACCES retry built in)
  end

  def test_subject_behaves_expected_way_under_condition
    subject = Rubik::Subject.new(root_dir: @dir)

    result = subject.call

    assert result[:ok], "expected ok result"
  end
end
```

### Agent-loop integration test

Use the shared harness (`test/support/scripted_agent_harness.rb`) — it wires
config, buffer manager, context index, and the default tool registry, and
replays scripted assistant turns through a fake provider:

```ruby
def test_agent_fixes_file_bug_e2e
  responses = [
    { role: "assistant", content: '{"tool": "read_file", "args": {"path": "lib/x.rb"}}' },
    { role: "assistant", content: '{"tool": "finish", "args": {"message": "done"}}' }
  ]

  harness = Rubik::TestSupport::ScriptedAgentHarness.build_agent_loop(
    root_dir: @dir,
    responses: responses,
    files: { "lib/x.rb" => "class X\nend\n" }
  )

  result = harness.agent_loop.run("fix lib/x.rb")

  assert result[:ok]
  assert_operator result[:steps], :<=, harness.agent_loop.max_steps
end
```

If the script runs dry the harness returns a `finish` call, so under-scripted
tests fail on their assertions, not on a nil deref.

## Known flakes & policy (G18)

- **Open3 `IOError: stream closed in another thread`** (Ruby ≤ 3.4): cosmetic,
  0–2 per run, does not affect assertions. Deliberately *not* filtered — see
  the rationale in `test/test_helper.rb`. Fixed upstream in Ruby 3.5+.
- **Windows temp-dir removal** (`Errno::EACCES` during teardown): use
  `remove_temp_dir` (retry helper in `test/test_helper.rb`), never raw
  `FileUtils.remove_entry`, in teardown.
- **Timing-fragile tests** (sleep/thread-heavy) are quarantined in
  `SLOW_UNIT_FILES` rather than deleted; they still run in `rake test`,
  `test:slow`, and CI-parity full runs.
- **Probe a suspect**: `bundle exec ruby dev/rerun_flaky.rb
  test/unit/test_x.rb 5` re-runs one file in fresh processes, reports the
  pass count and wall-time spread, and exits nonzero on any failure. A file
  that ever fails gets `test:profile`-d and either fixed at the race site or
  quarantined; flakiness is never papered over with retries inside the
  assertion itself.

## Benchmarks (G14)

`bundle exec rake bench` runs the aggregate benchmark report. Focused load
scripts live in `dev/`: `bench_ast_index.rb` (semantic-index build + lookup
over the whole tree — the cold-build load test), `bench_ast_extractors.rb`
(per-file extraction cost decomposition), `bench_context_scan.rb`,
`bench_native_tools.rb`, `bench_rg_flag_cost.rb`, and
`benchmark/tool_latency.rb`. The persistent AST cache additionally carries an
in-suite load guard (`test_ast_persistent_cache.rb` high-volume test); treat
that test's wall-time assertion as machine-sensitive — rerun it in isolation
(`dev/rerun_flaky.rb`) before believing a failure under parallel load.

## Lifecycle soak (G26)

The Ω zero-restart audit (AGENTS.md §6): drive `Context`/`ComponentFiber`
through N lifecycle epochs and verify the accumulator returns to its
baseline with every inverse executed exactly once. Four families — context
epochs (extend/dispose), service epochs (provide swap/unprovide), fiber
activation cycles, activation-failure rollback — in two forms:

- **Guard (suite):** `test/unit/test_runtime_zero_restart_soak.rb` pins the
  four contracts at suite-friendly epoch counts; runs in every fast pass.
- **Probe (scale):** `bundle exec ruby dev/soak_lifecycle.rb [epochs=1000]`
  runs the same families at soak scale with per-family wall time and exits
  nonzero on any leak. Run it after any change under `lib/rubik/runtime/`
  (Context, ComponentFiber, Manager) or when adding a new component class.

## Coverage (G17) — wired to CI

Coverage instrumentation exists behind `RUBIK_COVERAGE=1`: `simplecov` sits in
the Gemfile's dev/test group (`require: false`), and `test/test_helper.rb`
starts it before any rubik code loads. Local runs without the env var are
unchanged.

`.github/workflows/ci.yml` runs rubocop (lib/) and the FULL suite —
`test:fast`, then the `SLOW_UNIT_FILES` in `test:slow`, then
`test:integration` — with coverage enabled, publishing the HTML/JSON report
under the `coverage-report` artifact. This closes the blind spot that let
`test_mcp_manager_composability` regress for two days: nothing regular ever
ran the slow-excluded files.

Each CI step reports under its own simplecov command name
(`RUBIK_COVERAGE_SUITE` = fast/slow/integration): with one shared name every
suite's exit overwrote the previous suite's entry in `.resultset.json`, so
the artifact only ever described the last suite that ran. Distinct names let
SimpleCov merge all three suites into the final report. For local gap
analysis, snapshot `coverage/.resultset.json` after each suite and union the
snapshots yourself (one suite per `RUBIK_COVERAGE_SUITE` value).

The CI lint step is a bare `bundle exec rubocop` — repo-wide (534 files:
`lib/`, `test/`, Rakefile, benchmark), zero offenses as of the 2026-09-30
pass that cleared the test tree's old style debt (~57 offenses, mostly
autocorrectable). There is no separate scope to maintain: any new offense
anywhere fails the push CI, so the debt cannot quietly regrow.
