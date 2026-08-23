# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../../lib/rubik"

class TestAgentStepBudget < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_step_test")
    @home_dir = Dir.mktmpdir("rubik_step_home")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @home_dir)
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
    FileUtils.rm_rf(@home_dir)
  end

  def test_default_config_has_agent_step_knobs
    assert_equal 40, @config.fetch("agent.max_steps")
    assert_equal 80, @config.fetch("agent.goal_max_steps")
    assert_equal 15, @config.fetch("agent.plan_max_steps")
    assert_equal 0.75, @config.fetch("agent.warn_at_ratio")
    assert_equal true, @config.fetch("agent.ask_continue_on_limit")
  end

  def test_loop_triggers_step_warning_at_threshold
    warnings_captured = []
    # Mock provider that produces a message each time until max steps
    mock_provider = Class.new do
      def complete(history, opts = {})
        Struct.new(:text, :has_tool_calls?, :tool_calls, :usage).new(
          '{"tool": "list_files", "args": {}}',
          true,
          [{ "tool" => "list_files", "args" => {} }],
          nil
        )
      end
    end.new

    tool_reg = Rubik::Tools::Registry.new
    mock_tool = Class.new(Rubik::Tools::BaseTool) do
      def initialize; super(name: "list_files", description: "List files"); end
      def execute(_); "file1.rb"; end
    end.new
    tool_reg.register(mock_tool)

    loop_instance = Rubik::Orchestrator::Loop.new(
      provider: mock_provider,
      tool_registry: tool_reg,
      max_steps: 4,
      warn_at_ratio: 0.75,
      root_dir: @temp_dir,
      on_step: lambda { |step_info|
        if step_info[:type] == :step_warning
          warnings_captured << step_info
        end
      }
    )

    res = loop_instance.run("Infinite search")
    refute res[:ok]
    assert_includes res[:error], "Max steps budget exceeded (4)"
    assert_equal 4, res[:steps]

    # Verify warning was sent at step 3 (4 * 0.75 = 3)
    assert_equal 1, warnings_captured.size
    assert_equal 3, warnings_captured.first[:current]
    assert_equal 4, warnings_captured.first[:max]
    assert_equal 1, warnings_captured.first[:remaining]
  end

  def test_loop_continue_loop_extends_budget
    call_count = 0
    mock_provider = Class.new do
      def complete(history, opts = {})
        @count ||= 0
        @count += 1
        if @count < 4
          Struct.new(:text, :has_tool_calls?, :tool_calls, :usage).new(
            '{"tool": "list_files", "args": {}}',
            true,
            [{ "tool" => "list_files", "args" => {} }],
            nil
          )
        else
          Struct.new(:text, :has_tool_calls?, :tool_calls, :usage).new(
            '{"tool": "finish", "args": { "message": "All done successfully" }}',
            true,
            [{ "tool" => "finish", "args" => { "message": "All done successfully" } }],
            nil
          )
        end
      end
    end.new

    tool_reg = Rubik::Tools::Registry.new
    mock_tool = Class.new(Rubik::Tools::BaseTool) do
      def initialize; super(name: "list_files", description: "List files"); end
      def execute(_); "ok"; end
    end.new
    tool_reg.register(mock_tool)

    loop_instance = Rubik::Orchestrator::Loop.new(
      provider: mock_provider,
      tool_registry: tool_reg,
      max_steps: 2,
      root_dir: @temp_dir
    )

    # 1. First run exceeds budget of 2
    res = loop_instance.run("Multi-step task")
    refute res[:ok]
    assert_equal 2, res[:steps]

    # 2. Continue loop with +3 extra steps
    res_cont = loop_instance.continue_loop(3)
    assert res_cont[:ok]
    assert_equal "All done successfully", res_cont[:output]
    assert_equal 4, res_cont[:steps]
  end

  def test_repl_steps_command
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: @config, output: out)

    # 1. !steps status
    shell.execute_input("!steps status")
    assert_includes out.string, "=== Agentic Step Budget Configuration ==="
    assert_includes out.string, "Default Task Max Steps : 40"
    assert_includes out.string, "Goal Mode Max Steps    : 80"

    # 2. Change default max steps
    out.reopen
    shell.execute_input("!steps 50")
    assert_includes out.string, "Agent default max steps set to 50"
    assert_equal 50, @config.fetch("agent.max_steps")

    # 3. Change goal max steps
    out.reopen
    shell.execute_input("!steps goal 100")
    assert_includes out.string, "Goal mode max steps set to 100"
    assert_equal 100, @config.fetch("agent.goal_max_steps")

    # 4. Change plan max steps
    out.reopen
    shell.execute_input("!steps plan 25")
    assert_includes out.string, "Plan mode max steps set to 25"
    assert_equal 25, @config.fetch("agent.plan_max_steps")
  end
end
