# frozen_string_literal: true

require_relative "../test_helper"

class TestSecurityToolHardening < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_sec_test")
  end

  def teardown
    remove_temp_dir(@temp_dir)
  end

  def test_exec_repl_nested_agent_caller_preservation
    mock_shell = Class.new do
      attr_accessor :agent_caller

      def initialize
        @agent_caller = false
      end

      def commands
        {
          "test_cmd" => { audience: :agent, description: "test" }
        }
      end

      def capture_output
        yield
        "output"
      end

      def execute_input(_cmd)
        # Inside nested execution, agent_caller should be true
      end
    end.new

    tool = Rubik::Tools::ExecReplCommandTool.new(mock_shell)

    # Initial state is false (human operator)
    refute mock_shell.agent_caller
    tool.execute({ "command" => "!test_cmd" })
    # Restored to false
    refute mock_shell.agent_caller

    # When initially true (agent caller already in progress), it stays true after execution
    mock_shell.agent_caller = true
    tool.execute({ "command" => "!test_cmd" })
    assert mock_shell.agent_caller, "nested call must not reset outer agent_caller to false"
  end

  def test_run_command_timeout_clamped
    mock_runner = Class.new do
      attr_reader :last_timeout

      def run(_cmd, timeout: 30, **_rest)
        @last_timeout = timeout
        { ok: true, exit_code: 0, output: "done" }
      end
    end.new

    mock_guard = Object.new
    def mock_guard.verify_command_safety!(_cmd); end

    tool = Rubik::Tools::RunCommandTool.new(runner: mock_runner, guard: mock_guard, root_dir: @temp_dir)

    # Negative or 0 timeout clamped to 1
    tool.execute({ "command" => "echo 1", "timeout" => -5 })
    assert_equal 1, mock_runner.last_timeout

    tool.execute({ "command" => "echo 1", "timeout" => "0" })
    assert_equal 1, mock_runner.last_timeout

    # Excessive timeout clamped to 600
    tool.execute({ "command" => "echo 1", "timeout" => 9999 })
    assert_equal 600, mock_runner.last_timeout

    # Valid string timeout converted correctly
    tool.execute({ "command" => "echo 1", "timeout" => "45" })
    assert_equal 45, mock_runner.last_timeout
  end

  def test_adapter_registry_revertible_registration_with_context
    registry = Rubik::Adapter::Registry.new
    orig_ruby = registry.get("ruby")
    refute_nil orig_ruby

    ctx = Rubik::Runtime::Context.new
    mock_custom_ruby = Object.new
    registry.register("ruby", mock_custom_ruby, ctx: ctx)
    assert_equal mock_custom_ruby, registry.get("ruby")

    # Brand new language
    mock_lua = Object.new
    registry.register("lua", mock_lua, ctx: ctx)
    assert_equal mock_lua, registry.get("lua")

    # Disposing context restores previous adapter and deletes brand new adapter
    ctx.dispose

    assert_equal orig_ruby, registry.get("ruby"), "disposing context must restore original adapter"
    assert_nil registry.get("lua"), "disposing context must unregister ephemeral adapter"
  end

  def test_config_listener_error_emits_event
    cfg = Rubik::Config.new(root_dir: @temp_dir)
    event_bus = Rubik::EventBus.new
    cfg.event_bus = event_bus

    emitted_error = nil
    event_bus.subscribe(:config_listener_error) do |data|
      emitted_error = data
    end

    cfg.on_change("tools.timeout") do |_k, _new, _old|
      raise StandardError, "failing listener"
    end

    # Changing config value catches listener error, emits event, and does not raise
    cfg.set("tools.timeout", 50, persist: :session)

    assert emitted_error
    assert_equal "tools.timeout", emitted_error[:key]
    assert_includes emitted_error[:error], "failing listener"
  end
end
