# frozen_string_literal: true

require_relative "../test_helper"

# Pins for the unified budget-grant core (Candidate 03): grant_budget!
# owns normalize -> floor -> += -> warn-reset -> resume -> note -> broadcast,
# with the terminal-state guard covering BOTH grant paths.
class TestInstanceGrantBudget < Minitest::Test
  def setup
    @root_context = Rubik::Runtime::Context.new
    @inst = new_instance(max_steps: 5)
  end

  def teardown
    @root_context.dispose unless @root_context.disposed?
  end

  def new_instance(max_steps:)
    Rubik::Orchestrator::Subagent::Instance.new(
      id: "subagent-grant", parent_id: "agent-0", role: "Grant Worker",
      type_name: "research", prompt: "Work", context: @root_context,
      tool_registry: nil, max_steps: max_steps
    )
  end

  def test_extend_budget_grants_and_notes_history
    @inst.instance_variable_set(:@state, :waiting_budget)

    assert_equal true, @inst.extend_budget(10)
    assert_equal 15, @inst.max_steps
    assert_equal :running, @inst.state

    note = @inst.history.find { |m| m[:content]&.include?("Granted 10 additional step(s)") }
    refute_nil note, "history must carry the grant note"
    assert_includes note[:content], "Total budget: 15."
  end

  def test_extend_budget_refuses_terminal_states
    @inst.instance_variable_set(:@state, :completed)

    assert_equal false, @inst.extend_budget(10)
    assert_equal 5, @inst.max_steps
    assert_equal :completed, @inst.state
  end

  def test_post_message_grants_only_when_waiting_or_steps_attached
    @inst.instance_variable_set(:@state, :running)
    @inst.post_message("status ping")
    assert_equal 5, @inst.max_steps, "a plain message on a running worker must not grant budget"

    @inst.post_message("more work", additional_steps: 5)
    assert_equal 10, @inst.max_steps

    note = @inst.history.find { |m| m[:content]&.include?("Granted 5 additional step(s) with message") }
    refute_nil note
    assert_includes note[:content], "Total budget: 10."
  end

  def test_post_message_on_terminal_state_delivers_inbox_but_refuses_grant
    @inst.instance_variable_set(:@state, :completed)
    @inst.post_message("too late", additional_steps: 10)

    assert_equal 5, @inst.max_steps, "a dead instance must not resurrect"
    assert_equal :completed, @inst.state
    refute_empty @inst.instance_variable_get(:@inbox), "the message itself still lands in the inbox"
  end

  def test_grant_floor_normalizes_non_positive_steps
    [nil, 0, -3].each do |raw|
      inst = new_instance(max_steps: 5)
      inst.instance_variable_set(:@state, :waiting_budget)
      inst.extend_budget(raw)

      assert_equal 25, inst.max_steps, "raw #{raw.inspect} must floor to a 20-step grant"
    end
  end

  def test_grant_rearms_the_warning_flag
    @inst.instance_variable_set(:@state, :waiting_budget)
    budget = @inst.send(:budget)
    budget.instance_variable_set(:@warned, true)

    @inst.extend_budget(10)

    refute budget.warned?, "the 75% step warning must re-arm after a grant"
  end

  def test_extend_budget_refuses_canceling_state_kill_race_window
    @inst.instance_variable_set(:@state, :canceling)

    assert_equal false, @inst.extend_budget(10)
    assert_equal 5, @inst.max_steps
    assert_equal :canceling, @inst.state, "a grant must not undo a concurrent kill"
  end

  def test_plain_message_to_paused_worker_grants_default_twenty_and_resumes
    @inst.instance_variable_set(:@state, :waiting_budget)

    @inst.post_message("nudge")

    assert_equal 25, @inst.max_steps, "resuming a paused worker floors to the default 20-step grant"
    assert_equal :running, @inst.state
  end

  def test_explicit_zero_steps_floors_to_default_grant
    @inst.instance_variable_set(:@state, :waiting_budget)

    @inst.post_message("nudge", additional_steps: 0)

    assert_equal 25, @inst.max_steps, "additional_steps: 0 is truthy but floors to 20"
  end

  def test_extend_budget_refuses_budget_exhausted_state
    @inst.instance_variable_set(:@state, :budget_exhausted)

    assert_equal false, @inst.extend_budget(10)
    assert_equal 5, @inst.max_steps
    assert_equal :budget_exhausted, @inst.state
  end
end
