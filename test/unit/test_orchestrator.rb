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
end
