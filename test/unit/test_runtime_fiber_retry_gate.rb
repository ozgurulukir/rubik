# frozen_string_literal: true

require_relative "../test_helper"

# Pins for the failed-fiber retry gate (review 2026-09-17, Finding 3 +
# fresh-eye diff review R1/R2/R3). Manager#attempt_failed_retry backs off
# exponentially, hard-stops after MAX_FIBER_RETRIES with a one-shot warn, and
# the bookkeeping is cleared on success, explicit re-registration,
# unregister_component and dispose!.
#
# Determinism: the registration-time failure is the factory's FIRST run, not a
# retry — the bookkeeping only appears after the first reconcile retry (whose
# delay is 0). Later attempts are either backdated (elapsed >> delay, no sleep
# ever fires) or captured via @manager.stub(:sleep) — the suite never really
# waits.
class TestRuntimeFiberRetryGate < Minitest::Test
  MAX = Rubik::Runtime::Manager::MAX_FIBER_RETRIES
  BASE = Rubik::Runtime::Manager::RETRY_BACKOFF_BASE_S

  def setup
    @ctx = Rubik::Runtime::Context.new
    @manager = Rubik::Runtime::Manager.new(@ctx)
  end

  def teardown
    @manager.dispose! unless @ctx.disposed?
  end

  def book_for(name)
    @manager.instance_variable_get(:@retry_bookkeeping)[name]
  end

  def all_bookkeeping
    @manager.instance_variable_get(:@retry_bookkeeping)
  end

  # Backdate the last attempt so elapsed >> any delay: the gate advances
  # without ever calling Kernel#sleep, keeping the suite deterministic.
  def backdate!(book, seconds = 60)
    book[:last_attempt_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - seconds
  end

  # ── R1: hard stop ───────────────────────────────────────────────────

  def test_failed_fiber_stops_retrying_after_max_attempts
    runs = 0
    @manager.register_component("hopeless") do
      runs += 1
      raise "factory always fails"
    end

    assert_equal :failed, @manager.fibers["hopeless"].state
    assert_nil book_for("hopeless"), "registration-time failure is not a retry attempt yet"

    @manager.reconcile_all # retry attempt #1 (delay 0 — no prior attempt)
    book = book_for("hopeless")
    assert_equal 1, book[:attempts]

    (MAX - book[:attempts]).times do
      backdate!(book)
      @manager.reconcile_all
    end
    assert_equal MAX, book[:attempts]

    _out, _err = capture_io do
      (MAX + 3).times { @manager.reconcile_all }
    end
    assert_equal 1 + MAX, runs, "factory runs once at registration + MAX retries, never more"
    assert_equal :failed, @manager.fibers["hopeless"].state
  end

  def test_backoff_delay_doubles_between_attempts
    @manager.register_component("backoff") { raise "boom" }
    sleeps = []

    # Real elapsed time is ~0, so each reconcile sleeps its full backoff —
    # captured via stub instead of actually waiting.
    @manager.stub(:sleep, ->(s) { sleeps << s }) do
      3.times { @manager.reconcile_all }
    end

    assert_equal 2, sleeps.size, "attempt #1 has no delay; #2 and #3 sleep"
    assert_in_delta BASE * 2**1, sleeps[0], 0.01, "attempt #2 waits base * 2^1"
    assert_in_delta BASE * 2**2, sleeps[1], 0.01, "attempt #3 waits base * 2^2"
  end

  def test_retry_runs_once_backoff_elapsed_and_success_clears_budget
    runs = 0
    @manager.register_component("heals") do
      runs += 1
      raise "fails twice" if runs <= 2

      "ok"
    end
    assert_equal :failed, @manager.fibers["heals"].state
    assert_empty all_bookkeeping, "registration failure is the factory's first run, not a retry"

    @manager.reconcile_all # retry attempt #1: no delay yet, no sleep
    book = book_for("heals")
    assert_equal 1, book[:attempts]
    assert_equal 2, runs
    assert_equal :failed, @manager.fibers["heals"].state

    backdate!(book)
    @manager.reconcile_all

    assert_equal 3, runs, "backoff elapsed -> exactly one retry, no artificial delay"
    assert_equal :active, @manager.fibers["heals"].state
    assert_empty all_bookkeeping, "successful activation must clear the retry bookkeeping"
  end

  # ── R3: exhaustion warns exactly once ───────────────────────────────

  def test_retry_budget_exhaustion_warns_exactly_once
    @manager.register_component("hopeless") { raise "boom" }
    MAX.times do |i|
      backdate!(book_for("hopeless")) if i.positive?
      @manager.reconcile_all
    end
    book = book_for("hopeless")
    assert_equal MAX, book[:attempts]

    _out, err = capture_io do
      3.times { @manager.reconcile_all }
    end
    warnings = err.scan(/\[Runtime\] fiber 'hopeless' retry budget exhausted/)
    assert_equal 1, warnings.size, "exhaustion must warn once, not once per reconcile"
    assert_includes err, "MAX_FIBER_RETRIES"
    assert_includes err, "boom", "warn must carry the fiber's last error"
  end

  # ── Budget resets ───────────────────────────────────────────────────

  def test_explicit_re_registration_resets_retry_budget
    runs = 0
    @manager.register_component("reborn") do
      runs += 1
      raise "broken v#{runs}"
    end
    @manager.reconcile_all
    assert_equal 1, book_for("reborn")[:attempts]

    @manager.register_component("reborn") { "fixed" }

    assert_empty all_bookkeeping, "register_fiber must reset the budget so a fixed factory is honored immediately"
    assert_equal :active, @manager.fibers["reborn"].state
  end

  def test_swap_component_grants_fresh_retry_budget
    @manager.register_component("swapped") { raise "v1 broken" }
    @manager.reconcile_all
    assert all_bookkeeping.key?("swapped")

    @manager.swap_component("swapped") { "fixed" }

    refute all_bookkeeping.key?("swapped"), "swap must not inherit the old fiber's retry debt"
    assert_equal :active, @manager.fibers["swapped"].state
  end

  # ── R2: bookkeeping hygiene ─────────────────────────────────────────

  def test_unregister_component_removes_retry_bookkeeping_entry
    @manager.register_component("gone") { raise "boom" }
    @manager.reconcile_all
    assert all_bookkeeping.key?("gone")

    @manager.unregister_component("gone")

    assert_empty all_bookkeeping, "disposed fibers must not leak their retry budget (§6 zero-restart)"
  end

  def test_dispose_clears_all_retry_bookkeeping
    3.times { |i| @manager.register_component("zombie_#{i}") { raise "boom" } }
    @manager.reconcile_all # first retry attempt for each failed fiber
    refute_empty all_bookkeeping

    @manager.dispose!

    assert_empty all_bookkeeping, "dispose! must drop all bookkeeping — nothing outlives the manager"
  end

  # ── Sanity: pending fibers never consume retry budget ───────────────

  def test_pending_fibers_do_not_accrue_retry_bookkeeping
    @manager.register_component("waits", inject: ["missing"]) { "ok" }

    2.times { @manager.reconcile_all }

    assert_empty all_bookkeeping, "only :failed fibers consume retry budget"
    assert_equal :pending, @manager.fibers["waits"].state
  end
end
