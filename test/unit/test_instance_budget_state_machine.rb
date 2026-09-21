# frozen_string_literal: true

require_relative "../test_helper"

class TestInstanceBudgetStateMachine < Minitest::Test
  def setup
    @root_context = Rubik::Runtime::Context.new
    @tool_registry = Rubik::Tools::Registry.new(coeffect_ctx: @root_context)
  end

  def teardown
    @root_context.dispose unless @root_context.disposed?
  end

  def test_pause_and_await_budget_expansion_transitions_to_budget_exhausted_on_timeout
    inst = Rubik::Orchestrator::Subagent::Instance.new(
      id: "subagent-exhaust-1",
      parent_id: "agent-0",
      role: "Exhausted Worker",
      type_name: "coder",
      prompt: "Perform massive code refactoring",
      context: @root_context,
      tool_registry: @tool_registry,
      max_steps: 10
    )
    inst.instance_variable_set(:@state, :running)
    10.times { inst.send(:budget).consume }

    resumed = inst.send(:pause_and_await_budget_expansion!, 0.05)
    refute resumed, "Worker must not resume without supervisor grant"
    assert_equal :budget_exhausted, inst.state, "State must be :budget_exhausted, never :completed"
    assert_includes inst.result, "halted: task was NOT completed"
    refute inst.active?, "A budget-exhausted subagent is not active"
    refute inst.running?, "A budget-exhausted subagent is not running"
  end

  def test_grant_budget_refuses_budget_exhausted_instance
    inst = Rubik::Orchestrator::Subagent::Instance.new(
      id: "subagent-exhaust-2",
      parent_id: "agent-0",
      role: "Dead Worker",
      type_name: "research",
      prompt: "Search docs",
      context: @root_context,
      tool_registry: @tool_registry,
      max_steps: 5
    )
    inst.instance_variable_set(:@state, :budget_exhausted)

    refute inst.extend_budget(20), "Cannot extend budget for halted :budget_exhausted instance"
    assert_equal :budget_exhausted, inst.state
    assert_equal 5, inst.max_steps
  end

  def test_budget_exhausted_prevents_branch_buffer_merge_and_auto_apply
    dir = Dir.mktmpdir("rubik_exhausted_buffer")
    begin
      buf_mgr = Rubik::Buffer::Manager.new(root_dir: dir)
      supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(
        root_context: @root_context,
        buffer_manager: buf_mgr,
        root_dir: dir
      )

      # Create branch instance with dirty writes
      inst = supervisor.spawn(
        role: "Branch Coder",
        prompt: "Write dangerous unverified code",
        workspace: "branch",
        max_steps: 2
      )

      test_file = File.join(dir, "feature.rb")
      inst.buffer_manager.write(test_file, "# unverified draft code")
      assert inst.buffer_manager.dirty?
      refute buf_mgr.dirty?, "Root buffer should not yet have dirty edits"

      # Simulate timeout resulting in :budget_exhausted
      inst.instance_variable_set(:@state, :budget_exhausted)
      supervisor.send(:handle_subagent_completion, inst)

      # Root buffer must NOT have received the branch buffer changes
      refute buf_mgr.dirty?, "Root buffer must remain clean when subagent state is :budget_exhausted"
      refute File.exist?(test_file), "Disk must not be modified when task was incomplete"

      supervisor.shutdown_all
    ensure
      remove_temp_dir(dir)
    end
  end

  def test_notices_format_budget_exhausted_truthfully
    notice = {
      kind: :completed,
      id: "subagent-42",
      role: "Architect",
      state: "budget_exhausted"
    }

    user_text = Rubik::Orchestrator::Subagent::Notices.user_line(notice)
    assert_includes user_text, "BUDGET_EXHAUSTED (task incomplete)"
    assert_includes user_text, "🛑 [Subagent Budget Exhausted]"

    guidance = Rubik::Orchestrator::Subagent::Notices.guidance_for(notice)
    assert_includes guidance, "Task was NOT completed"
    assert_includes guidance, "Inspect transcript or launch a new subagent"
  end
end
