# frozen_string_literal: true

require_relative "../test_helper"

class TestToolAliasingAndNaming < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @context_index = Rubik::Context::Index.new(root_dir: @temp_dir)
    @ast_graph = Rubik::AST::Graph.new
    @adapter_registry = Rubik::Adapter::Registry.new
    @guard = Rubik::Security::Guard.new
    @runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir)

    @registry = Rubik::Tools::Registry.build_default(
      buffer_manager: @buffer_manager,
      context_index: @context_index,
      ast_graph: @ast_graph,
      adapter_registry: @adapter_registry,
      guard: @guard,
      sandbox_runner: @runner,
      root_dir: @temp_dir
    )
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_canonical_and_alias_resolution
    # Canonical matches
    assert_equal "read_file", @registry.get("read_file").name
    assert_equal "write_file", @registry.get("write_file").name
    assert_equal "run_command", @registry.get("run_command").name
    assert_equal "grep_search", @registry.get("grep_search").name
    assert_equal "lsp_diagnostics", @registry.get("lsp_diagnostics").name
    assert_equal "finish", @registry.get("finish").name

    # Aliases matches
    assert_equal "read_file", @registry.get("view_file").name
    assert_equal "read_file", @registry.get("read").name

    assert_equal "write_file", @registry.get("create_file").name
    assert_equal "write_file", @registry.get("edit_file").name
    assert_equal "write_file", @registry.get("save_file").name

    assert_equal "list_files", @registry.get("list_directory").name
    assert_equal "list_files", @registry.get("list_dir").name
    assert_equal "list_files", @registry.get("ls").name

    assert_equal "grep_search", @registry.get("search_code").name
    assert_equal "grep_search", @registry.get("grep").name
    assert_equal "grep_search", @registry.get("search_files").name

    assert_equal "run_command", @registry.get("bash").name
    assert_equal "run_command", @registry.get("sh").name
    assert_equal "run_command", @registry.get("execute_command").name
    assert_equal "run_command", @registry.get("cmd").name

    assert_equal "run_tests", @registry.get("test").name
    assert_equal "run_tests", @registry.get("run_test_suite").name

    assert_equal "search_symbols", @registry.get("find_symbols").name
    assert_equal "search_symbols", @registry.get("symbols").name

    assert_equal "get_outline", @registry.get("file_outline").name
    assert_equal "get_outline", @registry.get("outline").name

    assert_equal "find_references", @registry.get("references").name
    assert_equal "find_references", @registry.get("get_callers").name

    assert_equal "get_symbol", @registry.get("get_definition").name
    assert_equal "get_symbol", @registry.get("symbol_info").name

    assert_equal "lsp_diagnostics", @registry.get("get_diagnostics").name
    assert_equal "lsp_diagnostics", @registry.get("diagnostics").name

    assert_equal "lsp_hover", @registry.get("get_hover").name
    assert_equal "lsp_hover", @registry.get("hover").name

    assert_equal "lsp_definition", @registry.get("goto_definition").name
    assert_equal "lsp_definition", @registry.get("definition").name

    assert_equal "apply_buffer", @registry.get("save_buffer").name
    assert_equal "apply_buffer", @registry.get("commit_changes").name
    assert_equal "apply_buffer", @registry.get("save").name

    assert_equal "finish", @registry.get("complete").name
    assert_equal "finish", @registry.get("done").name
    assert_equal "finish", @registry.get("task_complete").name
    assert_equal "finish", @registry.get("exit").name
  end

  def test_case_insensitive_alias_lookup
    assert_equal "run_command", @registry.get("BASH").name
    assert_equal "read_file", @registry.get("View_File").name
    assert_equal "grep_search", @registry.get("GREP").name
    assert_equal "finish", @registry.get("Done").name
  end

  def test_schemas_remain_canonical_only_without_token_overhead
    schemas = @registry.schemas
    schema_names = schemas.map { |s| s[:name] || s["name"] }

    assert_equal 20, schemas.size
    assert_includes schema_names, "read_file"
    assert_includes schema_names, "run_command"
    assert_includes schema_names, "grep_search"
    refute_includes schema_names, "bash"
    refute_includes schema_names, "view_file"
    refute_includes schema_names, "grep"
    refute_includes schema_names, "done"
  end

  def test_aliases_map_inspection
    map = @registry.aliases_map
    assert_equal "run_command", map["bash"]
    assert_equal "read_file", map["view_file"]
    assert_equal "grep_search", map["search_code"]
  end

  def test_custom_tool_registration_and_unregistration_with_aliases
    custom_tool = Rubik::Tools::BaseTool.new(
      name: "custom_calc",
      aliases: %w[calc calculate],
      description: "Calculator tool"
    )

    @registry.register(custom_tool, aliases: ["compute"])

    assert_equal "custom_calc", @registry.get("custom_calc").name
    assert_equal "custom_calc", @registry.get("calc").name
    assert_equal "custom_calc", @registry.get("calculate").name
    assert_equal "custom_calc", @registry.get("compute").name

    @registry.unregister("custom_calc")
    assert_nil @registry.get("custom_calc")
    assert_nil @registry.get("calc")
    assert_nil @registry.get("calculate")
    assert_nil @registry.get("compute")
  end

  def test_unregister_by_alias_name
    custom_tool = Rubik::Tools::BaseTool.new(
      name: "dummy_tool",
      aliases: ["dummy_alias"],
      description: "Dummy"
    )
    @registry.register(custom_tool)
    assert_equal "dummy_tool", @registry.get("dummy_alias").name

    @registry.unregister("dummy_alias")
    assert_nil @registry.get("dummy_tool")
    assert_nil @registry.get("dummy_alias")
  end

  def test_swap_tool_with_new_aliases
    old_tool = Rubik::Tools::BaseTool.new(name: "v1_tool", aliases: ["v1"], description: "V1")
    new_tool = Rubik::Tools::BaseTool.new(name: "v2_tool", aliases: ["v2", "v1"], description: "V2")

    @registry.register(old_tool)
    assert_equal "v1_tool", @registry.get("v1").name

    @registry.swap("v1_tool", new_tool)
    assert_nil @registry.get("v1_tool")
    assert_equal "v2_tool", @registry.get("v2_tool").name
    assert_equal "v2_tool", @registry.get("v2").name
    assert_equal "v2_tool", @registry.get("v1").name
  end

  def test_orchestrator_loop_executes_aliased_tool_calls
    step = 0
    mock_provider = Class.new(Rubik::LLM::BaseProvider) do
      def initialize(on_step_block)
        @on_step_block = on_step_block
      end

      def complete(_messages, _opts = {})
        @on_step_block.call
      end
    end.new(lambda {
      step += 1
      case step
      when 1
        Rubik::LLM::Response.new(
          text: "",
          tool_calls: [{ "tool" => "create_file", "args" => { "path" => "lib/alias_test.rb", "content" => "ALIAS_OK = true" } }]
        )
      when 2
        Rubik::LLM::Response.new(
          text: "",
          tool_calls: [{ "tool" => "search_code", "args" => { "query" => "ALIAS_OK" } }]
        )
      when 3
        Rubik::LLM::Response.new(
          text: "All done!",
          tool_calls: [{ "tool" => "complete", "args" => { "message" => "All steps done successfully" } }]
        )
      end
    })

    loop = Rubik::Orchestrator::Loop.new(
      provider: mock_provider,
      tool_registry: @registry,
      buffer_manager: @buffer_manager,
      max_steps: 10
    )

    result = loop.run("Test aliasing flow")
    assert result[:ok]
    assert_equal "All done!\n\nAll steps done successfully", result[:output]
    assert_equal "ALIAS_OK = true", @buffer_manager.read("lib/alias_test.rb")
  end
end
