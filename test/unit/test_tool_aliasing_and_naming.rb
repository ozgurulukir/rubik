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
    assert_equal "replace_file_content", @registry.get("replace_file_content").name
    assert_equal "write_file", @registry.get("write_file").name
    assert_equal "run_command", @registry.get("run_command").name
    assert_equal "grep_search", @registry.get("grep_search").name
    assert_equal "lsp_diagnostics", @registry.get("lsp_diagnostics").name
    assert_equal "finish", @registry.get("finish").name

    # Aliases matches
    assert_equal "read_file", @registry.get("view_file").name
    assert_equal "read_file", @registry.get("read").name

    assert_equal "replace_file_content", @registry.get("edit_file").name
    assert_equal "replace_file_content", @registry.get("edit_chunk").name
    assert_equal "replace_file_content", @registry.get("str_replace").name
    assert_equal "replace_file_content", @registry.get("patch_file").name

    assert_equal "write_file", @registry.get("create_file").name
    assert_equal "write_file", @registry.get("save_file").name
    assert_equal "write_file", @registry.get("overwrite_file").name

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

    assert_equal "repair_runtime_service", @registry.get("fix_service").name
    assert_equal "repair_runtime_service", @registry.get("repair_lsp").name
    assert_equal "repair_runtime_service", @registry.get("repair_runner").name
    assert_equal "repair_runtime_service", @registry.get("repair_runtime").name

    assert_equal "finish", @registry.get("complete").name
    assert_equal "finish", @registry.get("done").name
    assert_equal "finish", @registry.get("task_complete").name
    assert_equal "finish", @registry.get("exit").name

    assert_equal "ask_question", @registry.get("ask").name
    assert_equal "ask_question", @registry.get("question").name
  end

  def test_case_insensitive_alias_lookup
    assert_equal "run_command", @registry.get("BASH").name
    assert_equal "read_file", @registry.get("View_File").name
    assert_equal "replace_file_content", @registry.get("EDIT_FILE").name
    assert_equal "grep_search", @registry.get("GREP").name
    assert_equal "finish", @registry.get("Done").name
    assert_equal "repair_runtime_service", @registry.get("FIX_SERVICE").name
  end

  def test_schemas_remain_canonical_only_without_token_overhead
    schemas = @registry.schemas
    schema_names = schemas.map { |s| s[:name] || s["name"] }

    assert_equal 32, schemas.size
    assert_includes schema_names, "read_file"
    assert_includes schema_names, "replace_file_content"
    assert_includes schema_names, "run_command"
    assert_includes schema_names, "manage_task"
    assert_includes schema_names, "grep_search"
    assert_includes schema_names, "repair_runtime_service"
    assert_includes schema_names, "ask_question"
    assert_includes schema_names, "invoke_subagent"
    assert_includes schema_names, "manage_subagents"
    assert_includes schema_names, "send_message"
    assert_includes schema_names, "define_subagent"
    assert_includes schema_names, "dmesg"
    refute_includes schema_names, "bash"
    refute_includes schema_names, "view_file"
    refute_includes schema_names, "grep"
    refute_includes schema_names, "fix_service"
    refute_includes schema_names, "tasks"
    refute_includes schema_names, "done"
    refute_includes schema_names, "kernel_log"
    refute_includes schema_names, "kernel_dmesg"
  end

  def test_aliases_map_inspection
    map = @registry.aliases_map
    assert_equal "run_command", map["bash"]
    assert_equal "read_file", map["view_file"]
    assert_equal "grep_search", map["search_code"]
    assert_equal "manage_task", map["task"]
    assert_equal "manage_task", map["tasks"]
  end

  def test_custom_tool_registration_and_unregistration_with_aliases
    custom_tool = Rubik::Tools::BaseTool.new(
      name: "custom_calc",
      aliases: ["calc", "calculate"],
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

  def test_registration_origin_tracking
    builtin = Rubik::Tools::BaseTool.new(name: "builtin_tool", description: "B")
    overlay = Rubik::Tools::BaseTool.new(name: "overlay_tool", description: "O")
    mcp = Rubik::Tools::BaseTool.new(name: "mcp_x_tool", description: "M")

    @registry.register(builtin)
    @registry.register(overlay, origin: :overlay)
    @registry.register(mcp, aliases: ["mcp_alias"], origin: :mcp)

    assert_equal :builtin, @registry.origin("builtin_tool")
    assert_equal :overlay, @registry.origin("overlay_tool")
    assert_equal :mcp, @registry.origin("mcp_x_tool")
    # Origin resolves through aliases too
    assert_equal :mcp, @registry.origin("mcp_alias")
    assert_nil @registry.origin("nonexistent")

    @registry.unregister("overlay_tool")
    assert_nil @registry.origin("overlay_tool")

    # swap preserves an explicitly passed origin
    replacement = Rubik::Tools::BaseTool.new(name: "mcp_x_tool", description: "M2")
    @registry.swap("mcp_x_tool", replacement, origin: :mcp)
    assert_equal :mcp, @registry.origin("mcp_x_tool")
  end

  def test_orchestrator_loop_executes_aliased_tool_calls
    step = 0
    mock_provider = Class.new(Rubik::LLM::BaseProvider) do
      def initialize(on_step_block)
        super()
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

    # Plumbing test (alias resolution through the live loop, not maestro
    # policy): gate off via shell config — policy lives in test_maestro_gate.rb.
    gate_off_shell = Struct.new(:lsp_manager, :buffer_manager, :config, :snapshot_store, :context_index, :runtime_manager)
                           .new(nil, @buffer_manager, { "subagents" => { "maestro_gate" => false } }, nil, nil, nil)
    loop = Rubik::Orchestrator::Loop.new(
      provider: mock_provider,
      tool_registry: @registry,
      max_steps: 10,
      shell: gate_off_shell
    )

    result = loop.run("Test aliasing flow")
    assert result[:ok]
    assert_equal "All done!\n\nAll steps done successfully", result[:output]
    assert_equal "ALIAS_OK = true", @buffer_manager.read("lib/alias_test.rb")
  end

  def test_unregister_cleans_aliases_without_affecting_reassigned_aliases
    t1 = Rubik::Tools::BaseTool.new(name: "tool_one", description: "First", aliases: ["shared_alias", "unique_one"])
    t2 = Rubik::Tools::BaseTool.new(name: "tool_two", description: "Second", aliases: ["shared_alias", "unique_two"])

    @registry.register(t1)
    assert_equal "tool_one", @registry.get("shared_alias").name
    assert_equal "tool_one", @registry.get("unique_one").name

    # t2 reassigns shared_alias
    @registry.register(t2)
    assert_equal "tool_two", @registry.get("shared_alias").name

    # unregister t1 should remove unique_one, but preserve shared_alias for t2
    @registry.unregister("tool_one")
    assert_nil @registry.get("tool_one")
    assert_nil @registry.get("unique_one")
    assert_equal "tool_two", @registry.get("shared_alias").name

    # unregistering t2 now removes shared_alias
    @registry.unregister("tool_two")
    assert_nil @registry.get("tool_two")
    assert_nil @registry.get("shared_alias")
  end
end
