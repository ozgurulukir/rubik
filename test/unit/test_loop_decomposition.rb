# frozen_string_literal: true

require_relative "../test_helper"

class TestLoopDecomposition < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_decomp_test")
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @registry = Rubik::Tools::Registry.new
    @registry.register(Rubik::Tools::ReadFileTool.new(@buffer_manager))
    @registry.register(Rubik::Tools::WriteFileTool.new(@buffer_manager))
    @registry.register(Rubik::Tools::FinishTool.new)

    @mock_provider = Class.new(Rubik::LLM::BaseProvider) do
      def complete(messages, opts = {})
        Rubik::LLM::Response.new(text: "ok")
      end
    end.new

    @loop = Rubik::Orchestrator::Loop.new(
      provider: @mock_provider,
      tool_registry: @registry,
      max_steps: 10,
      warn_at_ratio: 0.8,
      root_dir: @temp_dir
    )
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
  end

  def test_evaluate_step_budget_warning
    # At step 5 of 10 with warn_step 8, no warning
    refute @loop.send(:evaluate_step_budget_warning!, 8, false)

    # Set step_count to 8
    @loop.instance_variable_set(:@step_count, 8)
    warned = @loop.send(:evaluate_step_budget_warning!, 8, false)
    assert warned
    assert_includes @loop.history.last[:content], "<step_budget"
  end

  def test_track_token_usage
    res = Rubik::LLM::Response.new(text: "hi", usage: { input_tokens: 15, output_tokens: 25 })
    @loop.send(:track_token_usage!, res)
    assert_equal 15, @loop.total_tokens[:input]
    assert_equal 25, @loop.total_tokens[:output]
  end

  def test_extract_and_normalize_tool_calls_from_response_and_json
    # 1. Native tool calls
    res_native = Rubik::LLM::Response.new(
      text: "",
      tool_calls: [{ "tool" => "read_file", "args" => { "path" => "foo.rb" } }]
    )
    tcs = @loop.send(:extract_and_normalize_tool_calls, res_native, "")
    assert_equal 1, tcs.size
    assert tcs.first["id"].start_with?("call_")
    assert_equal "read_file", tcs.first["tool"]

    # 2. Text JSON tool call
    res_text = Rubik::LLM::Response.new(text: '```json\n{"tool": "write_file", "args": {"path": "bar.rb"}}\n```')
    tcs_parsed = @loop.send(:extract_and_normalize_tool_calls, res_text, res_text.text)
    assert_equal 1, tcs_parsed.size
    assert_equal "write_file", tcs_parsed.first["tool"]
  end

  def test_handle_finish_tool
    res = @loop.send(:handle_finish_tool, { "message" => "Goal reached" }, "Thought text", "manual")
    assert res[:ok]
    assert_includes res[:output], "Goal reached"
  end

  def test_handle_invalid_tool_retry_and_fatal
    # First invalid tool call logs error in history and returns nil
    res1 = @loop.send(:handle_invalid_tool, "unknown_tool", "call_1")
    assert_nil res1
    assert_equal 1, @loop.instance_variable_get(:@invalid_tool_count)
    assert_equal "tool", @loop.history.last[:role]
    assert_equal :error, @loop.history.last[:status]

    # Second invalid tool call returns fatal error result
    res2 = @loop.send(:handle_invalid_tool, "unknown_tool", "call_2")
    refute res2[:ok]
    assert_includes res2[:error], "Repeated invalid tool call"
  end

  def test_execute_registered_tool
    tool = @registry.get("write_file")
    res = @loop.send(:execute_registered_tool, tool, "write_file", { "path" => "hello.txt", "content" => "world" }, "call_w", "manual")
    assert_equal :ok, res.status
    assert_equal "world", @buffer_manager.read("hello.txt")
  end
end
