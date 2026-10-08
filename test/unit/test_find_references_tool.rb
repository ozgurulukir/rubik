# frozen_string_literal: true

require_relative "../test_helper"

class TestFindReferencesTool < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_find_ref")
    @ast_graph = Rubik::AST::Graph.new
  end

  def teardown
    remove_temp_dir(@temp_dir)
  end

  def test_declaration_metadata
    tool = Rubik::Tools::FindReferencesTool.new
    assert_equal "find_references", tool.name
    assert_equal :read, tool.risk
    assert_includes tool.archetypes, :research
    assert_includes tool.aliases, "references"
    assert_includes tool.aliases, "get_callers"

    schema = tool.declaration.params_schema
    assert_equal "object", schema[:type]
    assert_includes schema[:required], "symbol_name"
  end

  def test_execute_without_ast_graph_returns_error
    tool = Rubik::Tools::FindReferencesTool.new
    res = tool.execute(symbol_name: "some_method")
    assert_kind_of Rubik::Tools::ToolOutput, res
    assert res.error?
    assert_includes res, "AST graph is not available"
  end

  def test_execute_with_missing_or_empty_symbol_name_returns_error
    tool = Rubik::Tools::FindReferencesTool.new(@ast_graph)

    [{}, { symbol_name: "" }, { "symbol_name" => "   " }, { symbol: nil }].each do |args|
      res = tool.execute(args)
      assert_kind_of Rubik::Tools::ToolOutput, res
      assert res.error?
      assert_includes res, "Symbol name is required"
    end
  end

  def test_execute_when_no_references_found
    code = <<~RUBY
      def unused_method
        1 + 1
      end
    RUBY
    path = File.join(@temp_dir, "file.rb")
    File.write(path, code)
    @ast_graph.index_file(path)

    tool = Rubik::Tools::FindReferencesTool.new(@ast_graph)
    res = tool.execute(symbol_name: "unused_method")

    assert_equal "No references or callers found for 'unused_method' in AST graph.", res
  end

  def test_execute_finds_single_and_multiple_references
    code = <<~RUBY
      def calculate_tax(amount)
        amount * 0.2
      end

      def process_invoice(amount)
        tax = calculate_tax(amount)
        amount + tax
      end

      def process_order(amount)
        calculate_tax(amount)
      end
    RUBY
    path = File.join(@temp_dir, "tax.rb")
    File.write(path, code)
    @ast_graph.index_file(path)

    tool = Rubik::Tools::FindReferencesTool.new(@ast_graph)
    res = tool.execute(symbol_name: "calculate_tax")

    assert_includes res, "Found 2 reference(s) for 'calculate_tax':"
    assert_includes res, "process_invoice"
    assert_includes res, "process_order"
    assert_includes res, "(#{path}:"
  end

  def test_parameter_key_variations
    code = <<~RUBY
      def helper
        true
      end

      def main
        helper
      end
    RUBY
    path = File.join(@temp_dir, "app.rb")
    File.write(path, code)
    @ast_graph.index_file(path)

    tool = Rubik::Tools::FindReferencesTool.new(@ast_graph)

    [
      { "symbol_name" => "helper" },
      { symbol_name: "helper" },
      { "symbol" => "helper" },
      { symbol: "helper" }
    ].each do |args|
      res = tool.execute(args)
      assert_includes res, "Found 1 reference(s) for 'helper':", "Failed for args: #{args.inspect}"
      assert_includes res, "main"
    end
  end

  def test_coeffect_resolution_via_context
    context = Rubik::Runtime::Context.new
    context.provide(Rubik::Coeffects::AST_GRAPH, @ast_graph)

    code = <<~RUBY
      def ping
        "pong"
      end

      def status
        ping
      end
    RUBY
    path = File.join(@temp_dir, "net.rb")
    File.write(path, code)
    @ast_graph.index_file(path)

    tool = Rubik::Tools::FindReferencesTool.new(runtime_context: context)
    res = tool.execute(symbol_name: "ping")

    assert_includes res, "Found 1 reference(s) for 'ping':"
    assert_includes res, "status"
  end

  def test_stub_ast_graph_support
    stub_caller = Struct.new(:name, :file, :line_start, :line_end, :signature).new(
      "custom_caller", "lib/custom.rb", 10, 15, "def custom_caller(x)"
    )
    stub_graph = Minitest::Mock.new
    stub_graph.expect(:callers_of, [stub_caller], ["target_sym"])

    tool = Rubik::Tools::FindReferencesTool.new(stub_graph)
    res = tool.execute(symbol_name: "target_sym")

    assert_includes res, "Found 1 reference(s) for 'target_sym':"
    assert_includes res, "custom_caller (lib/custom.rb:10-15) -> def custom_caller(x)"
    stub_graph.verify
  end
end
