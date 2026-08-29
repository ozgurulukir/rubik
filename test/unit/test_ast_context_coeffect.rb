# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class TestASTContextCoeffect < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_coeffect_test_")
    @ctx = Rubik::Runtime::Context.new
    @manager = Rubik::Runtime::Manager.new(@ctx)
    @ast = Rubik::AST::Graph.new
    @index = Rubik::Context::Index.new(root_dir: @temp_dir)
  end

  def teardown
    @manager.dispose! unless @ctx.disposed?
    FileUtils.remove_entry(@temp_dir)
  end

  def test_ast_service_registration_and_coeffects
    Rubik::Runtime::ASTService.register(@manager, @ast)

    assert @ctx.has?("ast_graph")
    assert @ctx.has?("ast")
    assert_equal @ast, @ctx.require("ast_graph")
    assert_equal @ast, @ctx.require("ast")
  end

  def test_index_service_registration_and_coeffects
    Rubik::Runtime::IndexService.register(@manager, @index)

    assert @ctx.has?("context_index")
    assert @ctx.has?("index")
    assert_equal @index, @ctx.require("context_index")
    assert_equal @index, @ctx.require("index")
  end

  def test_ast_service_locality_of_disposal
    file_path = File.join(@temp_dir, "sample.rb")
    File.write(file_path, "class Sample\n  def hello\n    puts 'hi'\n  end\nend\n")
    @ast.index_file(file_path)

    assert @ast.symbols.key?("Sample")

    cache_store = Rubik::AST::CacheStore.new(root_dir: @temp_dir)
    Rubik::Runtime::ASTService.register(@ctx, @ast, cache_store: cache_store)

    @ctx.dispose

    # Graph memory should be cleared
    assert_empty @ast.symbols
    assert_empty @ast.file_symbols

    # Cache store should have saved content
    loaded = cache_store.load
    assert loaded.key?(file_path)
  end

  def test_tools_reactive_coeffect_resolution
    search_tool = Rubik::Tools::SearchSymbolsTool.new(runtime_context: @ctx)
    outline_tool = Rubik::Tools::GetOutlineTool.new(runtime_context: @ctx)
    list_tool = Rubik::Tools::ListFilesTool.new(root_dir: @temp_dir, runtime_context: @ctx)

    file_path = File.join(@temp_dir, "test.rb")
    File.write(file_path, "def greet; 'hello'; end\n")

    # Before services are provided
    assert_includes search_tool.execute("query" => "greet"), "not available"

    # Provide services
    Rubik::Runtime::ASTService.register(@manager, @ast)
    Rubik::Runtime::IndexService.register(@manager, @index)
    @ast.index_file(file_path)

    # Coeffects dynamically resolved
    res = search_tool.execute("query" => "greet")
    assert_includes res, "greet"

    outline_res = outline_tool.execute("file_path" => file_path)
    assert_includes outline_res, "greet"

    list_res = list_tool.execute
    assert_includes list_res, "test.rb"
  end

  def test_index_service_sync_roots
    extra_dir = Dir.mktmpdir("rubik_extra_root_")
    extra_file = File.join(extra_dir, "extra.rb")
    File.write(extra_file, "class ExtraComponent; end\n")

    Rubik::Runtime::ASTService.register(@manager, @ast)
    Rubik::Runtime::IndexService.register(@manager, @index)

    Rubik::Runtime::IndexService.sync_roots(
      @manager,
      @index,
      additional_roots: [extra_dir],
      ast_graph: @ast
    )

    assert_includes @index.additional_roots, extra_dir
    rel_from_root = Pathname.new(extra_file).relative_path_from(Pathname.new(@temp_dir)).to_s
    assert @index.files.key?(rel_from_root)
    assert @ast.symbols.key?("ExtraComponent")
  ensure
    FileUtils.remove_entry(extra_dir) if extra_dir && File.exist?(extra_dir)
  end
end
