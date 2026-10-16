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
    xml = Rubik::Prompt::ContextBuilder.build_system_context(services: Rubik::Prompt::Services.new(config: @config))
    assert_includes xml, "<environment os="
    assert_includes xml, "shell=\""

    auto_line = Rubik::Sandbox::ShellResolver.environment_line("auto", platform: Rubik::Platform.os_family)
    assert_includes xml, auto_line

    fixed = Rubik::Prompt::ContextBuilder.build_system_context(services: Rubik::Prompt::Services.new(config: { "sandbox.shell" => "pwsh" }))
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

  def test_operational_rules_xml
    xml = Rubik::Prompt::Doctrine.operational_rules_xml
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
      services: Rubik::Prompt::Services.new(
        buffer_manager: @buffer_manager, snapshot_store: @snapshot_store,
        context_index: @context_index, root_dir: @temp_dir
      )
    )

    assert_includes prompt, "AUTONOMOUS GOAL mode"
    assert_includes prompt, "<system_context>"
    assert_includes prompt, "<operational_rules>"
    assert_includes prompt, '<protocol source="AGENTS.md">'
    assert_includes prompt, "<workspace_status>"
    refute_includes prompt, "<repl_commands>"
    assert_includes prompt, "</system_context>"
  end

  # Doctrine header/header-doctrine pins moved to test_prompt_doctrine
  # (Phase 4: tests assert invariants against the Doctrine SSOT; this
  # file keeps assembler structure). The two tests below pin the
  # services-view surface added by the prompt policy seam.

  def test_prompt_renders_with_an_empty_services_view
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(mode: :default, services: Rubik::Prompt::Services.new(root_dir: @temp_dir))

    assert_kind_of String, prompt
    assert_includes prompt, "<system_context>"
    assert_includes prompt, "<operational_rules>"
    # Unsatisfied slots degrade to omitted sections — never a raise.
    # (<agent_commands is anchored on its section form: rule 4's PROSE
    # legitimately mentions the literal tag name.)
    refute_includes prompt, "<lsp_status"
    refute_includes prompt, "<lsp_diagnostics"
    refute_includes prompt, "<skills "
    refute_includes prompt, "<subagents "
    refute_includes prompt, "<agent_commands via="
  end

  def test_from_shell_collects_the_same_slots_an_explicit_view_would
    config = { "buffer.auto_apply" => "auto" }
    commands = { "db_seed" => { description: "Seed the test database", custom: true } }
    skills_index = [{ name: "s", description: "d", scope: "project" }]

    buffer_manager = @buffer_manager
    snapshot_store = @snapshot_store
    context_index = @context_index
    shell = Object.new
    shell.define_singleton_method(:config) { config }
    shell.define_singleton_method(:commands) { commands }
    shell.define_singleton_method(:buffer_manager) { buffer_manager }
    shell.define_singleton_method(:snapshot_store) { snapshot_store }
    shell.define_singleton_method(:context_index) { context_index }

    via_shell = Rubik::Prompt::Services.from_shell(shell, skills_index: skills_index, root_dir: @temp_dir)
    explicit = Rubik::Prompt::Services.new(
      config: config, commands: commands, buffer_manager: @buffer_manager,
      snapshot_store: @snapshot_store, context_index: @context_index,
      skills_index: skills_index, root_dir: @temp_dir
    )

    assert_equal explicit.to_a, via_shell.to_a, "from_shell must collect the same slots an explicit view would"
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
      services: Rubik::Prompt::Services.new(
        context_limit: 32_768, max_output_tokens: 16_384, root_dir: @temp_dir
      )
    )

    assert_includes prompt, '<context_budget limit="32768" unit="tokens" />'
    assert_includes prompt, '<output_budget limit="16384" unit="tokens" />'
    assert_includes prompt, "6. Output Budget & Conciseness: Respect your output token budget"
  end

  def test_build_system_prompt_filters_gated_tool_teachings_by_tool_schemas
    services = Rubik::Prompt::Services.new(
      root_dir: @temp_dir,
      type_registry: Rubik::Orchestrator::Subagent::TypeRegistry.new
    )
    minimal_schemas = [{ "name" => "read_file" }, { "name" => "invoke_subagent" }]
    prompt_without = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :goal,
      tool_schemas: minimal_schemas,
      native_tools: true,
      services: services
    )

    ["storage", "vakanuvis", "show_file", "prune_context"].each do |gated_tool|
      refute_includes prompt_without, Rubik::Prompt::ToolTeachings.teaching_for(gated_tool),
                      "system prompt must omit #{gated_tool} teaching when absent from tool_schemas"
    end
    refute_includes prompt_without, "Chronicler briefs",
                    "orchestration guidance must omit vakanuvis bullet when vakanuvis is absent from tool_schemas"

    full_schemas = minimal_schemas + [
      { "name" => "storage" }, { "name" => "vakanuvis" },
      { "name" => "show_file" }, { "name" => "prune_context" }
    ]
    prompt_with = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :goal,
      tool_schemas: full_schemas,
      native_tools: true,
      services: services
    )
    ["storage", "vakanuvis", "show_file", "prune_context"].each do |gated_tool|
      assert_includes prompt_with, Rubik::Prompt::ToolTeachings.teaching_for(gated_tool),
                      "system prompt must include #{gated_tool} teaching when present in tool_schemas"
    end
    assert_includes prompt_with, "Chronicler briefs"
  end

  def test_build_system_prompt_plan_mode_suppresses_tool_and_subagent_invocation_sections
    services = Rubik::Prompt::Services.new(
      commands: { "db_seed" => { description: "Seed the test database", custom: true } },
      skills_index: [{ name: "s", description: "d", scope: "project" }],
      type_registry: Rubik::Orchestrator::Subagent::TypeRegistry.new,
      root_dir: @temp_dir
    )
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :plan,
      tool_schemas: [{ "name" => "read_file" }, { "name" => "invoke_subagent" }, { "name" => "skill" }],
      native_tools: true,
      services: services
    )

    assert_includes prompt, "No tools are exposed in PLAN-ONLY mode"
    assert_includes prompt, "1. Code Exploration & Review (PLAN-ONLY — no tool calls):"
    refute_includes prompt, "Available tools:"
    refute_includes prompt, "<custom_commands>"
    refute_includes prompt, "<skills "
    refute_includes prompt, "<subagents "
  end
end
