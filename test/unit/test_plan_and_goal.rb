# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestPlanAndGoal < Minitest::Test
  class MockScriptProvider < Rubik::LLM::BaseProvider
    def initialize(responses)
      @responses = responses.dup
    end

    def complete(_messages, _opts = {})
      text = @responses.shift || '{"tool": "finish", "args": { "message": "done" }}'
      Rubik::LLM::Response.new(text: text, usage: { input_tokens: 10, output_tokens: 20 })
    end
  end

  def setup
    @temp_dir = Dir.mktmpdir("rubik_plan_test")
    @temp_home = Dir.mktmpdir("rubik_plan_home")
    @output = StringIO.new
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @shell = Rubik::REPL::Shell.new(config: @config, buffer_manager: @buffer_manager, output: @output)
  end

  def teardown
    @shell&.stop
    FileUtils.remove_entry(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
    FileUtils.remove_entry(@temp_home) if @temp_home && File.exist?(@temp_home)
  end

  def test_plan_command_formulates_plan_and_executes_on_approval
    plan_output = "1. Inspect lib/app.rb\n2. Add helper method\n3. Run tests"
    execution_output = '{"tool": "write_file", "args": { "path": "lib/app.rb", "content": "def helper; 42; end" }}'
    finish_output = '{"tool": "finish", "args": { "message": "Plan executed successfully" }}'

    mock_provider = MockScriptProvider.new([plan_output, execution_output, finish_output])
    @shell.instance_variable_get(:@llm_registry).register("ollama", mock_provider)

    @shell.execute_input("!plan Create helper method in lib/app.rb")

    out = @output.string
    assert_includes out, "=== Proposed Plan ==="
    assert_includes out, "1. Inspect lib/app.rb"
    assert_includes out, "Executing approved plan"
    assert @buffer_manager.dirty?
    assert_equal "def helper; 42; end", @buffer_manager.read("lib/app.rb")
  end

  def test_goal_command_executes_autonomous_loop
    responses = [
      '{"tool": "list_files", "args": {}}',
      '{"tool": "write_file", "args": { "path": "lib/calc.rb", "content": "class Calc; def add(a,b); a+b; end; end" }}',
      '{"tool": "run_command", "args": { "command": "echo \'test ok\'" }}',
      '{"tool": "finish", "args": { "message": "Calculator implemented and verified" }}'
    ]

    mock_provider = MockScriptProvider.new(responses)
    @shell.instance_variable_get(:@llm_registry).register("ollama", mock_provider)

    @shell.execute_input("!goal Implement Calculator with addition")

    out = @output.string
    assert_includes out, "[Rubik::Goal] Starting autonomous goal loop"
    assert_includes out, "Goal Achieved"
    assert_includes out, "Calculator implemented and verified"
    assert @buffer_manager.dirty?
    assert_includes @buffer_manager.read("lib/calc.rb"), "class Calc"
  end
end
