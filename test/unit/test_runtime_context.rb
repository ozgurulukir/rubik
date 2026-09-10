# frozen_string_literal: true

require_relative "../test_helper"

class TestRuntimeContext < Minitest::Test
  def setup
    @ctx = Rubik::Runtime::Context.new
  end

  def teardown
    @ctx.dispose unless @ctx.disposed?
  end

  # ── provide & require ────────────────────────────────────────────────

  def test_provide_and_require_with_string_and_symbol_keys
    @ctx.provide("logger", { level: :info })
    @ctx.provide(:database, { connected: true })

    assert_equal({ level: :info }, @ctx.require("logger"))
    assert_equal({ level: :info }, @ctx.require(:logger))
    assert_equal({ connected: true }, @ctx.require("database"))
    assert_equal({ connected: true }, @ctx.require(:database))
  end

  def test_get_returns_nil_for_missing_service
    assert_nil @ctx.get("non_existent")
    assert_nil @ctx.get(:non_existent)
  end

  def test_require_raises_coeffect_missing_error_when_not_satisfied
    err = assert_raises(Rubik::Runtime::CoeffectMissingError) do
      @ctx.require("missing_service")
    end

    assert_includes err.message, "missing_service"
  end

  def test_has_and_satisfied_predicates
    @ctx.provide("auth", { user: "admin" })

    assert @ctx.has?("auth")
    assert @ctx.has?(:auth)
    assert @ctx.satisfied?(["auth"])
    assert @ctx.satisfied?([:auth])

    refute @ctx.has?("missing")
    refute @ctx.satisfied?(["auth", "missing"])
  end

  # ── Legacy alias bridge (Rubik::Coeffects SSOT) ──────────────────────

  def test_require_resolves_legacy_alias_to_canonical_service
    registry = Object.new
    @ctx.provide(:tool_registry, registry)

    assert_same registry, @ctx.require(:tools)
    assert @ctx.has?("tools")
    assert @ctx.satisfied?(["tools"])
  end

  def test_legacy_alias_resolves_through_parent_chain
    @ctx.provide(:llm_client, "llm")
    child = @ctx.extend

    assert_equal "llm", child.require(:llm)
    assert child.has?("llm")
  end

  def test_literal_alias_provide_wins_for_literal_reads
    @ctx.provide(:tool_registry, "canonical")
    @ctx.provide(:tools, "literal")

    assert_equal "literal", @ctx.require(:tools)
  end

  def test_unsatisfied_alias_request_still_raises_with_requested_name
    err = assert_raises(Rubik::Runtime::CoeffectMissingError) do
      @ctx.require(:tools)
    end

    assert_includes err.message, "tools"
  end

  # ── extend & parent hierarchy ────────────────────────────────────────

  def test_extend_creates_child_with_parent_lookup
    @ctx.provide("global_config", { env: "test" })

    child = @ctx.extend
    child.provide("local_service", 42)

    assert_equal({ env: "test" }, child.require("global_config"))
    assert_equal 42, child.require("local_service")
    assert child.has?("global_config")
    assert child.has?("local_service")

    # Parent does not see child services
    refute @ctx.has?("local_service")
  end

  def test_child_override_shadows_parent_without_mutating_parent
    @ctx.provide("service", "parent_value")

    child = @ctx.extend
    child.provide("service", "child_value")

    assert_equal "child_value", child.require("service")
    assert_equal "parent_value", @ctx.require("service")
  end

  def test_multi_level_subcontext_chain
    root = Rubik::Runtime::Context.new
    root.provide("level_0", "root")

    level1 = root.extend
    level1.provide("level_1", "mid")

    level2 = level1.extend
    level2.provide("level_2", "leaf")

    assert_equal "root", level2.require("level_0")
    assert_equal "mid", level2.require("level_1")
    assert_equal "leaf", level2.require("level_2")
  ensure
    root.dispose unless root.disposed?
  end

  # ── LIFO Ω Inverses & Disposal ───────────────────────────────────────

  def test_lifo_disposal_order
    order = []
    @ctx.on_dispose { order << 1 }
    @ctx.register_disposable { order << 2 }
    @ctx.on_dispose { order << 3 }

    @ctx.dispose

    assert_equal [3, 2, 1], order
    assert @ctx.disposed?
  end

  def test_parent_disposal_disposes_all_children_recursively
    child = @ctx.extend
    grandchild = child.extend

    child_cleaned = false
    grandchild_cleaned = false

    child.on_dispose { child_cleaned = true }
    grandchild.on_dispose { grandchild_cleaned = true }

    @ctx.dispose

    assert @ctx.disposed?
    assert child.disposed?
    assert grandchild.disposed?
    assert child_cleaned
    assert grandchild_cleaned
  end

  def test_child_disposal_does_not_dispose_parent
    child = @ctx.extend
    child_cleaned = false
    parent_cleaned = false

    child.on_dispose { child_cleaned = true }
    @ctx.on_dispose { parent_cleaned = true }

    child.dispose

    assert child.disposed?
    assert child_cleaned
    refute @ctx.disposed?
    refute parent_cleaned
  end

  def test_disposal_error_isolation
    first_called = false
    second_called = false

    @ctx.on_dispose { first_called = true }
    @ctx.on_dispose { raise "cleanup failure!" }
    @ctx.on_dispose { second_called = true }

    # Should not raise exception out of dispose; should execute all cleanups
    capture_io do
      @ctx.dispose
    end

    assert first_called
    assert second_called
    assert @ctx.disposed?
  end

  def test_multiple_dispose_calls_are_idempotent
    calls = 0
    @ctx.on_dispose { calls += 1 }

    @ctx.dispose
    @ctx.dispose

    assert_equal 1, calls
    assert @ctx.disposed?
  end

  def test_disposal_cleans_services_and_preserves_lifo_even_with_failing_inverses
    execution_order = []

    @ctx.provide("service_a", "val_a")
    @ctx.on_dispose do
      execution_order << :custom_cleanup_first
      raise "failing inverse in Ω"
    end
    @ctx.provide("service_b", "val_b")
    @ctx.on_dispose do
      execution_order << :custom_cleanup_second
    end

    assert_equal 2, @ctx.services.size

    capture_io do
      @ctx.dispose
    end

    # Ω drains in strict LIFO order despite middle failure
    assert_equal [:custom_cleanup_second, :custom_cleanup_first], execution_order
    assert @ctx.services.empty?, "all services must be cleanly removed after dispose"
    assert @ctx.disposed?
    assert_equal 1, @ctx.last_dispose_errors.size
    assert_equal "failing inverse in Ω", @ctx.last_dispose_errors.first.message
  end

  # ── Thread safety: state snapshots must not leak live internals ──────

  def test_services_snapshot_is_frozen
    @ctx.provide("db", { connected: true })

    assert @ctx.services.frozen?, "services must return a frozen snapshot, not live internal state"
  end

  def test_last_dispose_errors_snapshot_is_isolated
    @ctx.on_dispose { raise "boom" }
    capture_io { @ctx.dispose }

    errors = @ctx.last_dispose_errors
    errors << :caller_mutation

    assert_equal 1, @ctx.last_dispose_errors.size, "mutating the returned list must not corrupt internal state"
  end

  # ── Thread safety: contention stress ─────────────────────────────────

  # Contract pin: concurrent provide/require/extend from many threads must
  # never crash or lose services. MRI's GVL masks most Hash races, so this
  # is not a red/green race reproduction — the Context monitor makes the
  # interleavings impossible by construction.
  def test_concurrent_provide_and_read_stress
    errors = []
    writer_threads = 4.times.map do |t|
      Thread.new do
        200.times do |i|
          @ctx.provide("svc_#{t}_#{i}", { t: t, i: i })
        end
      end
    end
    reader_threads = 4.times.map do
      Thread.new do
        200.times do
          @ctx.get("svc_0_0")
          @ctx.has?("svc_1_100")
          @ctx.services.size
          @ctx.service_names.size
        end
      rescue StandardError => e
        errors << e
      end
    end

    (writer_threads + reader_threads).each(&:join)

    assert_empty errors
    assert_equal 800, @ctx.services.size, "every concurrent provide must land exactly once"
  end

  # A disposable registered while dispose is draining another thread's
  # context must run exactly once: either drained by the LIFO loop (before
  # the final pop) or executed immediately (after the context is sealed).
  def test_disposable_registered_during_drain_still_runs
    200.times do
      ctx = Rubik::Runtime::Context.new
      ran = []
      ctx.on_dispose { ran << :first }
      disposer = Thread.new { ctx.dispose }
      ctx.on_dispose { ran << :second } # races the drain
      disposer.join

      assert_equal 2, ran.size, "every disposable must run exactly once despite registration racing the drain"
    end
  end

  # ── Ω sealing: registration after disposal must not leak ─────────────

  def test_disposable_registered_after_dispose_runs_immediately
    ran = []
    @ctx.dispose
    assert @ctx.disposed?

    @ctx.on_dispose { ran << :late }

    assert_equal [:late], ran, "an inverse registered after disposal must run now, not sit in a dead accumulator"
    assert_equal 0, @ctx.disposable_count, "a disposed context must not accumulate dead inverses"
  end

  def test_disposable_registered_after_dispose_records_errors
    @ctx.dispose

    capture_io do
      @ctx.on_dispose { raise "late boom" }
    end

    assert_equal 1, @ctx.last_dispose_errors.size
    assert_equal "late boom", @ctx.last_dispose_errors.first.message
  end
end
