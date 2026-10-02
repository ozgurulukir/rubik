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

  def test_budget_exhausted_prevents_branch_buffer_merge_and_auto_apply
    dir = Dir.mktmpdir("rubik_exhausted_buffer")
    begin
      resp = Struct.new(:content, :tool_calls).new("Working", [{ "id" => "c1", "tool" => "dummy", "args" => {} }])
      provider = Object.new
      provider.define_singleton_method(:complete) { |_h, _o = {}| resp }
      cfg = Rubik::Config.new
      cfg.set("subagents.budget_wait_timeout", 0.05)
      buf_mgr = Rubik::Buffer::Manager.new(root_dir: dir)
      supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(
        root_context: @root_context,
        buffer_manager: buf_mgr,
        root_dir: dir,
        provider: provider,
        config: cfg
      )

      # Branch worker burns its budget for real and parks exhausted.
      inst = supervisor.spawn(
        role: "Branch Coder",
        prompt: "Write dangerous unverified code",
        workspace: "branch",
        max_steps: 2
      )
      wait_until { inst.state == :budget_exhausted }

      test_file = File.join(dir, "feature.rb")
      inst.buffer_manager.write(test_file, "# unverified draft code")
      assert inst.buffer_manager.dirty?
      refute buf_mgr.dirty?, "Root buffer should not yet have dirty edits"

      # The exhausted thread parks forever, so the spawn-time on_complete
      # hook cannot fire naturally — drive the completion choreography on
      # this genuinely-exhausted instance.
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
      state: "budget_exhausted",
      max_steps: 88
    }

    user_text = Rubik::Orchestrator::Subagent::Notices.user_line(notice)
    assert_includes user_text, "BUDGET_EXHAUSTED (task incomplete)"
    assert_includes user_text, "🛑 [Subagent Budget Exhausted]"

    guidance = Rubik::Orchestrator::Subagent::Notices.guidance_for(notice)
    assert_includes guidance, "reached step budget (88 steps) and halted: task was NOT completed"
    assert_includes guidance, "Inspect transcript or spawn a new subagent"
  end

  private

  def wait_until
    deadline = Time.now + 5
    until (value = yield)
      return false if Time.now >= deadline

      sleep 0.02
    end
    value
  end
end
