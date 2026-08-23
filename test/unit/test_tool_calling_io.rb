# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../../lib/rubik"

class TestToolCallingIO < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_tool_io_test")
    @home_dir = Dir.mktmpdir("rubik_tool_io_home")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @home_dir)
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
    FileUtils.rm_rf(@home_dir)
  end

  def test_tool_result_data_structure_and_xml
    res_ok = Rubik::Tools::Result.new(
      tool_name: "read_file",
      call_id: "call_abc123",
      status: :ok,
      output: "class App; end",
      duration_ms: 12.5,
      truncated: false
    )

    assert res_ok.ok?
    refute res_ok.error?
    assert_equal "class App; end", res_ok.to_s
    xml = res_ok.to_xml
    assert_includes xml, %(<tool_result tool="read_file" id="call_abc123" status="ok" duration_ms="12.5">)
    assert_includes xml, "class App; end"
    assert_includes xml, "</tool_result>"

    res_err = Rubik::Tools::Result.new(
      tool_name: "run_command",
      call_id: "call_err456",
      status: :error,
      error: "Command failed",
      output: "Error: exit code 1",
      duration_ms: 45.0
    )

    assert res_err.error?
    refute res_err.ok?
    err_xml = res_err.to_xml
    assert_includes err_xml, %(status="error")
    assert_includes err_xml, "Error: exit code 1"
  end

  def test_truncator_preserves_small_output
    small_text = "Line 1\nLine 2\nLine 3"
    res = Rubik::Tools::Truncator.truncate(small_text, max_chars: 100, max_lines: 10)
    refute res[:truncated]
    assert_equal small_text, res[:text]
    assert_equal 0, res[:omitted_lines]
  end

  def test_truncator_head_tail_truncation
    large_lines = (1..500).map { |i| "Log output line #{i} with some details" }.join("\n")
    res = Rubik::Tools::Truncator.truncate(large_lines, max_chars: 2000, max_lines: 50, strategy: :head_tail)

    assert res[:truncated]
    assert_includes res[:text], "Log output line 1"
    assert_includes res[:text], "Log output line 500"
    assert_includes res[:text], "Truncated:"
    assert_includes res[:text], "omitted to preserve token budget"
  end

  def test_loop_handles_tool_exceptions_gracefully
    mock_provider = Class.new do
      def complete(history, opts = {})
        @turns ||= 0
        @turns += 1
        if @turns == 1
          Struct.new(:text, :has_tool_calls?, :tool_calls, :usage).new(
            '{"tool": "buggy_tool", "args": {}}',
            true,
            [{ "id" => "call_bug1", "tool" => "buggy_tool", "args" => {} }],
            nil
          )
        else
          Struct.new(:text, :has_tool_calls?, :tool_calls, :usage).new(
            '{"tool": "finish", "args": { "message": "Recovered from tool error" }}',
            true,
            [{ "id" => "call_fin", "tool" => "finish", "args" => { "message": "Recovered from tool error" } }],
            nil
          )
        end
      end
    end.new

    buggy_tool = Class.new(Rubik::Tools::BaseTool) do
      def initialize
        super(name: "buggy_tool", description: "A tool that throws")
      end

      def execute(_args = {})
        raise Errno::EACCES, "Permission denied to secret file"
      end
    end.new

    tool_reg = Rubik::Tools::Registry.new
    tool_reg.register(buggy_tool)

    loop_instance = Rubik::Orchestrator::Loop.new(
      provider: mock_provider,
      tool_registry: tool_reg,
      max_steps: 5,
      root_dir: @temp_dir
    )

    # Must NOT raise exception!
    res = loop_instance.run("Run buggy operation")
    assert res[:ok]
    assert_equal "Recovered from tool error", res[:output]

    # Verify tool error was recorded in history as XML
    tool_entry = loop_instance.history.find { |m| m[:role] == "tool" && m[:tool_name] == "buggy_tool" }
    refute_nil tool_entry
    assert_equal :error, tool_entry[:status]
    assert_includes tool_entry[:content], 'status="error"'
    assert_includes tool_entry[:content], "Permission denied"
  end

  def test_openai_compatible_message_formatting
    provider = Rubik::LLM::OpenAICompatibleProvider.new(name: "test_openai")
    internal_msgs = [
      { role: "system", content: "You are an assistant." },
      { role: "user", content: "Write a test" },
      {
        role: "assistant",
        content: "I will write the test.",
        tool_calls: [{ "id" => "call_123", "tool" => "write_file", "args" => { "path" => "t.rb" } }]
      },
      {
        role: "tool",
        tool_call_id: "call_123",
        tool_name: "write_file",
        content: "<tool_result tool=\"write_file\" status=\"ok\">File written</tool_result>"
      }
    ]

    formatted = provider.send(:format_messages, internal_msgs)

    # 1. System and user unchanged
    assert_equal "system", formatted[0]["role"]
    assert_equal "user", formatted[1]["role"]

    # 2. Assistant message has native tool_calls
    assert_equal "assistant", formatted[2]["role"]
    assert_equal "I will write the test.", formatted[2]["content"]
    assert_equal 1, formatted[2]["tool_calls"].size
    assert_equal "call_123", formatted[2]["tool_calls"].first["id"]
    assert_equal "write_file", formatted[2]["tool_calls"].first.dig("function", "name")

    # 3. Tool message has role="tool" and tool_call_id
    assert_equal "tool", formatted[3]["role"]
    assert_equal "call_123", formatted[3]["tool_call_id"]
    assert_includes formatted[3]["content"], "File written"
  end

  def test_anthropic_message_formatting
    provider = Rubik::LLM::AnthropicProvider.new
    user_msgs = [
      { role: "user", content: "Calculate 2+2" },
      {
        role: "assistant",
        content: "Calculating...",
        tool_calls: [{ "id" => "call_calc", "tool" => "calculate", "args" => { "expr" => "2+2" } }]
      },
      {
        role: "tool",
        tool_call_id: "call_calc",
        tool_name: "calculate",
        content: "<tool_result tool=\"calculate\" status=\"ok\">4</tool_result>"
      }
    ]

    formatted = provider.send(:format_messages, user_msgs)

    # 1. Assistant has tool_use block
    assert_equal "assistant", formatted[1]["role"]
    content_blocks = formatted[1]["content"]
    assert_equal 2, content_blocks.size
    assert_equal "text", content_blocks[0]["type"]
    assert_equal "tool_use", content_blocks[1]["type"]
    assert_equal "call_calc", content_blocks[1]["id"]
    assert_equal "calculate", content_blocks[1]["name"]

    # 2. Tool response has tool_result block in user turn
    assert_equal "user", formatted[2]["role"]
    tool_res_block = formatted[2]["content"].first
    assert_equal "tool_result", tool_res_block["type"]
    assert_equal "call_calc", tool_res_block["tool_use_id"]
    assert_includes tool_res_block["content"], "<tool_result"
  end
end
