# frozen_string_literal: true

require_relative "../test_helper"

# Unit pins for the Subagent::Budget state machine (Candidate 04). End-to-end
# behavior (step markers, pause/resume, grant notes) stays pinned in
# test_subagent_orchestration.rb and test_instance_grant_budget.rb. Plan 109
# replaced the 75% warning latch with per-step [Step X/Y] transparency.
class TestSubagentBudget < Minitest::Test
  def budget(max_steps: 4)
    Rubik::Orchestrator::Subagent::Budget.new(max_steps: max_steps)
  end

  def test_constructor_normalizes_nil_to_default
    assert_equal 88, budget(max_steps: nil).max_steps
    assert_equal 4, budget(max_steps: 4).max_steps
    assert_equal 0, budget.current_step
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

  def test_step_marker_pins_vocabulary_and_grant_re_aim
    b = budget(max_steps: 4)
    2.times { b.consume }
    assert_equal "[Step 2/4]", b.step_marker
    b.grant!(4)
    assert_equal "[Step 2/8]", b.step_marker, "grant re-aims the denominator immediately (no latch to re-arm)"
  end

  def test_seventy_five_percent_latch_is_gone
    budget_class = Rubik::Orchestrator::Subagent::Budget
    refute budget_class.const_defined?(:WARN_RATIO), "Plan 109 removed WARN_RATIO with the latch"
    b = budget_class.new(max_steps: 4)
    refute_respond_to b, :take_step_warning!
    refute_respond_to b, :warned?
  end

  def test_grant_normalizes_floors_and_returns_extra_total_pair
    [nil, 0, -3].each do |raw|
      assert_equal [20, 108], budget(max_steps: 88).grant!(raw), "raw #{raw.inspect} floors to 20"
    end
    assert_equal [5, 9], budget(max_steps: 4).grant!(5)
  end

  def test_normalize_grant_is_the_pure_pre_grant_invariant_shared_by_reporting_edges
    assert_equal 20, Rubik::Orchestrator::Subagent::Budget.normalize_grant(nil)
    assert_equal 20, Rubik::Orchestrator::Subagent::Budget.normalize_grant("0")
    assert_equal 20, Rubik::Orchestrator::Subagent::Budget.normalize_grant(-3)
    assert_equal 15, Rubik::Orchestrator::Subagent::Budget.normalize_grant("15")
  end

  def test_grant_notes_share_the_grant_note_vocabulary
    assert_equal "[Supervisor init-0]: Granted 10 additional step(s). Total budget: 15. Continue execution.",
                 Rubik::Orchestrator::Subagent::Budget.grant_note(10, 15)
    assert_equal "[Supervisor init-0]: Granted 5 additional step(s) with message. Total budget: 10. Continue execution.",
                 Rubik::Orchestrator::Subagent::Budget.message_grant_note(5, 10)
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
