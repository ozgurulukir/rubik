# frozen_string_literal: true

require_relative "../test_helper"

class TestSynthesisSecurity < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_synth_sec")
    @guard = Rubik::Security::Guard.new
    @tool_registry = Rubik::Tools::Registry.new
    @overlay_storage = Rubik::Runtime::OverlayStorage.new(root_dir: @temp_dir, home_dir: @temp_dir)
    @runtime_manager = Rubik::Runtime::Manager.new(Rubik::Runtime::Context.new)

    @synth_tool = Rubik::Tools::SynthesizeToolTool.new(
      @tool_registry,
      @overlay_storage,
      @guard,
      runtime_manager: @runtime_manager
    )

    @shell_mock = Object.new
    @registered_commands = {}
    reg_cmds = @registered_commands
    @shell_mock.define_singleton_method(:commands) { {} }
    @shell_mock.define_singleton_method(:output) { StringIO.new }
    @shell_mock.define_singleton_method(:register_command) do |name, **_opts, &block|
      reg_cmds[name] = block
    end
    @shell_mock.define_singleton_method(:unregister_command) do |name|
      reg_cmds.delete(name)
    end

    @synth_cmd = Rubik::Tools::SynthesizeCommandTool.new(
      @shell_mock,
      @overlay_storage,
      @guard,
      runtime_manager: @runtime_manager
    )
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  def test_blocks_dangerous_code_in_synthesize_command
    res = @synth_cmd.execute(
      "name" => "evil_cmd",
      "code" => '->(args, out, shell) { system("rm -rf /") }'
    )

    assert_includes res, "Security blocked"
    refute @registered_commands.key?("evil_cmd")
  end

  def test_blocks_dangerous_code_in_synthesize_tool
    res = @synth_tool.execute(
      "name" => "evil_tool",
      "description" => "Deletes everything",
      "code" => "->(args) { `rm -rf /` }"
    )
    assert_includes res, "Security blocked"
    assert_nil @tool_registry.get("evil_tool")
  end

  def test_guard_downgrade_fallback_warns_loudly
    # Duck-typed guard without the synthesis check: the shell-only fallback
    # is a documented test-double affordance, but it skips the entire AST
    # deny surface — the downgrade must be loud (ungated warn), and benign
    # code must still register through it.
    duck_guard = Object.new
    def duck_guard.verify_command_safety!(*)
      true
    end

    tool = Rubik::Tools::SynthesizeToolTool.new(
      @tool_registry,
      @overlay_storage,
      duck_guard,
      runtime_manager: @runtime_manager
    )

    _out, err = capture_io do
      res = tool.execute(
        "name" => "duck_guarded",
        "description" => "benign",
        "code" => "->(args) { args['x'].to_s }"
      )
      refute_includes res, "Security blocked"
    end

    assert_includes err, "downgraded to shell-only gate"
  end

  def test_command_path_guard_downgrade_fallback_warns_loudly
    # Mirror of the tool-path downgrade pin: the !command builtin must warn
    # just as loudly when handed a duck-typed guard, and benign code must
    # still register through the shell-only gate.
    duck_guard = Object.new
    def duck_guard.verify_command_safety!(*)
      true
    end

    cmd = Rubik::Tools::SynthesizeCommandTool.new(
      @shell_mock,
      @overlay_storage,
      duck_guard,
      runtime_manager: @runtime_manager
    )

    _out, err = capture_io do
      res = cmd.execute(
        "name" => "duck_cmd",
        "code" => "->(args, out, shell) { out.puts args['x'].to_s }"
      )
      refute_includes res, "Security blocked"
    end

    assert_includes err, "downgraded to shell-only gate"
  end

  def test_blocks_thread_spawn_in_synthesized_code
    res = @synth_tool.execute(
      "name" => "thread_leaker",
      "description" => "Spawns unmanaged background thread",
      "code" => "->(args) { Thread.new { loop { sleep 1 } } }"
    )

    assert_includes res, "Security blocked"
    assert_nil @tool_registry.get("thread_leaker")
  end

  def test_command_preflight_failure_blocks_registration
    res = @synth_cmd.execute(
      "name" => "broken_cmd",
      "code" => '->(args) { raise "boom during preflight" }',
      "test_args" => { "sample" => true }
    )

    assert_includes res, "Pre-flight verification failed for command '!broken_cmd'"
    assert_includes res, "boom during preflight"
    refute @registered_commands.key?("broken_cmd")
  end

  def test_pre_flight_verification_times_out_safely
    res = @synth_tool.execute(
      "name" => "infinite_loop_tool",
      "description" => "Hangs indefinitely",
      "code" => "->(args) { sleep 10 }",
      "test_args" => { "input" => "test" }
    )

    assert_includes res, "Pre-flight verification failed"
    assert_includes res, "execution timed out after 5 seconds"
    assert_nil @tool_registry.get("infinite_loop_tool")
  end

  def test_safe_tool_synthesis_and_execution
    res = @synth_tool.execute(
      "name" => "double_num",
      "description" => "Doubles a number",
      "code" => '->(args) { (args["n"] || args[:n]).to_i * 2 }',
      "test_args" => { "n" => 21 }
    )

    assert_includes res, "Successfully synthesized and registered native tool 'double_num'"
    tool = @tool_registry.get("double_num")
    refute_nil tool
    assert_equal 84, tool.execute("n" => 42)
  end

  def test_safe_command_synthesis_and_execution
    res = @synth_cmd.execute(
      "name" => "ping_custom",
      "description" => "Custom ping command",
      "code" => '->(args, out, shell) { "pong: #{args}" }' # rubocop:disable Lint/InterpolationCheck -- sentezlenen lambda kaynak kodu; #{} burada literal kalmalı
    )

    assert_includes res, "Successfully synthesized and registered !ping_custom"
    assert @registered_commands.key?("ping_custom")
  end

  def test_lifo_context_disposal_cleans_synthesized_tool
    @synth_tool.execute(
      "name" => "temp_clean_tool",
      "description" => "Temporary tool",
      "code" => "->(args) { :ok }"
    )

    refute_nil @tool_registry.get("temp_clean_tool")
    @runtime_manager.context.dispose!
    assert_nil @tool_registry.get("temp_clean_tool"), "Tool should be unregistered upon context disposal"
  end

  def test_synthesized_tools_and_commands_do_not_leak_caller_lexical_scope
    res_tool = @synth_tool.execute(
      "name" => "scope_probe_tool",
      "description" => "Inspects scope",
      "code" => "->(args) { local_variables }",
      "test_args" => {}
    )
    assert_includes res_tool, "Successfully synthesized and registered native tool 'scope_probe_tool'"
    tool = @tool_registry.get("scope_probe_tool")
    tool_vars = tool.execute({})
    assert_equal [:args], tool_vars
    refute_includes tool_vars, :scope
    refute_includes tool_vars, :clean_name

    res_cmd = @synth_cmd.execute(
      "name" => "scope_probe_cmd",
      "description" => "Inspects scope",
      "code" => "->(args, out, shell) { local_variables }"
    )
    assert_includes res_cmd, "Successfully synthesized and registered !scope_probe_cmd"
    handler = @registered_commands["scope_probe_cmd"]
    cmd_vars = handler.call([])
    assert_equal [:args, :out, :shell], cmd_vars
    refute_includes cmd_vars, :scope
    refute_includes cmd_vars, :proc_handler
  end
end
