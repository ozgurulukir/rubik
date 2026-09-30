# frozen_string_literal: true

require_relative "../test_helper"

class TestStructuredContextBuilder < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @agents_md = File.join(@temp_dir, "AGENTS.md")
    File.write(@agents_md, "# Test Protocol\n- Invariant Omega LIFO")

    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @snapshot_store = Rubik::Buffer::SnapshotStore.new
    @context_index = Rubik::Context::Index.new(root_dir: @temp_dir)
    @shell = Rubik::REPL::Shell.new(
      buffer_manager: @buffer_manager,
      snapshot_store: @snapshot_store,
      output: StringIO.new
    )
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_find_and_build_protocol_xml
    files = Rubik::Prompt::ContextBuilder.find_protocol_files(@temp_dir)
    assert_equal 1, files.size
    assert_equal "AGENTS.md", files.first[:path]

    xml = Rubik::Prompt::ContextBuilder.build_protocol_xml(@temp_dir)
    assert_includes xml, '<protocol source="AGENTS.md">'
    assert_includes xml, "# Test Protocol"
    assert_includes xml, "- Invariant Omega LIFO"
    assert_includes xml, "</protocol>"
  end

  def test_system_context_publishes_environment_line
    xml = Rubik::Prompt::ContextBuilder.build_system_context(config: @config)
    assert_includes xml, "<environment os="
    assert_includes xml, "shell=\""

    auto_line = Rubik::Sandbox::ShellResolver.environment_line("auto", platform: Rubik::Platform.os_family)
    assert_includes xml, auto_line

    fixed = Rubik::Prompt::ContextBuilder.build_system_context(config: { "sandbox.shell" => "pwsh" })
    assert_includes fixed, 'shell="pwsh"'
  end

  def test_build_workspace_xml
    xml = Rubik::Prompt::ContextBuilder.build_workspace_xml(@context_index, @temp_dir)
    assert_includes xml, "<workspace_status>"
    assert_includes xml, "<project_name>"
    assert_includes xml, "<git_branch>"
    assert_includes xml, "<languages>"
    assert_includes xml, "<workspace_files count="
    assert_includes xml, "</workspace_status>"
  end

  def test_build_buffer_xml_clean_and_dirty
    # Clean buffer
    clean_xml = Rubik::Prompt::ContextBuilder.build_buffer_xml(@buffer_manager, @snapshot_store)
    assert_includes clean_xml, 'dirty="false"'
    assert_includes clean_xml, '<dirty_files count="0">'

    # Dirty buffer
    @buffer_manager.write("dirty_file.rb", "puts 123")
    dirty_xml = Rubik::Prompt::ContextBuilder.build_buffer_xml(@buffer_manager, @snapshot_store)
    assert_includes dirty_xml, 'dirty="true"'
    assert_includes dirty_xml, '<dirty_files count="1">'
    assert_includes dirty_xml, "<file>dirty_file.rb</file>"
  end

  def test_build_operational_rules_xml
    xml = Rubik::Prompt::ContextBuilder.build_operational_rules_xml
    assert_includes xml, "<operational_rules>"
    assert_includes xml, "Code Exploration & Review"
    assert_includes xml, "REPL Bang Commands"
    assert_includes xml, "</operational_rules>"
  end

  def test_build_commands_xml
    # Built-in agent-visible commands are name-listed under <agent_commands> (Plan 53)
    xml = Rubik::Prompt::ContextBuilder.build_commands_xml(@shell)
    assert_includes xml, "<agent_commands"
    assert_includes xml, "!diff"
    assert_includes xml, "!undo"
    assert_includes xml, "!model"
    refute_includes xml, "<repl_commands>"
    refute_includes xml, "!quit"
    refute_includes xml, "<command name="

    # When custom command is added -> also returns <custom_commands>
    @shell.register_command("db_seed", description: "Seed the test database", custom: true) { "seeded" }
    custom_xml = Rubik::Prompt::ContextBuilder.build_commands_xml(@shell)
    assert_includes custom_xml, "<custom_commands>"
    assert_includes custom_xml, '<command name="!db_seed">Seed the test database</command>'
    assert_includes custom_xml, "</custom_commands>"
  end

  def test_build_system_prompt_structure
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :goal,
      tool_schemas: [{ "name" => "test_tool" }],
      shell: @shell,
      buffer_manager: @buffer_manager,
      snapshot_store: @snapshot_store,
      context_index: @context_index,
      root_dir: @temp_dir
    )

    assert_includes prompt, "AUTONOMOUS GOAL mode"
    assert_includes prompt, "<system_context>"
    assert_includes prompt, "<operational_rules>"
    assert_includes prompt, '<protocol source="AGENTS.md">'
    assert_includes prompt, "<workspace_status>"
    refute_includes prompt, "<repl_commands>"
    assert_includes prompt, "</system_context>"
  end

  def test_goal_mode_header_mandates_subagent_pipeline
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :goal,
      tool_schemas: [{ "name" => "test_tool" }],
      shell: @shell,
      buffer_manager: @buffer_manager,
      snapshot_store: @snapshot_store,
      context_index: @context_index,
      root_dir: @temp_dir
    )

    assert_includes prompt, "SUPERVISOR", "init-0 must be framed as the pipeline supervisor"
    assert_includes prompt, "(maestro)", "header must pin the pure-orchestrator doctrine"
    assert_includes prompt, "never in yours", "all research/code/verification belongs to subagent contexts"
    assert_includes prompt, "Keep YOUR context lean", "header must forbid code/test dumps in init-0's context"
    assert_includes prompt, "invoke_subagent", "header must mandate subagent dispatch"
    assert_includes prompt, "'coder'", "header must pin the coder archetype for file changes"
    assert_includes prompt, "extend_budget", "header must teach budget escalation over task absorption"
    assert_includes prompt, "rubik://goal/state", "header must publish the live goal snapshot URL"
    assert_includes prompt, "run_tests", "verification duty stays explicit (delegated verifier stage)"
    assert_includes prompt, "ask_question", "header must keep the init-0 answering duty"
    refute_includes prompt, "run final `run_tests` yourself",
                    "the self-verification clause must be gone — verification is delegated"
    refute_includes prompt, "Use `write_file` to prepare changes",
                    "old inline-implementer language must be gone"
  end

  def test_format_user_task
    task_xml = Rubik::Prompt::ContextBuilder.format_user_task("Fix the test suite")
    assert_equal "<user_task>\nFix the test suite\n</user_task>", task_xml
  end

  def test_loop_generates_xml_context_and_task
    mock_provider = Class.new do
      def complete(_messages, _opts = {})
        Struct.new(:text, :usage, :tool_calls?).new("Done", { input_tokens: 10, output_tokens: 5 }, false)
      end
    end.new

    loop_engine = Rubik::Orchestrator::Loop.new(
      provider: mock_provider,
      tool_registry: Rubik::Tools::Registry.new,
      shell: @shell
    )

    res = loop_engine.run("Implement new feature")
    assert res[:ok]
    assert_equal "Done", res[:output]

    # Verify history contains XML boundaries
    system_msg = loop_engine.history.find { |m| m[:role] == "system" }
    assert_includes system_msg[:content], "<system_context>"
    assert_includes system_msg[:content], '<protocol source="AGENTS.md">'

    user_msg = loop_engine.history.find { |m| m[:role] == "user" }
    assert_includes user_msg[:content], "<user_task>"
    assert_includes user_msg[:content], "Implement new feature"
    assert_includes user_msg[:content], "</user_task>"
  end

  def test_build_system_prompt_includes_output_budget_and_rule_six
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :default,
      shell: @shell,
      context_limit: 32_768,
      max_output_tokens: 16_384,
      root_dir: @temp_dir
    )

    assert_includes prompt, '<context_budget limit="32768" unit="tokens" />'
    assert_includes prompt, '<output_budget limit="16384" unit="tokens" />'
    assert_includes prompt, "6. Output Budget & Conciseness: Respect your output token budget"
  end
end
