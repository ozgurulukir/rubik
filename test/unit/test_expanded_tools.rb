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

  def test_run_command_output_carries_shell_tag
    tool = Rubik::Tools::RunCommandTool.new(guard: @guard, runner: @runner, root_dir: @temp_dir)

    res = tool.execute("command" => "echo tagged")
    assert_match(/\[(OK|EXIT \d+)\] \((cmd|bash|pwsh|sh)\)/, res)

    # Drivers that resolve no shell keep the untagged historical format.
    @runner.stub :run, { ok: true, exit_code: 0, output: "plain result" } do
      res2 = tool.execute("command" => "echo tagged")
      assert_equal "[OK] plain result", res2
    end
  end

  def test_read_file_tool_full_and_paged_reads
    tool = Rubik::Tools::ReadFileTool.new(@buffer_manager)
    @buffer_manager.write("page.rb", (1..304).map { |i| "line #{i}" }.join("\n") + "\n")

    # No paging params: full content, unchanged historical behavior.
    full = tool.execute("path" => "page.rb")
    assert_includes full, "line 1"
    assert_includes full, "line 304"

    # The transcript loop: offset/limit must actually slice.
    paged = tool.execute("path" => "page.rb", "offset" => 220, "limit" => 150)
    assert_includes paged, "[lines 220-304 of 304 total]"
    assert_includes paged, "line 220"
    assert_includes paged, "line 304"
    refute_includes paged, "line 1\n"

    middle = tool.execute("path" => "page.rb", "offset" => 148, "limit" => 200)
    assert_includes middle, "[lines 148-304 of 304 total]"

    beyond = tool.execute("path" => "page.rb", "offset" => 500)
    assert_includes beyond, "No content at offset 500"

    missing = tool.execute("path" => "nope.rb")
    assert_includes missing, "File not found"
  end

  def test_result_to_s_basic
    result = Rubik::Tools::Result.new(tool_name: "test", output: "hello world")
    assert_equal "hello world", result.to_s
    assert result.ok?
  end

  def test_result_to_s_with_error
    result = Rubik::Tools::Result.new(tool_name: "test", status: :error, output: "error output", error: "something went wrong")
    assert_equal "error output", result.to_s
    assert result.error?
    refute result.ok?
  end

  def test_result_to_s_with_truncated
    result = Rubik::Tools::Result.new(tool_name: "test", output: "truncated content", truncated: true)
    assert result.truncated
    assert_equal "truncated content", result.to_s
  end

  def test_result_to_s_with_duration
    result = Rubik::Tools::Result.new(tool_name: "test", output: "slow result", duration_ms: 1500.0)
    assert_equal 1500.0, result.duration_ms
    assert_equal "slow result", result.to_s
  end

  def test_result_to_xml
    result = Rubik::Tools::Result.new(tool_name: "test_tool", call_id: "123", status: :ok, output: "result data", exit_code: 0, duration_ms: 100.0)
    xml = result.to_xml
    assert_includes xml, "<tool_result"
    assert_includes xml, 'tool="test_tool"'
    assert_includes xml, 'id="123"'
    assert_includes xml, 'status="ok"'
    assert_includes xml, 'exit_code="0"'
    assert_includes xml, 'duration_ms="100.0"'
    assert_includes xml, "result data"
    assert_includes xml, "</tool_result>"

    # Without call_id
    result_no_id = Rubik::Tools::Result.new(tool_name: "test_tool", call_id: nil, status: :ok, output: "data")
    refute_includes result_no_id.to_xml, 'id="'

    # With truncated
    result_truncated = Rubik::Tools::Result.new(tool_name: "test_tool", output: "data", truncated: true)
    assert_includes result_truncated.to_xml, 'truncated="true"'
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

    expected_tools = %w[read_file write_file list_files grep_search search_symbols get_outline find_references get_symbol lsp_diagnostics lsp_hover lsp_definition run_tests run_command exec_repl_command synthesize_command synthesize_tool inspect_runtime provide_service repair_runtime_service apply_buffer finish]
    expected_tools.each do |tname|
      refute_nil registry.get(tname), "Registry should include #{tname}"
    end
    assert_equal 21, registry.list.size
  end
end
