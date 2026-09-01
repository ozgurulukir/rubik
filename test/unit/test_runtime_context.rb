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
    @ctx.dispose

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
end
