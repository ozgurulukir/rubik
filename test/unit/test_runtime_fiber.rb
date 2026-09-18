# frozen_string_literal: true

require_relative "../test_helper"

class TestRuntimeFiber < Minitest::Test
  def setup
    @ctx = Rubik::Runtime::Context.new
  end

  def teardown
    @ctx.dispose unless @ctx.disposed?
  end

  # ── Initialization and States ──────────────────────────────────────

  def test_initial_state_is_pending
    fiber = Rubik::Runtime::Fiber.new(name: "test_fiber", inject: ["logger"])

    assert_equal "test_fiber", fiber.name
    assert_equal ["logger"], fiber.inject
    assert_equal :pending, fiber.state
    assert_nil fiber.instance
    assert_nil fiber.sub_context
    assert_nil fiber.last_error
  end

  # ── Satisfiability ─────────────────────────────────────────────────

  def test_satisfiable_when_all_injected_dependencies_present
    fiber = Rubik::Runtime::Fiber.new(name: "worker", inject: [:database, :logger])

    refute fiber.satisfiable?(@ctx)

    @ctx.provide("database", { connected: true })
    refute fiber.satisfiable?(@ctx)

    @ctx.provide("logger", { level: :debug })
    assert fiber.satisfiable?(@ctx)
  end

  def test_satisfiable_with_empty_inject_is_always_true
    fiber = Rubik::Runtime::Fiber.new(name: "standalone", inject: [])
    assert fiber.satisfiable?(@ctx)
  end

  # ── Activation & Factory ───────────────────────────────────────────

  def test_activation_executes_factory_and_transitions_to_active
    cleaned = false
    fiber = Rubik::Runtime::Fiber.new(name: "service", inject: ["config"]) do |sub_ctx, cfg|
      sub_ctx.on_dispose { cleaned = true }
      { running: true, config: cfg }
    end

    @ctx.provide("config", { port: 8080 })
    activated = fiber.activate!(@ctx)

    assert activated
    assert_equal :active, fiber.state
    assert_equal({ running: true, config: {} }, fiber.instance)
    assert_instance_of Rubik::Runtime::Context, fiber.sub_context
    refute cleaned
  end

  def test_activation_fails_when_unsatisfied
    fiber = Rubik::Runtime::Fiber.new(name: "service", inject: ["missing_dep"]) { "instance" }

    activated = fiber.activate!(@ctx)

    refute activated
    assert_equal :pending, fiber.state
    assert_nil fiber.instance
  end

  def test_activate_is_idempotent_when_already_active
    calls = 0
    fiber = Rubik::Runtime::Fiber.new(name: "counter", inject: []) do
      calls += 1
      "instance_#{calls}"
    end

    assert fiber.activate!(@ctx)
    assert_equal "instance_1", fiber.instance

    # Second call does not re-run factory
    assert fiber.activate!(@ctx)
    assert_equal "instance_1", fiber.instance
    assert_equal 1, calls
  end

  # ── Atomic Rollback on Error ───────────────────────────────────────

  def test_activation_error_performs_atomic_rollback_to_failed_state
    cleaned = false
    fiber = Rubik::Runtime::Fiber.new(name: "broken", inject: []) do |sub_ctx|
      sub_ctx.on_dispose { cleaned = true }
      raise "initialization crash"
    end

    activated = fiber.activate!(@ctx)

    refute activated
    assert_equal :failed, fiber.state
    assert_nil fiber.instance
    assert_nil fiber.sub_context
    assert_instance_of RuntimeError, fiber.last_error
    assert_equal "initialization crash", fiber.last_error.message
    # Partial inverse must have been executed immediately
    assert cleaned
  end

  # ── Deactivation & Inverses ────────────────────────────────────────

  def test_deactivation_runs_inverses_and_transitions_to_pending
    cleaned = false
    fiber = Rubik::Runtime::Fiber.new(name: "transient", inject: []) do |sub_ctx|
      sub_ctx.on_dispose { cleaned = true }
      "worker_running"
    end

    fiber.activate!(@ctx)
    assert_equal :active, fiber.state

    deactivated = fiber.deactivate!
    assert deactivated
    assert_equal :pending, fiber.state
    assert_nil fiber.instance
    assert_nil fiber.sub_context
    assert cleaned
  end

  def test_deactivate_when_not_active_returns_false
    fiber = Rubik::Runtime::Fiber.new(name: "idle", inject: [])
    refute fiber.deactivate!
    assert_equal :pending, fiber.state
  end

  # ── Reactivate & Dispose ───────────────────────────────────────────

  def test_reactivate_cycles_through_deactivation_and_activation
    events = []
    fiber = Rubik::Runtime::Fiber.new(name: "cycler", inject: []) do |sub_ctx|
      events << :created
      sub_ctx.on_dispose { events << :cleaned }
      "instance"
    end

    fiber.activate!(@ctx)
    assert_equal [:created], events

    fiber.reactivate!(@ctx)
    assert_equal [:created, :cleaned, :created], events
    assert_equal :active, fiber.state
  end

  def test_dispose_cleans_subcontext_and_marks_disposed
    cleaned = false
    fiber = Rubik::Runtime::Fiber.new(name: "mortal", inject: []) do |sub_ctx|
      sub_ctx.on_dispose { cleaned = true }
      "alive"
    end

    fiber.activate!(@ctx)
    fiber.dispose!

    assert_equal :disposed, fiber.state
    assert_nil fiber.instance
    assert cleaned
  end

  def test_component_fiber_naming_and_alias_compatibility
    assert_same Rubik::Runtime::ComponentFiber, Rubik::Runtime::Fiber
    cf = Rubik::Runtime::ComponentFiber.new(name: "cf_test", inject: []) { "ok" }
    assert_instance_of Rubik::Runtime::ComponentFiber, cf
    assert_instance_of Rubik::Runtime::Fiber, cf
    assert cf.activate!(@ctx)
    assert_equal "ok", cf.instance

    # Standard library ::Fiber remains accessible and uncorrupted
    coroutine = ::Fiber.new { 42 }
    assert_equal 42, coroutine.resume
  end

  # ── Plan 86 D-3: requires: pre-activation gate ─────────────────────

  def test_requires_defaults_to_empty_backward_compatible
    fiber = Rubik::Runtime::Fiber.new(name: "plain")

    assert_equal [], fiber.requires
    assert fiber.ready_to_activate?(@ctx), "no requires: must behave exactly like satisfiable?"
  end

  def test_ready_to_activate_needs_both_inject_and_requires
    fiber = Rubik::Runtime::Fiber.new(name: "gated", inject: ["database"], requires: ["tool_registry"])

    @ctx.provide("database", { connected: true })
    refute fiber.ready_to_activate?(@ctx), "satisfied inject alone must not clear the requires: gate"
    assert fiber.satisfiable?(@ctx), "satisfiable? must stay inject-only (pre-existing contract)"

    @ctx.provide("tool_registry", Object.new)
    assert fiber.ready_to_activate?(@ctx)
  end

  def test_activation_blocked_until_requires_present
    calls = 0
    fiber = Rubik::Runtime::Fiber.new(name: "gated_factory", requires: ["llm_client"]) do |_ctx|
      calls += 1
      "built"
    end

    refute fiber.activate!(@ctx)
    assert_equal :pending, fiber.state
    assert_equal 0, calls

    @ctx.provide(:llm_client, "client")
    assert fiber.activate!(@ctx)
    assert_equal :active, fiber.state
    assert_equal 1, calls
  end

  # ── Concurrency contract (review 2026-09-17, Finding 2) ─────────────

  def test_fiber_is_documented_lock_free_with_manager_monitor_contract
    source = File.read(File.expand_path("../../lib/rubik/runtime/fiber.rb", __dir__))

    # The lock-free contract MUST stay documented on the class, and it must
    # name the Manager Monitor as the single serialization point.
    assert_includes source, "Concurrency Contract"
    assert_includes source, "lock-free"
    assert_includes source, "Manager's Monitor"

    # And the class must not have grown a hidden internal lock. (fresh-eye R4:
    # matchers target real locking idioms instead of raw substrings, so an
    # innocuous future comment mentioning @monitor cannot false-positive,
    # while MonitorMixin inclusion and bare @lock assignments stay caught.)
    refute_match(/\bMonitor\.new\b/, source)
    refute_match(/\bMutex\.new\b/, source)
    refute_match(/include\s+(?:MonitorMixin|ThreadSafe)/, source)
    refute_match(/@lock\s*=/, source)
    refute_match(/\.synchronize\b/, source)
  end
end
