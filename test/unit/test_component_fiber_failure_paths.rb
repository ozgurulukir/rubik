# frozen_string_literal: true

require_relative "../test_helper"

# G13 error-path coverage: ComponentFiber failure transitions (audit
# 2026-09-29, item 8). mark_failed! from :active must dispose the sub-context
# (running its Ω inverses) exactly like deactivate!, and dispose! on a failed
# fiber must not re-dispose a nil sub-context.
class TestComponentFiberFailurePaths < Minitest::Test
  def setup
    @ctx = Rubik::Runtime::Context.new
    @inverses_run = []
  end

  def teardown
    @ctx.dispose unless @ctx.disposed?
  end

  def build_fiber
    inverses_run = @inverses_run
    Rubik::Runtime::ComponentFiber.new(name: "flipflop", provides: [:flipflop_service]) do |sub_ctx|
      sub_ctx.on_dispose { inverses_run << true }
      Object.new
    end
  end

  def test_mark_failed_from_active_disposes_sub_context_and_records_error
    fiber = build_fiber
    fiber.activate!(@ctx)
    assert_equal :active, fiber.state
    refute_nil fiber.instance

    boom = StandardError.new("downstream coeffect vanished")
    fiber.mark_failed!(boom)

    assert_equal :failed, fiber.state
    assert_nil fiber.instance
    assert_equal 1, @inverses_run.size, "mark_failed! must run the sub-context's inverses"
    assert_equal boom, fiber.last_error
  end

  def test_mark_failed_default_error_is_generic_standard_error
    fiber = build_fiber
    fiber.activate!(@ctx)

    fiber.mark_failed!

    assert_equal :failed, fiber.state
    assert_instance_of StandardError, fiber.last_error
    assert_includes fiber.last_error.message, "flipflop"
  end

  def test_dispose_on_failed_fiber_reaches_disposed_without_redispose
    fiber = build_fiber
    fiber.activate!(@ctx)
    fiber.mark_failed!(StandardError.new("already failed"))
    @inverses_run.clear

    fiber.dispose!

    assert_equal :disposed, fiber.state
    assert_equal 0, @inverses_run.size, "failed fiber has no sub-context left to dispose"
  end
end
