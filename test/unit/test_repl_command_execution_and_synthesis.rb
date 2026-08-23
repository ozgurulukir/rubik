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
    code = '->(args, out) { out.puts "Seeding completed for #{args.first || "default"}" }'
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

    # Verify visible in REPL !commands list
    cmds_out = @exec_tool.execute("command" => "!commands")
    assert_includes cmds_out, "!db_seed"
    assert_includes cmds_out, "[session]"
  end

  def test_llm_synthesize_project_command_persists_and_reloads
    code = '->(args, out) { out.puts "Docker build tag: #{args.first || "latest"}" }'
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
end
