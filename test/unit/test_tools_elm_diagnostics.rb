# frozen_string_literal: true

require_relative "../test_helper"

class TestToolsElmDiagnostics < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_elm_diag_test")
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @ast_graph = Rubik::AST::Graph.new
    @registry = Rubik::Tools::Registry.build_default(
      buffer_manager: @buffer_manager,
      ast_graph: @ast_graph,
      root_dir: @temp_dir
    )
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  def test_read_file_line_numbering_and_file_not_found_elm_box
    @buffer_manager.write("hello.rb", "puts 'Hello'\nputs 'World'\n")
    read_tool = @registry.get("read_file")

    output = read_tool.execute("path" => "hello.rb")
    assert_equal "1: puts 'Hello'\n2: puts 'World'\n", output

    missing_out = read_tool.execute("path" => "helo.rb")
    assert_includes missing_out, "-- FILE NOT FOUND --"
    assert_includes missing_out, "I cannot find the file `helo.rb`"
    assert_includes missing_out, "Did you mean this?"
    assert_includes missing_out, "• hello.rb"
  end

  def test_symbol_tools_elm_diagnostic_on_missing_symbol
    sym_tool = @registry.get("get_symbol")
    res = sym_tool.execute("symbol_name" => "UnknownClass")
    assert_includes res, "-- SYMBOL NOT FOUND --"
    assert_includes res, "I could not find the symbol `UnknownClass` in the AST semantic graph."
    assert_includes res, "Actionable Next Steps:"
  end

  def test_step_executor_invalid_tool_returns_elm_diagnostic_with_synthesis_tip
    loop_mock = Object.new
    loop_mock.define_singleton_method(:step_count) { 1 }
    loop_mock.define_singleton_method(:max_steps) { 40 }
    loop_mock.define_singleton_method(:total_tokens) { { input: 0, output: 0 } }
    loop_mock.define_singleton_method(:last_turn_streamed) { false }
    reg = @registry
    buf = @buffer_manager
    loop_mock.define_singleton_method(:tool_registry) { reg }
    loop_mock.define_singleton_method(:buffer_manager) { buf }
    loop_mock.define_singleton_method(:shell) { nil }
    loop_mock.define_singleton_method(:lsp_manager) { nil }
    loop_mock.define_singleton_method(:on_step) { nil }

    invalid_count = 0
    loop_mock.define_singleton_method(:invalid_tool_count) { invalid_count }
    loop_mock.define_singleton_method(:invalid_tool_count=) { |v| invalid_count = v }

    history = []
    loop_mock.define_singleton_method(:history) { history }

    executor = Rubik::Orchestrator::StepExecutor.new(loop_mock)
    res = executor.execute_single_tool_call(
      { "tool" => "view_fle", "args" => {} },
      "",
      "manual"
    )

    assert_nil res # step continues
    assert_equal 1, history.size
    tool_xml = history.first[:content]
    assert_includes tool_xml, "-- UNKNOWN TOOL --"
    assert_includes tool_xml, "I cannot find an active tool named `view_fle`."
    assert_includes tool_xml, "• read_file"
    assert_includes tool_xml, "synthesize_tool"
  end
end
