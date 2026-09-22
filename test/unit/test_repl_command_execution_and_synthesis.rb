# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestReplCommandExecutionAndSynthesis < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @temp_home = Dir.mktmpdir
    @output = StringIO.new
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @shell = Rubik::REPL::Shell.new(
      config: @config,
      buffer_manager: @buffer_manager,
      output: @output
    )
    @overlay_storage = Rubik::Runtime::OverlayStorage.new(root_dir: @temp_dir, home_dir: @temp_home)
    @exec_tool = Rubik::Tools::ExecReplCommandTool.new(@shell)
    @synth_tool = Rubik::Tools::SynthesizeCommandTool.new(@shell, @overlay_storage)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
    FileUtils.remove_entry(@temp_home)
  end

  def test_llm_can_execute_repl_status_and_diff
    @buffer_manager.write("test.rb", "puts 'hello'")

    out = @exec_tool.execute("command" => "!diff")
    assert_includes out, "test.rb"
    assert_includes out, "puts 'hello'"

    out_status = @exec_tool.execute("command" => "!status")
    assert_includes out_status, "Project:"
    assert_includes out_status, "Default Model:"
  end

  def test_llm_can_update_model_and_context_via_repl
    res = @exec_tool.execute("command" => "!model set fast ollama/qwen2.5-coder:7b")
    assert_includes res, "Set model role 'fast' to ollama/qwen2.5-coder:7b"
    assert_equal "qwen2.5-coder:7b", @config.model_spec(:fast)["name"]

    ctx_res = @exec_tool.execute("command" => "!context scan")
    assert_includes ctx_res, "Context index"
  end

  def test_llm_synthesize_session_command
    code = '->(args, out) { out.puts "Seeding completed for #{args.first || "default"}" }' # rubocop:disable Lint/InterpolationCheck -- sentezlenen lambda kaynak kodu; #{} burada literal kalmalı
    synth_res = @synth_tool.execute(
      "name" => "db_seed",
      "description" => "Seed test database",
      "scope" => "session",
      "code" => code
    )

    assert_includes synth_res, "Successfully synthesized and registered !db_seed"

    # Verify execution via LLM exec tool
    exec_res = @exec_tool.execute("command" => "!db_seed users")
    assert_equal "Seeding completed for users", exec_res

    # Plan 53: synthesized commands are published to the agent via
    # <custom_commands>; the full !commands dump is reserved for the operator.
    xml = Rubik::Prompt::ContextBuilder.build_commands_xml(@shell)
    assert_includes xml, '<command name="!db_seed">Seed test database [session]</command>'
    cmds_out = @exec_tool.execute("command" => "!commands")
    assert_includes cmds_out, "'!commands' is reserved for the human operator"
  end

  def test_llm_synthesize_project_command_persists_and_reloads
    code = '->(args, out) { out.puts "Docker build tag: #{args.first || "latest"}" }' # rubocop:disable Lint/InterpolationCheck -- sentezlenen lambda kaynak kodu; #{} burada literal kalmalı
    synth_res = @synth_tool.execute(
      "name" => "docker_build",
      "description" => "Build project container",
      "scope" => "project",
      "code" => code
    )

    assert_includes synth_res, "Successfully synthesized and registered !docker_build"

    # Verify file was written into .rubik/commands/
    project_file = File.join(@temp_dir, ".rubik", "commands", "docker_build.rb")
    assert File.exist?(project_file)
    assert_includes File.read(project_file), "Docker build tag"

    # Verify new shell automatically auto-loads it on startup
    new_output = StringIO.new
    new_shell = Rubik::REPL::Shell.new(
      config: @config,
      buffer_manager: @buffer_manager,
      output: new_output
    )

    new_exec = Rubik::Tools::ExecReplCommandTool.new(new_shell)
    res = new_exec.execute("command" => "!docker_build v2.0")
    assert_equal "Docker build tag: v2.0", res
  end

  def test_syntax_error_in_synthesis_is_safely_rejected
    invalid_code = "->(args) { def missing_end"
    synth_res = @synth_tool.execute(
      "name" => "bad_cmd",
      "code" => invalid_code
    )

    assert_includes synth_res, "Syntax error in synthesized code"
  end

  def test_sh_command_uses_shell_sandbox_runner
    mock_runner = Object.new
    executed_command = nil
    mock_runner.define_singleton_method(:run) do |cmd|
      executed_command = cmd
      { output: "mocked output from sandbox runner", exit_code: 0 }
    end

    @shell.instance_variable_set(:@sandbox_runner, mock_runner)
    @shell.execute_input("!sh echo test_sandbox")

    assert_equal "echo test_sandbox", executed_command
    assert_includes @output.string, "mocked output from sandbox runner"
  end

  def test_sh_warns_on_unapplied_buffer_in_manual_mode
    mock_runner = Object.new
    mock_runner.define_singleton_method(:run) { |_cmd| { output: "ran", exit_code: 0 } }
    @shell.instance_variable_set(:@sandbox_runner, mock_runner)

    @buffer_manager.write("staged.rb", "# staged")
    @shell.execute_input("!sh echo probe")

    assert_includes @output.string, "Unapplied buffer changes exist. Commands run against files on disk."
    assert_includes @output.string, "ran"
    refute File.exist?(File.join(@temp_dir, "staged.rb")), "manual mode must not touch disk"
  end

  def test_sh_auto_applies_with_unified_copy_in_on_test_mode
    mock_runner = Object.new
    mock_runner.define_singleton_method(:run) { |_cmd| { output: "ran", exit_code: 0 } }
    @shell.instance_variable_set(:@sandbox_runner, mock_runner)
    @config.set("buffer.auto_apply", "on_test")

    @buffer_manager.write("staged.rb", "# staged")
    @shell.execute_input("!sh echo probe")

    assert_includes @output.string,
                    "[Rubik::Buffer] Auto-applied 1 modified file(s) before command execution.",
                    "!sh copy now matches the unified 'modified file(s)' vocabulary"
    assert File.exist?(File.join(@temp_dir, "staged.rb"))
  end

  def test_test_command_auto_applies_in_on_test_mode
    adapter = Object.new
    adapter.define_singleton_method(:run_tests) { |_dir| { ok: true, output: "All green" } }
    registry = Object.new
    registry.define_singleton_method(:get) { |_lang| adapter }
    @shell.instance_variable_set(:@adapter_registry, registry)
    @config.set("buffer.auto_apply", "on_test")

    @buffer_manager.write("staged.rb", "# staged")
    @shell.execute_input("!test")

    assert_includes @output.string, "Auto-applied 1 modified file(s) before test run."
    assert File.exist?(File.join(@temp_dir, "staged.rb"))
  end

  def test_sandbox_repl_command_status_on_off_and_driver_selection
    # 1. Status
    @output.reopen
    @shell.execute_input("!sandbox status")
    assert_includes @output.string, "Sandbox Durumu"
    assert_includes @output.string, "bwrap"

    # 2. Enable sandbox
    @output.reopen
    @shell.execute_input("!sandbox on")
    assert @config.fetch("sandbox.enabled")
    assert_includes @output.string, "[Sandbox] Enabled"

    # 3. Disable sandbox
    @output.reopen
    @shell.execute_input("!sandbox off")
    refute @config.fetch("sandbox.enabled")
    assert_includes @output.string, "[Sandbox] Disabled"

    # 4. Set specific driver
    @output.reopen
    @shell.execute_input("!sandbox bwrap")
    assert @config.fetch("sandbox.enabled")
    assert_equal "bwrap", @config.fetch("sandbox.driver")
    assert_includes @output.string, "[Sandbox] Driver set to 'bwrap'"
  end
end
