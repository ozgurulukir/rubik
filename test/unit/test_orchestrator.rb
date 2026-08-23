# frozen_string_literal: true

require_relative "../test_helper"

class TestOrchestrator < Minitest::Test
  class MockScriptProvider < Rubik::LLM::BaseProvider
    def initialize(responses)
      @responses = responses.dup
    end

    def complete(messages, opts = {})
      text = @responses.shift || '{"tool": "finish", "args": { "message": "done" }}'
      Rubik::LLM::Response.new(text: text)
    end
  end

  def setup
    @temp_dir = Dir.mktmpdir
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @registry = Rubik::Tools::Registry.new

    @registry.register(Rubik::Tools::ReadFileTool.new(@buffer_manager))
    @registry.register(Rubik::Tools::WriteFileTool.new(@buffer_manager))
    @registry.register(Rubik::Tools::FinishTool.new)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_end_to_end_write_and_finish_loop
    script = [
      '{"tool": "write_file", "args": { "path": "fizzbuzz.rb", "content": "def fizzbuzz; end" }}',
      '{"tool": "finish", "args": { "message": "FizzBuzz module created in buffer" }}'
    ]

    provider = MockScriptProvider.new(script)
    orchestrator = Rubik::Orchestrator::Loop.new(provider: provider, tool_registry: @registry)

    res = orchestrator.run("Write FizzBuzz module")
    assert res[:ok]
    assert_equal "FizzBuzz module created in buffer", res[:output]
    assert @buffer_manager.dirty?
    assert_equal "def fizzbuzz; end", @buffer_manager.read("fizzbuzz.rb")
  end

  def test_invalid_tool_retry_and_termination
    script = [
      '{"tool": "non_existent_tool", "args": {}}',
      '{"tool": "non_existent_tool", "args": {}}'
    ]

    provider = MockScriptProvider.new(script)
    orchestrator = Rubik::Orchestrator::Loop.new(provider: provider, tool_registry: @registry)

    res = orchestrator.run("Do something impossible")
    refute res[:ok]
    assert_includes res[:error], "Repeated invalid tool call"
  end

  def test_multi_step_read_and_format_messages_call_id_matching
    File.write(File.join(@temp_dir, "README.md"), "# Go-HaYaP Project\nOverview of progress payment system.")

    openai_prov = Rubik::LLM::OpenAICompatibleProvider.new(
      name: "test_openai",
      endpoint: "http://localhost:9999/v1/chat/completions",
      api_key: "dummy"
    )

    received_messages_step2 = nil
    step = 0

    mock_provider = Class.new(Rubik::LLM::BaseProvider) do
      define_method(:complete) do |messages, opts = {}|
        step += 1
        if step == 1
          Rubik::LLM::Response.new(
            text: '{"tool": "read_file", "args": { "path": "README.md" }}'
          )
        else
          received_messages_step2 = messages
          Rubik::LLM::Response.new(
            text: "Go-HaYaP is a progress payment tracking system.",
            tool_calls: [{ "tool" => "finish", "args" => { "message" => "done" } }]
          )
        end
      end
    end.new

    orchestrator = Rubik::Orchestrator::Loop.new(
      provider: mock_provider,
      tool_registry: @registry,
      root_dir: @temp_dir
    )

    res = orchestrator.run("What is this project about?")
    assert res[:ok]
    assert_equal "Go-HaYaP is a progress payment tracking system.", res[:output]

    # Verify formatting of messages for OpenAI maintains identical IDs
    formatted = openai_prov.send(:format_messages, received_messages_step2)
    assistant_msg = formatted.find { |m| m["role"] == "assistant" && m["tool_calls"] }
    tool_msg = formatted.find { |m| m["role"] == "tool" }

    refute_nil assistant_msg
    refute_nil tool_msg

    assistant_call_id = assistant_msg["tool_calls"].first["id"]
    tool_response_id = tool_msg["tool_call_id"]

    assert_equal assistant_call_id, tool_response_id
    refute_empty assistant_call_id
  end
end
