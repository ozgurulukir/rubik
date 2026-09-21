# frozen_string_literal: true

require_relative "../test_helper"

# Candidate 05 Stage 1: the ServiceRegistration spine owns exactly three
# things — carrier->context extraction, the trailing reconcile, nil-carrier
# tolerance. These tests lock each against fake and real carriers; the four
# shims built on the spine are covered by their own suites
# (test_runtime_ast_service / test_runtime_index_service /
# test_orchestrator_fiber_lifecycle / test_ui_renderer).
class TestRuntimeServiceRegistration < Minitest::Test
  class FakeManager
    attr_reader :context, :reconcile_count

    def initialize(context)
      @context = context
      @reconcile_count = 0
    end

    def reconcile_all
      @reconcile_count += 1
    end
  end

  def test_manager_carrier_yields_its_context_and_reconciles_once
    ctx = Rubik::Runtime::Context.new
    manager = FakeManager.new(ctx)

    seen = nil
    result = Rubik::Runtime::ServiceRegistration.call(manager) do |yielded|
      seen = yielded
      :block_value
    end

    assert_same ctx, seen
    assert_equal :block_value, result
    assert_equal 1, manager.reconcile_count
  end

  def test_bare_context_carrier_yields_itself_without_reconciling
    ctx = Rubik::Runtime::Context.new

    seen = nil
    result = Rubik::Runtime::ServiceRegistration.call(ctx) do |yielded|
      seen = yielded
      42
    end

    assert_same ctx, seen
    assert_equal 42, result
  end

  def test_nil_carrier_yields_nil_without_raising
    seen = :unset
    result = Rubik::Runtime::ServiceRegistration.call(nil) do |yielded|
      seen = yielded
      :fallback
    end

    assert_nil seen
    assert_equal :fallback, result
  end

  def test_reconcile_false_suppresses_the_trailing_reconcile
    manager = FakeManager.new(Rubik::Runtime::Context.new)

    Rubik::Runtime::ServiceRegistration.call(manager, reconcile: false) { |_ctx| nil }

    assert_equal 0, manager.reconcile_count
  end

  def test_real_manager_carrier_end_to_end_provide_and_reconcile
    manager = Rubik::Runtime::Manager.new

    value = Object.new
    returned = Rubik::Runtime::ServiceRegistration.call(manager) do |ctx|
      ctx.provide("spine_probe", value)
      value
    end

    assert_same value, returned
    assert_same value, manager.context.get("spine_probe")
  ensure
    manager&.dispose!
  end
end
