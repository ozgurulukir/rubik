# frozen_string_literal: true

require_relative "../test_helper"

class TestSynthesis < Minitest::Test
  class DuckContext
    attr_reader :inverses, :disposed

    def initialize
      @inverses = []
      @disposed = false
    end

    def on_dispose(&block)
      @inverses << block
    end

    def dispose
      @disposed = true
      @inverses.reverse_each(&:call)
    end
  end

  def setup
    @tool_registry = Rubik::Tools::Registry.new
    @temp_dir = Dir.mktmpdir
    @overlay_storage = Rubik::Runtime::OverlayStorage.new(root_dir: @temp_dir)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_tool_with_runtime_failure_without_test_args_is_not_registered
    synthesizer = Rubik::Tools::SynthesizeToolTool.new(@tool_registry, @overlay_storage)

    code = "->(args) { raise 'runtime crash on call' }"
    res = synthesizer.execute(
      "name" => "failing_runtime_tool",
      "description" => "Fails at runtime",
      "code" => code
    )

    assert_includes res, "Pre-flight verification failed for tool 'failing_runtime_tool'"
    assert_nil @tool_registry.get("failing_runtime_tool"), "Tool must not be registered when preflight fails"
  end

  def test_tool_with_safe_code_without_test_args_runs_default_preflight_and_registers
    synthesizer = Rubik::Tools::SynthesizeToolTool.new(@tool_registry, @overlay_storage)

    code = "->(args) { 'preflight safe default' }"
    res = synthesizer.execute(
      "name" => "safe_default_tool",
      "description" => "Safe without test_args",
      "code" => code
    )

    assert_includes res, "Successfully synthesized and registered"
    assert_includes res, "Pre-flight verified with default arguments"
    refute_nil @tool_registry.get("safe_default_tool")
  end

  def test_unregister_inverse_installed_on_duck_typed_context
    duck_ctx = DuckContext.new
    manager_double = Struct.new(:context).new(duck_ctx)
    synthesizer = Rubik::Tools::SynthesizeToolTool.new(@tool_registry, @overlay_storage, nil, runtime_manager: manager_double)

    res = synthesizer.execute(
      "name" => "duck_registered_tool",
      "description" => "Registered with duck context",
      "code" => "->(args) { 'ok' }"
    )
    assert_includes res, "Successfully synthesized"
    refute_nil @tool_registry.get("duck_registered_tool")

    assert_equal 1, duck_ctx.inverses.size, "Inverse hook must be registered even on duck-typed context"

    duck_ctx.dispose
    assert_nil @tool_registry.get("duck_registered_tool"), "Tool must be unregistered when context disposes"
  end

  def test_command_unregister_inverse_installed_on_duck_typed_context
    duck_ctx = DuckContext.new
    manager_double = Struct.new(:context).new(duck_ctx)
    shell = Rubik::REPL::Shell.new(output: StringIO.new)
    synthesizer = Rubik::Tools::SynthesizeCommandTool.new(shell, @overlay_storage, nil, runtime_manager: manager_double)

    res = synthesizer.execute(
      "name" => "duck_cmd",
      "description" => "Duck cmd",
      "code" => "->(args, out) { out.puts 'hi' }"
    )
    assert_includes res, "Successfully synthesized and registered !duck_cmd"
    refute_nil shell.commands["duck_cmd"]

    assert_equal 1, duck_ctx.inverses.size
    duck_ctx.dispose
    assert_nil shell.commands["duck_cmd"], "Command must be unregistered when context disposes"
  end

  def test_parameterized_and_no_arg_synthesized_tools_expose_expected_input_schemas
    synthesizer = Rubik::Tools::SynthesizeToolTool.new(@tool_registry, @overlay_storage)

    param_schema = {
      type: "object",
      properties: { query: { type: "string", description: "Search term" } },
      required: ["query"]
    }
    res_param = synthesizer.execute(
      "name" => "param_tool",
      "description" => "Accepts query",
      "params_schema" => param_schema,
      "code" => "->(args) { \"query: \#{args['query'] || args[:query]}\" }",
      "test_args" => { "query" => "ok" }
    )
    assert_includes res_param, "Successfully synthesized"
    param_entry = @tool_registry.schemas.find { |s| s[:name] == "param_tool" }
    refute_nil param_entry
    assert_equal param_schema, param_entry[:parameters]

    res_no_arg = synthesizer.execute(
      "name" => "no_arg_tool",
      "description" => "Takes no arguments",
      "code" => "->(_args) { 'pong' }"
    )
    assert_includes res_no_arg, "Successfully synthesized"
    no_arg_entry = @tool_registry.schemas.find { |s| s[:name] == "no_arg_tool" }
    refute_nil no_arg_entry
    assert_equal({ type: "object", properties: {} }, no_arg_entry[:parameters])
  end
end
