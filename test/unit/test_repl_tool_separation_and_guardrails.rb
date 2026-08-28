# frozen_string_literal: true

require_relative "../test_helper"

class TestReplToolSeparationAndGuardrails < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @snapshot_store = Rubik::Buffer::SnapshotStore.new
    @context_index = Rubik::Context::Index.new(root_dir: @temp_dir)
    @out = StringIO.new
    @shell = Rubik::REPL::Shell.new(
      buffer_manager: @buffer_manager,
      snapshot_store: @snapshot_store,
      output: @out,
      root_dir: @temp_dir
    )
    @exec_tool = Rubik::Tools::ExecReplCommandTool.new(@shell)
    @guard = Rubik::Security::Guard.new
    @overlay_storage = Rubik::Runtime::OverlayStorage.new(root_dir: @temp_dir, home_dir: @temp_dir)
    @synth_tool = Rubik::Tools::SynthesizeCommandTool.new(@shell, @overlay_storage, @guard)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_system_prompt_omits_builtin_repl_commands_and_contains_operational_rules
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :default,
      shell: @shell,
      buffer_manager: @buffer_manager,
      snapshot_store: @snapshot_store,
      context_index: @context_index,
      root_dir: @temp_dir
    )

    # Operational rules must be present
    assert_includes prompt, "<operational_rules>"
    assert_includes prompt, "1. Code Exploration & Review: Use native tools directly"
    assert_includes prompt, "2. Code Editing: Use `write_file` to stage changes into the in-memory buffer."
    assert_includes prompt, "3. Testing & Execution: Use native tools `run_tests` and `run_command` directly."
    assert_includes prompt, "4. REPL Bang Commands: `exec_repl_command` runs only the session-safe commands listed in <agent_commands>"
    assert_includes prompt, "</operational_rules>"

    # Agent-visible commands (<agent_commands>, Plan 53) must be present;
    # human-only and blocked commands must NOT leak, and the old full
    # <repl_commands> dump must stay gone.
    assert_includes prompt, "<agent_commands via=\"exec_repl_command\">"
    assert_includes prompt, "!diff"
    assert_includes prompt, "!undo"
    refute_includes prompt, "<repl_commands>"
    refute_includes prompt, "!quit"
    refute_includes prompt, "!plan"
    refute_includes prompt, "!allow"
    refute_includes prompt, "!provider "
    refute_includes prompt, "<command name=\"!test\">"
    refute_includes prompt, "<command name=\"!sh\">"
    refute_includes prompt, "<command name=\"!undo\">"
  end

  def test_dynamically_synthesized_commands_appear_in_custom_commands_xml
    # Initially: agent commands published, no custom commands yet
    xml = Rubik::Prompt::ContextBuilder.build_commands_xml(@shell)
    assert_includes xml, "<agent_commands via=\"exec_repl_command\">"
    refute_includes xml, "<custom_commands>"

    # Synthesize a custom command
    code = "->(args, out, shell) { out.puts 'Synthesized benchmark output' }"
    res = @synth_tool.execute("name" => "benchmark_db", "code" => code, "description" => "Custom DB benchmark", "scope" => "session")
    assert_includes res, "Successfully synthesized"

    # Verify custom flag is true in shell commands
    assert_equal true, @shell.commands["benchmark_db"][:custom]

    # Verify custom commands XML contains benchmark_db
    xml = Rubik::Prompt::ContextBuilder.build_commands_xml(@shell)
    assert_includes xml, "<custom_commands>"
    assert_includes xml, '<command name="!benchmark_db">Custom DB benchmark [session]</command>'
    assert_includes xml, "</custom_commands>"
    refute_includes xml, "<repl_commands>"

    # System prompt now includes <custom_commands>
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :default,
      shell: @shell,
      buffer_manager: @buffer_manager,
      snapshot_store: @snapshot_store,
      context_index: @context_index,
      root_dir: @temp_dir
    )
    assert_includes prompt, "<custom_commands>"
    assert_includes prompt, '<command name="!benchmark_db">'

    # Executing the custom command via exec_repl_command succeeds
    exec_res = @exec_tool.execute("command" => "!benchmark_db")
    assert_includes exec_res, "Synthesized benchmark output"
  end

  def test_overlay_storage_eval_command_sets_custom_flag
    code = "# Description: Overlay helper\n->(args, out) { out.puts 'Overlay OK' }"
    @overlay_storage.eval_command(@shell, "overlay_helper", code, :project)

    assert_equal true, @shell.commands["overlay_helper"][:custom]
    xml = Rubik::Prompt::ContextBuilder.build_commands_xml(@shell)
    assert_includes xml, '<command name="!overlay_helper">Overlay helper [project]</command>'
  end

  def test_exec_repl_command_redirects_known_direct_tools
    # !test redirect
    res_test = @exec_tool.execute("command" => "!test")
    assert_includes res_test, "Notice: Please use native tool 'run_tests' directly instead of exec_repl_command('!test')."

    # test without bang
    res_test_nobang = @exec_tool.execute("command" => "test spec/app_spec.rb")
    assert_includes res_test_nobang, "Notice: Please use native tool 'run_tests' directly instead of exec_repl_command('!test spec/app_spec.rb')."

    # !sh redirect
    res_sh = @exec_tool.execute("command" => "!sh echo hello")
    assert_includes res_sh, "Notice: Please use native tool 'run_command' directly instead of exec_repl_command('!sh echo hello')."

    # other redirects in REDIRECT_MAP
    Rubik::Tools::ExecReplCommandTool::REDIRECT_MAP.each do |cmd_name, tool_name|
      res = @exec_tool.execute("command" => "!#{cmd_name}")
      assert_includes res, "Notice: Please use native tool '#{tool_name}' directly"
    end
  end

  def test_exec_repl_command_unknown_commands_provide_helpful_guidance
    # Imaginary commands like !review, !check, !audit
    res_review = @exec_tool.execute("command" => "!review")
    assert_includes res_review, "Unknown REPL command '!review'."
    assert_includes res_review, "To explore files, read code, or perform a review, use direct tools ('list_files', 'read_file', 'search_symbols', 'get_outline') instead of REPL commands."
    refute_includes res_review, "Kullanılabilir komutlar:"

    res_check = @exec_tool.execute("command" => "!check")
    assert_includes res_check, "Unknown REPL command '!check'."
    assert_includes res_check, "To explore files, read code, or perform a review, use direct tools"
  end

  def test_exec_repl_command_legitimate_meta_commands_continue_to_work
    # !status
    res_status = @exec_tool.execute("command" => "!status")
    refute_includes res_status, "Notice: Please use native tool"
    refute_includes res_status, "Unknown REPL command"

    # !diff
    res_diff = @exec_tool.execute("command" => "!diff")
    refute_includes res_diff, "Notice: Please use native tool"
    refute_includes res_diff, "Unknown REPL command"

    # !runtime
    res_runtime = @exec_tool.execute("command" => "!runtime")
    refute_includes res_runtime, "Notice: Please use native tool"
    refute_includes res_runtime, "Unknown REPL command"
    assert_includes res_runtime, "Rubik Spatiotemporal Runtime Diagnostics"

    # !fibers
    res_fibers = @exec_tool.execute("command" => "!fibers")
    refute_includes res_fibers, "Unknown REPL command"

    # !services
    res_services = @exec_tool.execute("command" => "!services")
    refute_includes res_services, "Unknown REPL command"

    # !model
    res_model = @exec_tool.execute("command" => "!model")
    refute_includes res_model, "Unknown REPL command"

    # !config
    res_config = @exec_tool.execute("command" => "!config")
    refute_includes res_config, "Unknown REPL command"
  end

  def test_exec_repl_command_edge_cases
    # Empty command
    assert_equal "No command provided", @exec_tool.execute("command" => "")

    # Nil shell
    orphan_tool = Rubik::Tools::ExecReplCommandTool.new(nil)
    assert_equal "REPL shell is not connected", orphan_tool.execute("command" => "!status")

    # Blocked recursive plan / goal
    assert_includes @exec_tool.execute("command" => "!plan something"), "Nested !plan invocation inside tool call is blocked."
    assert_includes @exec_tool.execute("command" => "!goal something"), "Nested !goal invocation inside tool call is blocked."
  end
end
