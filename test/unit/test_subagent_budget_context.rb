# frozen_string_literal: true

require_relative "../test_helper"

# Plan 109 Faz A: the subagent knows its budget — "Allocated Step Budget" in
# the system prompt plus an explanation of the [Step X/Y] marker it will see
# every step. The per-step marker injection end-to-end and the Budget VO
# marker vocabulary/grant re-aim are pinned in test_subagent_orchestration.rb
# and test_subagent_budget.rb respectively (test-placement contract).
class TestSubagentBudgetContext < Minitest::Test
  def setup
    @root_context = Rubik::Runtime::Context.new
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: Dir.pwd)
    @tool_registry = Rubik::Tools::Registry.build_default(
      buffer_manager: @buffer_manager,
      root_dir: Dir.pwd
    )
    @supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context,
      buffer_manager: @buffer_manager,
      tool_registry: @tool_registry
    )
  end

  def teardown
    @supervisor&.shutdown_all
    @root_context&.dispose unless @root_context&.disposed?
  end

  def test_system_prompt_states_default_allocated_step_budget
    inst = @supervisor.spawn(role: "Budget Reader", prompt: "Read your budget")
    prompt = inst.send(:build_effective_system_prompt)

    assert_includes prompt, "Allocated Step Budget: 88 steps"
    assert_includes prompt, "[Step X/Y]", "the prompt must explain the per-step marker it will see"
  end

  def test_system_prompt_reflects_custom_max_steps
    inst = @supervisor.spawn(role: "Small Budget", prompt: "P", max_steps: 7)
    assert_includes inst.send(:build_effective_system_prompt), "Allocated Step Budget: 7 steps"
  end
end
