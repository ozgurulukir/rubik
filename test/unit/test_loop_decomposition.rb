# frozen_string_literal: true

require_relative "../test_helper"

# The Loop pass-through shims retired (agent-turn-executor Phase 5): these
# pins drive the collaborators directly, exactly as Loop's step loop and the
# TurnExecutor user-channel adapter do.
class TestLoopDecomposition < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_decomp_test")
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @registry = Rubik::Tools::Registry.new
    @registry.register(Rubik::Tools::ReadFileTool.new(@buffer_manager))
    @registry.register(Rubik::Tools::WriteFileTool.new(@buffer_manager))
    @registry.register(Rubik::Tools::FinishTool.new)

    @mock_provider = Class.new(Rubik::LLM::BaseProvider) do
      def complete(_messages, _opts = {})
        Rubik::LLM::Response.new(text: "ok")
      end
    end.new

    @loop = Rubik::Orchestrator::Loop.new(
      provider: @mock_provider,
      tool_registry: @registry,
      max_steps: 10,
      warn_at_ratio: 0.8
    )
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
  end

  def test_evaluate_step_budget_warning
    # BudgetManager's documented test-double path (ShellDeps.wrap): drive the
    # manager over a plain deps double whose step_count moves between calls —
    # no Loop ivar pokes (issue #476 tranche 2).
    events = []
    deps = Struct.new(:step_count, :max_steps, :warn_at_ratio, :history, :on_step, keyword_init: true).new(
      step_count: 5, max_steps: 10, warn_at_ratio: 0.8, history: [],
      on_step: ->(info) { events << info }
    )
    manager = Rubik::Orchestrator::BudgetManager.new(deps)

    # At step 5 of 10 with warn_at_ratio 0.8 (threshold 8), no warning
    refute manager.evaluate_step_budget_warning!(false)

    # At step 8 (the threshold) the warning fires as its own user message
    deps.step_count = 8
    assert manager.evaluate_step_budget_warning!(false)
    assert_includes deps.history.last[:content], "<step_budget"
    assert_equal 8, events.last[:current], "the threshold crossing must emit a :step_warning event"
  end

  def test_track_token_usage
    res = Rubik::LLM::Response.new(text: "hi", usage: { input_tokens: 15, output_tokens: 25 })
    @loop.budget_manager.track_token_usage!(res)
    assert_equal 15, @loop.total_tokens[:input]
    assert_equal 25, @loop.total_tokens[:output]
  end

  def test_handle_finish_tool
    res = @loop.step_executor.handle_finish_tool({ "message" => "Goal reached" }, "Thought text", "manual")
    assert res[:ok]
    assert_includes res[:output], "Goal reached"
  end

  def test_handle_invalid_tool_retry_and_fatal
    # First invalid tool call logs error in history and returns nil
    res1 = @loop.step_executor.handle_invalid_tool("unknown_tool", "call_1")
    assert_nil res1
    assert_equal 1, @loop.invalid_tool_count, "invalid_tool_count is a public attr_reader on Loop"
    assert_equal "tool", @loop.history.last[:role]
    assert_equal :error, @loop.history.last[:status]

    # Second invalid tool call returns fatal error result
    res2 = @loop.step_executor.handle_invalid_tool("unknown_tool", "call_2")
    refute res2[:ok]
    assert_includes res2[:error], "Repeated invalid tool call"
  end

  def test_execute_registered_tool
    tool = @registry.get("write_file")
    res = @loop.step_executor.execute_registered_tool(tool, "write_file", { "path" => "hello.txt", "content" => "world" }, "call_w", "manual")
    assert_equal :ok, res.status
    assert_equal "world", @buffer_manager.read("hello.txt")
  end
end
