# frozen_string_literal: true

require_relative "../test_helper"

# G26 lifecycle auditor's suite-embedded guard (AGENTS.md §6, Zero-Restart
# Reloading): repeated lifecycle epochs must return the Omega accumulator to
# its baseline with every inverse executed exactly once. Single-cycle hygiene
# contracts live in test_context_dispose_hygiene.rb / test_runtime_context.rb;
# the scale probe is dev/soak_lifecycle.rb (docs/development/testing.md "Lifecycle soak (G26)").
class TestRuntimeZeroRestartSoak < Minitest::Test
  EPOCHS = 100

  def test_context_epochs_return_the_omega_accumulator_to_baseline
    parent = Rubik::Runtime::Context.new
    ran = 0
    EPOCHS.times do
      child = parent.extend
      child.provide("db", Object.new)
      child.on_dispose { ran += 1 }
      child.dispose
    end

    assert_equal 0, parent.disposable_count,
                 "closed epochs must leave no cascade inverses in the parent accumulator"
    assert_equal EPOCHS, ran, "each epoch's inverse must run exactly once"
  end

  def test_reproviding_a_service_never_stacks_delete_inverses
    ctx = Rubik::Runtime::Context.new
    EPOCHS.times do |i|
      key = "svc_#{i % 5}"
      ctx.provide(key, Object.new)
      ctx.provide(key, Object.new) # swap — must never stack a second inverse
    end

    assert_equal 5, ctx.disposable_count,
                 "re-providing a live key must swap the value, not grow the accumulator"

    EPOCHS.times { |i| ctx.unprovide("svc_#{i % 5}") }

    assert_equal 0, ctx.disposable_count, "unprovide must retract service AND inverse"
    assert_empty ctx.services
  end

  def test_activation_cycles_leave_no_residue_in_the_parent_accumulator
    parent = Rubik::Runtime::Context.new
    ran = 0
    fiber = Rubik::Runtime::ComponentFiber.new(name: "soak") do |sub|
      sub.on_dispose { ran += 1 }
      :ok
    end
    EPOCHS.times do
      assert fiber.activate!(parent), "activation must succeed: #{fiber.last_error}"
      assert_equal :ok, fiber.instance
      fiber.deactivate!
      assert_equal :pending, fiber.state
      assert_nil fiber.sub_context
      assert_nil fiber.instance
    end

    assert_equal EPOCHS, ran, "each cycle's sub-context inverse must run exactly once"
    assert_equal 0, parent.disposable_count, "activation cycles must not grow the parent accumulator"
  end

  def test_failed_activations_roll_back_every_partial_inverse_each_epoch
    parent = Rubik::Runtime::Context.new
    rolled = 0
    boom = Rubik::Runtime::ComponentFiber.new(name: "boom") do |sub|
      sub.on_dispose { rolled += 1 }
      raise "factory failure"
    end
    EPOCHS.times do
      refute boom.activate!(parent)
      assert_equal :failed, boom.state
    end

    assert_equal EPOCHS, rolled, "each failed activation must unwind its partial inverse immediately"
    assert_equal "factory failure", boom.last_error.message
    assert_equal 0, parent.disposable_count, "rollbacks must not leak into the parent accumulator"
    assert_empty parent.last_dispose_errors
  end
end
