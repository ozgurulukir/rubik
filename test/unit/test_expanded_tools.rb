# frozen_string_literal: true

require_relative "../test_helper"

class TestExpandedTools < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @context_index = Rubik::Context::Index.new(root_dir: @temp_dir)
    @ast_graph = Rubik::AST::Graph.new
    @adapter_registry = Rubik::Adapter::Registry.new
    @guard = Rubik::Security::Guard.new
    @runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_list_files_tool
    File.write(File.join(@temp_dir, "app.rb"), "def hello; end")
    File.write(File.join(@temp_dir, "main.go"), "package main")
    @context_index.full_scan

    tool = Rubik::Tools::ListFilesTool.new(@context_index, root_dir: @temp_dir)
    res = tool.execute({})
    assert_includes res, "app.rb"
    assert_includes res, "main.go"

    filtered_res = tool.execute("extension" => ".go")
    assert_includes filtered_res, "main.go"
    refute_includes filtered_res, "app.rb"
  end

  def test_search_symbols_tool
    code = "class Greeter\n  def greet\n    puts 'hi'\n  end\nend\n"
    @ast_graph.index_file("greeter.rb", code)

    tool = Rubik::Tools::SearchSymbolsTool.new(@ast_graph)
    res = tool.execute("query" => "greet")

    assert_includes res, "Greeter#greet"

    smart_res = tool.execute("query" => "Greeter#greet", "smart_context" => true)
    assert_includes smart_res, "def greet"
  end

  def test_run_command_tool_safety_and_execution
    tool = Rubik::Tools::RunCommandTool.new(guard: @guard, runner: @runner, root_dir: @temp_dir)

    safe_res = tool.execute("command" => "echo 'hello rubik tool'")
    assert_includes safe_res, "hello rubik tool"

    blocked_res = tool.execute("command" => "rm -rf /")
    assert_includes blocked_res, "Security blocked"
  end

  def test_build_default_registry_contains_all_tools
    registry = Rubik::Tools::Registry.build_default(
      buffer_manager: @buffer_manager,
      context_index: @context_index,
      ast_graph: @ast_graph,
      adapter_registry: @adapter_registry,
      guard: @guard,
      sandbox_runner: @runner,
      root_dir: @temp_dir
    )

    expected_tools = %w[read_file write_file list_files search_symbols get_outline find_references get_symbol lsp_diagnostics lsp_hover lsp_definition run_tests run_command exec_repl_command synthesize_command synthesize_tool inspect_runtime provide_service apply_buffer finish]
    expected_tools.each do |tname|
      refute_nil registry.get(tname), "Registry should include #{tname}"
    end
    assert_equal 19, registry.list.size
  end
end
