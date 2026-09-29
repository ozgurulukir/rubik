# frozen_string_literal: true

require_relative "../test_helper"

# G13 error-path coverage: Runtime::Manager dependency-cycle handling (audit
# 2026-09-29, item 3). Two fibers whose inject/requires reference each other's
# provides can never topologically order; handle_fiber_cycle must fail them
# loudly without poisoning the manager for acyclic components.
class TestRuntimeManagerFiberCycle < Minitest::Test
  def setup
    @ctx = Rubik::Runtime::Context.new
    @manager = Rubik::Runtime::Manager.new(@ctx)
  end

  def teardown
    @manager.dispose! unless @ctx.disposed?
  end

  def test_dependency_cycle_marks_all_cycle_members_failed
    @manager.register_component("alpha", inject: [:beta_service], provides: [:alpha_service]) do |_ctx|
      Object.new
    end
    @manager.register_component("beta", inject: [:alpha_service], provides: [:beta_service]) do |_ctx|
      Object.new
    end

    assert_output(nil, /Dependency cycle detected among fibers: /) { @manager.reconcile_all }

    alpha = @manager.fibers["alpha"]
    beta = @manager.fibers["beta"]
    assert_equal :failed, alpha.state, "alpha should be failed by cycle detection"
    assert_equal :failed, beta.state, "beta should be failed by cycle detection"
    assert_includes alpha.last_error.message, "Dependency cycle detected"
    assert_includes alpha.last_error.message, "alpha, beta"
  end

  def test_manager_stays_usable_after_cycle_detection
    @manager.register_component("alpha", inject: [:beta_service], provides: [:alpha_service]) { |_ctx| Object.new }
    @manager.register_component("beta", inject: [:alpha_service], provides: [:beta_service]) { |_ctx| Object.new }
    @manager.reconcile_all

    # an acyclic third component still activates and is injected its deps
    ran = nil
    @manager.register_component("standalone", provides: [:standalone_service]) do |_ctx|
      ran = true
      Object.new
    end
    assert ran, "acyclic component should activate despite earlier cycle"
    assert_equal :active, @manager.fibers["standalone"].state

    # breaking the cycle lets the failed pair recover on the next reconcile
    @manager.fibers["beta"].instance_variable_set(:@requires, [])
    @manager.fibers["beta"].instance_variable_set(:@inject, [])
    @manager.context.provide(:beta_service, Object.new)
    @manager.reconcile_all
    assert_equal :active, @manager.fibers["alpha"].state, "alpha should activate once its dependency is satisfiable"
  end
end
