# frozen_string_literal: true

require_relative "../test_helper"

class TestSpatiotemporalRuntime < Minitest::Test
  def setup
    @ctx = Rubik::Runtime::Context.new
    @manager = Rubik::Runtime::Manager.new(@ctx)
  end

  def teardown
    @manager.dispose! unless @ctx.disposed?
  end

  def test_lifo_inverse_execution_order
    order = []
    ctx = Rubik::Runtime::Context.new

    ctx.register_disposable { order << 1 }
    ctx.register_disposable { order << 2 }
    ctx.register_disposable { order << 3 }

    ctx.dispose
    assert_equal [3, 2, 1], order, "Inverses must be executed in strict reverse chronological order (LIFO)"
    assert ctx.disposed?
  end

  def test_coeffect_requirement_and_delegation
    parent = Rubik::Runtime::Context.new
    parent.provide("database", { connected: true })

    child = parent.extend
    assert_equal({ connected: true }, child.require("database"))
    assert child.has?("database")

    assert_raises(Rubik::Runtime::CoeffectMissingError) do
      child.require("non_existent_service")
    end
  end

  def test_recursive_subcontext_disposal
    parent = Rubik::Runtime::Context.new
    child = parent.extend
    grandchild = child.extend

    child_disposed = false
    grandchild_disposed = false

    child.register_disposable { child_disposed = true }
    grandchild.register_disposable { grandchild_disposed = true }

    parent.dispose

    assert parent.disposed?
    assert child.disposed?
    assert grandchild.disposed?
    assert child_disposed
    assert grandchild_disposed
  end

  def test_fiber_reactive_lifecycle_transitions
    logs = []

    # Declare component requiring 'database' and 'http_server'
    fiber = @manager.register_component(
      "analytics",
      inject: ["database", "http_server"]
    ) do |ctx, _config|
      db = ctx.require("database")
      logs << "Analytics active with #{db[:name]}"
      ctx.on_dispose { logs << "Analytics deactivated" }
    end

    # 1. Initially Pending (missing coeffects)
    assert_equal :pending, fiber.state
    assert_equal [], logs

    # 2. Provide 'database' -> Still Pending (missing http_server)
    @manager.provide("database", { name: "PostgreSQL" })
    assert_equal :pending, fiber.state

    # 3. Provide 'http_server' -> Transition to Active
    @manager.provide("http_server", { port: 8080 })
    assert_equal :active, fiber.state
    assert_includes logs, "Analytics active with PostgreSQL"

    # 4. Deactivate fiber cleanly
    fiber.deactivate!
    assert_equal :pending, fiber.state
    assert_includes logs, "Analytics deactivated"
  end

  def test_atomic_rollback_on_activation_failure
    cleanups = []
    ctx = Rubik::Runtime::Context.new
    ctx.provide("logger", Object.new)

    fiber = Rubik::Runtime::Fiber.new(name: "failing_plugin", inject: ["logger"]) do |sub_ctx, _cfg|
      sub_ctx.on_dispose { cleanups << "step 1 cleaned" }
      cleanups << "step 1 done"

      sub_ctx.on_dispose { cleanups << "step 2 cleaned" }
      cleanups << "step 2 done"

      raise "Boom during step 3!"
    end

    success = fiber.activate!(ctx)
    refute success
    assert_equal :failed, fiber.state
    assert_equal "Boom during step 3!", fiber.last_error.message

    # Verify that partial inverses executed immediately in LIFO order
    assert_equal ["step 1 done", "step 2 done", "step 2 cleaned", "step 1 cleaned"], cleanups
  end

  def test_zero_downtime_hot_swapping_and_stress_reloading
    swaps = 0
    active_listeners = []

    # 1,000 consecutive reload cycles
    1000.times do |i|
      @manager.swap_component("dynamic_tool", inject: []) do |ctx, _cfg|
        listener_id = "listener_v#{i}"
        active_listeners << listener_id
        swaps += 1

        ctx.on_dispose do
          active_listeners.delete(listener_id)
        end
      end
    end

    assert_equal 1000, swaps
    assert_equal 1, active_listeners.size, "Exactly one active version must remain after 1,000 consecutive reloads"
    assert_equal "listener_v999", active_listeners.first

    @manager.dispose!
    assert_empty active_listeners, "All listeners must be cleanly unwound on manager disposal"
  end
end
