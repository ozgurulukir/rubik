# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestNativeToolCallingAndRouter < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_proj")
    @temp_home = Dir.mktmpdir("rubik_home")
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @tool_reg = Rubik::Tools::Registry.build_default(buffer_manager: @buffer_manager, root_dir: @temp_dir)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
    FileUtils.remove_entry(@temp_home)
  end

  def test_router_roles_and_tuning
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    config.set_model_spec(:fast, provider: "ollama", name: "qwen2.5-coder:7b")
    config.set_model_spec(:advanced, provider: "openai", name: "gpt-4o")
    router = Rubik::LLM::Router.new(config: config)

    fast_route = router.route(task_type: :fast)
    assert_equal :fast, fast_route[:role]
    assert_equal "qwen2.5-coder:7b", fast_route[:model]

    adv_route = router.route(task_type: :advanced)
    assert_equal :advanced, adv_route[:role]
    assert_equal "gpt-4o", adv_route[:model]

    auto_adv = router.route(task_type: :auto, prompt: "Refactor architecture and plan whole system")
    assert_equal :advanced, auto_adv[:role]

    auto_fast = router.route(task_type: :auto, prompt: "Fix syntax error on line 4")
    assert_equal :fast, auto_fast[:role]
  end

  def test_router_manual_mode
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    config.set_model_spec(:default, provider: "ollama", name: "default-model")
    config.set_model_spec(:advanced, provider: "openai", name: "gpt-4o")
    config.data["router"]["mode"] = "manual"
    router = Rubik::LLM::Router.new(config: config)

    routed = router.route(task_type: :auto, prompt: "Full architecture plan")
    assert_equal :default, routed[:role]
    assert_equal "default-model", routed[:model]
  end

  def test_orchestrator_native_tool_calling_flow
    native_mock_provider = Class.new(Rubik::LLM::BaseProvider) do
      def initialize
        @called = false
      end

      def complete(_messages, opts = {})
        raise "Native tools schema should be passed" unless opts[:tools] && !opts[:tools].empty?

        if @called
          Rubik::LLM::Response.new(text: "Done", tool_calls: [])
        else
          @called = true
          Rubik::LLM::Response.new(
            text: "",
            tool_calls: [
              { "tool" => "write_file", "args" => { "path" => "native.rb", "content" => "NATIVE = true" } }
            ]
          )
        end
      end
    end.new

    orchestrator = Rubik::Orchestrator::Loop.new(
      provider: native_mock_provider,
      tool_registry: @tool_reg,
      max_steps: 5
    )

    res = orchestrator.run("Create native.rb file")
    assert res[:ok]
    assert @buffer_manager.dirty?
    assert_equal "NATIVE = true", @buffer_manager.read("native.rb")
  end

  def test_shell_model_set_and_route_commands
    output = StringIO.new
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(config: cfg, buffer_manager: @buffer_manager, output: output)

    shell.execute_input("!model set fast ollama/fast-coder:3b")
    assert_includes output.string, "Set model role 'fast' to ollama/fast-coder:3b"

    output = StringIO.new
    shell.instance_variable_set(:@output, output)
    shell.execute_input("!model set advanced anthropic/claude-3-5-sonnet")
    assert_includes output.string, "Set model role 'advanced' to anthropic/claude-3-5-sonnet"

    output = StringIO.new
    shell.instance_variable_set(:@output, output)
    shell.execute_input("!model route manual")
    assert_includes output.string, "Router mode set to manual"

    output = StringIO.new
    shell.instance_variable_set(:@output, output)
    shell.execute_input("!model")
    assert_includes output.string, "Model Router Configuration (Mode: manual)"
    assert_includes output.string, "fast-coder:3b"
    assert_includes output.string, "claude-3-5-sonnet"
  end
end
