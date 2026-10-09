# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/adapter/rust"

# Issue #97 finding 2: the rust runner candidates put `cargo nextest run`
# first and availability checked only the first token ("cargo"), so a machine
# without cargo-nextest selected a runner that exits 101 with no fallback and
# no structured hint. Pins: the one-shot missing-runner fallback to the next
# Discovery candidate, no fallback on genuine test failures, and the
# cargo-plugin remediation in the diagnostic.
class TestAdapterTestRunnerFallback < Minitest::Test
  NEXTFAIL = {
    ok: false, exit_code: 101, stdout: "",
    stderr: "error: no such command: `nextest`\n\nA subcommand was expected",
    output: "error: no such command: `nextest`", duration: 0.1
  }.freeze
  CARGO_PASS = {
    ok: true, exit_code: 0, stdout: "test result: ok. 36 passed", stderr: "",
    output: "test result: ok. 36 passed", duration: 1.0
  }.freeze

  def setup
    @adapter = Rubik::Adapter::RustAdapter.new
  end

  def test_missing_plugin_runner_falls_back_to_next_candidate
    runs = []
    with_runner_stub(["cargo nextest run", "cargo test"],
                     runner: lambda { |cmd|
                       runs << cmd
                       (cmd.start_with?("cargo nextest") ? NEXTFAIL : CARGO_PASS).dup
                     }) do
      res = @adapter.run_tests("/tmp/whatever")
      assert res[:ok], "the fallback run must decide the outcome"
      assert_includes res[:output], "[Test runner fallback]"
      assert_includes res[:output], "cargo test"
      assert_includes res[:output], "test result: ok"
    end
    assert_equal ["cargo nextest run", "cargo test"], runs, "exactly one fallback retry with the next candidate"
  end

  def test_genuine_test_failure_never_triggers_a_fallback
    failure = {
      ok: false, exit_code: 1, stdout: "3 runs, 1 assertions, 1 failures", stderr: "",
      output: "3 runs, 1 assertions, 1 failures", duration: 1.0
    }
    runs = []
    with_runner_stub(["cargo test"], runner: lambda { |cmd|
      runs << cmd
      failure
    }) do
      res = @adapter.run_tests("/tmp/whatever")
      refute res[:ok]
      refute_includes res[:output], "[Test runner fallback]"
    end
    assert_equal ["cargo test"], runs, "a real failure is reported as-is, no retry"
  end

  def test_missing_plugin_without_alternative_reports_structured_remediation
    runs = []
    with_runner_stub(["cargo nextest run"], runner: lambda { |cmd|
      runs << cmd
      NEXTFAIL.dup
    }) do
      res = @adapter.run_tests("/tmp/whatever")
      refute res[:ok]
      assert_equal :missing_binary, res[:diagnostic].category
      assert_includes res[:diagnostic].suggestion, "cargo install cargo-nextest"
      assert_includes res[:diagnostic].suggestion, "cargo test"
    end
    assert_equal ["cargo nextest run"], runs, "no alternative candidate means no retry"
  end

  private

  # Deterministic adapter environment: the adapter itself is "installed",
  # every candidate passes the (first-token-only, hence broken-for-plugins)
  # availability probe, and the candidate list is pinned so the fallback
  # ladder is predictable. Discovery returns the same list in the same order.
  def with_runner_stub(candidates, runner:, &)
    Rubik::Adapter::ProcessRunner.stub(:run, ->(cmd, **_kw) { runner.call(cmd) }) do
      @adapter.stub(:available?, true) do
        Rubik::Runtime::Discovery.stub(:binary_available?, ->(_cmd, **_kw) { true }) do
          Rubik::Runtime::Discovery.stub(:test_runner_candidates, ->(*_a, **_kw) { candidates.dup }) do
            Rubik::Runtime::Discovery.stub(:discover_test_runners, ->(*_a, **_kw) { candidates.dup }, &)
          end
        end
      end
    end
  end
end
