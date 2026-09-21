# frozen_string_literal: true

require_relative "../test_helper"

# Unit pins for the Subagent::Budget state machine (Candidate 04). End-to-end
# behavior (warning surfacing, pause/resume, grant notes) stays pinned in
# test_subagent_orchestration.rb and test_instance_grant_budget.rb.
class TestSubagentBudget < Minitest::Test
  def budget(max_steps: 4)
    Rubik::Orchestrator::Subagent::Budget.new(max_steps: max_steps)
  end

  def test_constructor_normalizes_nil_to_default
    assert_equal 15, budget(max_steps: nil).max_steps
    assert_equal 4, budget(max_steps: 4).max_steps
    assert_equal 0, budget.current_step
    refute budget.warned?
  end

  def test_consume_increments_and_returns_new_step
    b = budget
    assert_equal 1, b.consume
    assert_equal 2, b.consume
    assert_equal 2, b.current_step
  end

  def test_exhausted_at_ceiling
    b = budget(max_steps: 2)
    refute b.exhausted?
    2.times { b.consume }
    assert b.exhausted?
  end

  def test_warning_fires_once_at_seventy_five_percent_with_pinned_text
    b = budget(max_steps: 4) # ceil(4 * 0.75) = 3
    2.times { b.consume }
    assert_nil b.take_step_warning!
    b.consume
    assert_equal "[Step budget warning]: Used 3/4 steps (1 remaining). " \
                 "Conclude work or prepare progress summary for init-0 supervisor.",
                 b.take_step_warning!
    assert_nil b.take_step_warning!, "latch: second call in the same epoch is silent"
  end

  def test_warning_threshold_uses_ceil_and_stays_silent_at_ceiling
    b = budget(max_steps: 5) # ceil(3.75) = 4, not 3
    3.times { b.consume }
    assert_nil b.take_step_warning!
    b.consume
    assert_includes b.take_step_warning!, "Used 4/5 steps"

    at_ceiling = budget(max_steps: 4)
    4.times { at_ceiling.consume }
    assert_nil at_ceiling.take_step_warning!, "no warning when already exhausted"
  end

  def test_grant_normalizes_floors_and_returns_extra_total_pair
    [nil, 0, -3].each do |raw|
      assert_equal [10, 25], budget(max_steps: 15).grant!(raw), "raw #{raw.inspect} floors to 10"
    end
    assert_equal [5, 9], budget(max_steps: 4).grant!(5)
  end

  def test_grant_rearms_and_reaims_the_warning_at_the_new_budget
    b = budget(max_steps: 4)
    3.times { b.consume }
    b.take_step_warning! # fired + latched at 3/4
    b.grant!(4)          # total 8, new threshold ceil(6.0) = 6
    refute b.warned?
    3.times { b.consume }
    msg = b.take_step_warning!
    refute_nil msg, "warning must fire again at the new budget's 75% point"
    assert_includes msg, "Used 6/8 steps"
  end

  def test_to_h_is_a_two_key_snapshot
    b = budget(max_steps: 4)
    3.times { b.consume }
    assert_equal({ current_step: 3, max_steps: 4 }, b.to_h)
  end

  def test_concurrent_grants_and_consumes_do_not_lose_updates
    b = budget(max_steps: 100)
    threads = Array.new(8) do
      Thread.new do
        b.grant!(1)
        b.consume
      end
    end
    threads.each(&:join)

    assert_equal 108, b.max_steps
    assert_equal 8, b.current_step
  end
end
