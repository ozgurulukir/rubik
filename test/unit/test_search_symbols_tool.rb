# frozen_string_literal: true

require_relative "../test_helper"

class TestSearchSymbolsTool < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_search_symbols_test_")
    @ast_graph = Rubik::AST::Graph.new
  end

  def teardown
    remove_temp_dir(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
  end

  def test_declaration_and_metadata
    tool = Rubik::Tools::SearchSymbolsTool.new(@ast_graph)
    assert_equal "search_symbols", tool.declaration.name
    assert_equal ["find_symbols", "symbols"], tool.declaration.aliases
    assert_equal :read, tool.declaration.risk
    assert_equal [:research], tool.declaration.archetypes
    assert_equal [Rubik::Coeffects::AST_GRAPH], Rubik::Tools::SearchSymbolsTool::REQUIRES

    schema = tool.declaration.params_schema
    assert_equal "object", schema[:type]
    assert_includes schema[:required], "query"
  end

  def test_execute_missing_query_returns_error
    tool = Rubik::Tools::SearchSymbolsTool.new(@ast_graph)

    [{}, { query: "" }, { "query" => "   " }, { query: nil }].each do |args|
      res = tool.execute(args)
      assert_kind_of Rubik::Tools::ToolOutput, res
      assert res.error?
      assert_includes res, "Query parameter is required."
    end
  end

  def test_execute_missing_ast_graph_returns_error
    tool = Rubik::Tools::SearchSymbolsTool.new(nil)
    res = tool.execute(query: "search_term")

    assert_kind_of Rubik::Tools::ToolOutput, res
    assert res.error?
    assert_includes res, "AST graph is not available"
  end

  def test_execute_smart_context_option
    mock_graph = Minitest::Mock.new
    mock_graph.expect(:smart_context_for, "", ["nonexistent"])
    mock_graph.expect(:smart_context_for, "class User\n  def initialize; end\nend", ["User"])

    tool = Rubik::Tools::SearchSymbolsTool.new(mock_graph)

    res_empty = tool.execute("query" => "nonexistent", "smart_context" => true)
    assert_equal "No smart context found for 'nonexistent'.", res_empty

    res_found = tool.execute(query: "User", smart_context: true)
    assert_equal "class User\n  def initialize; end\nend", res_found

    mock_graph.verify
  end

  def test_search_symbols_using_graph_search_symbols_method
    sym1 = Struct.new(:kind, :name, :file, :line_start, :line_end, :signature, :calls).new(
      :class, "UserAuthenticator", "lib/auth.rb", 10, 45, "class UserAuthenticator", ["validate_token", "fetch_user"]
    )
    sym2 = Struct.new(:kind, :name, :file, :line_start, :line_end, :signature, :calls).new(
      :method, "authenticate", "lib/auth.rb", 15, 25, "def authenticate(token)", ["validate_token"]
    )

    mock_graph = Minitest::Mock.new
    mock_graph.expect(:search_symbols, [sym1, sym2], ["auth"])

    tool = Rubik::Tools::SearchSymbolsTool.new(mock_graph)
    res = tool.execute(query: "auth")

    assert_includes res, "• CLASS UserAuthenticator (lib/auth.rb:10-45)"
    assert_includes res, "Signature: class UserAuthenticator"
    assert_includes res, "Calls: validate_token, fetch_user"
    assert_includes res, "• METHOD authenticate (lib/auth.rb:15-25)"
    assert_includes res, "Signature: def authenticate(token)"
    assert_includes res, "Calls: validate_token"

    mock_graph.verify
  end

  def test_search_symbols_fallback_filtering_when_search_symbols_not_defined
    sym1 = Struct.new(:kind, :name, :file, :line_start, :line_end, :signature, :calls).new(
      :method, "parse_json", "lib/parser.rb", 1, 10, "def parse_json(raw)", []
    )
    sym2 = Struct.new(:kind, :name, :file, :line_start, :line_end, :signature, :calls).new(
      :method, "encode_json", "lib/parser.rb", 12, 20, "def encode_json(obj)", []
    )
    sym3 = Struct.new(:kind, :name, :file, :line_start, :line_end, :signature, :calls).new(
      :method, "other_helper", "lib/parser.rb", 22, 30, "def other_helper", []
    )

    fallback_graph = Object.new
    symbols_hash = { "parse_json" => sym1, "encode_json" => sym2, "other_helper" => sym3 }
    fallback_graph.define_singleton_method(:symbols) { symbols_hash }

    tool = Rubik::Tools::SearchSymbolsTool.new(fallback_graph)
    res = tool.execute(query: "JSON")

    assert_includes res, "• METHOD parse_json"
    assert_includes res, "• METHOD encode_json"
    refute_includes res, "other_helper"
  end

  def test_search_symbols_no_matches_renders_diagnostic_suggestion
    sym1 = Struct.new(:kind, :name, :file, :line_start, :line_end, :signature, :calls).new(
      :method, "calculate_total", "lib/calc.rb", 1, 10, "def calculate_total", []
    )
    fallback_graph = Object.new
    symbols_hash = { "calculate_total" => sym1 }
    fallback_graph.define_singleton_method(:symbols) { symbols_hash }

    tool = Rubik::Tools::SearchSymbolsTool.new(fallback_graph)
    res = tool.execute(query: "calc_tot")

    assert_includes res, "calc_tot"
    assert_includes res, "calculate_total"
  end

  def test_parameter_key_variations
    sym = Struct.new(:kind, :name, :file, :line_start, :line_end, :signature, :calls).new(
      :method, "run_task", "lib/task.rb", 5, 10, "def run_task", []
    )
    mock_graph = Minitest::Mock.new
    mock_graph.expect(:search_symbols, [sym], ["run"])
    mock_graph.expect(:search_symbols, [sym], ["run"])

    tool = Rubik::Tools::SearchSymbolsTool.new(mock_graph)

    # String key
    res1 = tool.execute("query" => "run")
    assert_includes res1, "run_task"

    # Symbol key
    res2 = tool.execute(query: "run")
    assert_includes res2, "run_task"

    mock_graph.verify
  end

  def test_coeffect_resolution_from_runtime_context
    ctx = Rubik::Runtime::Context.new
    ctx.provide(Rubik::Coeffects::AST_GRAPH, @ast_graph)

    code = <<~RUBY
      class PaymentGateway
        def process_payment(amount)
          log_transaction(amount)
        end

        def log_transaction(amount)
          true
        end
      end
    RUBY

    path = File.join(@temp_dir, "gateway.rb")
    File.write(path, code)
    @ast_graph.index_file(path)

    tool = Rubik::Tools::SearchSymbolsTool.new(runtime_context: ctx)
    res = tool.execute(query: "payment")

    assert_includes res, "PaymentGateway"
    assert_includes res, "process_payment"
  end

  def test_coeffect_resolution_from_legacy_context_kwarg
    ctx = Rubik::Runtime::Context.new
    ctx.provide(Rubik::Coeffects::AST_GRAPH, @ast_graph)

    code = <<~RUBY
      def legacy_symbol_search
        42
      end
    RUBY

    path = File.join(@temp_dir, "legacy_test.rb")
    File.write(path, code)
    @ast_graph.index_file(path)

    tool = Rubik::Tools::SearchSymbolsTool.new(context: ctx)
    res = tool.execute(query: "legacy_symbol")

    assert_includes res, "legacy_symbol_search"
  end

  def test_execute_delegates_to_real_ast_graph
    code = <<~RUBY
      module Ordering
        class OrderProcessor
          def process(order)
            validate(order)
            ship(order)
          end

          private

          def validate(order)
            true
          end

          def ship(order)
            true
          end
        end
      end
    RUBY

    file_path = File.join(@temp_dir, "order_processor.rb")
    File.write(file_path, code)
    @ast_graph.index_file(file_path)

    tool = Rubik::Tools::SearchSymbolsTool.new(@ast_graph)
    res = tool.execute(query: "OrderProcessor")

    assert_includes res, "OrderProcessor"
    assert_includes res, "Signature: class OrderProcessor"
  end
end
