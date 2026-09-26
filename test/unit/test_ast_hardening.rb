# frozen_string_literal: true

require_relative "../test_helper"

class TestASTHardening < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_ast_test")
  end

  def teardown
    remove_temp_dir(@temp_dir)
  end

  def test_treesitter_clear_parsers
    Thread.current[:rubik_ts_parsers] = { "ruby" => Object.new }
    Rubik::AST::TreeSitterExtractor.clear_parsers!
    assert_empty Thread.current[:rubik_ts_parsers]
  end

  def test_treesitter_extractor_returns_nil_on_syntax_error_with_no_symbols
    return unless Rubik::AST::TreeSitterExtractor.available?

    mock_node = Object.new
    # rubocop:disable-next Naming/PredicatePrefix
    def mock_node.has_error?
      true
    end

    mock_tree = Object.new
    mock_tree.define_singleton_method(:root_node) { mock_node }

    mock_parser = Object.new
    mock_parser.define_singleton_method(:parse) { |_code| mock_tree }

    Rubik::AST::TreeSitterExtractor.stub :parser_for, mock_parser do
      res = Rubik::AST::TreeSitterExtractor.extract("test.py", "def broken(:")
      assert_nil res, "TreeSitter with root_node error and empty symbols must return nil for regex fallback"
    end
  end

  def test_graph_deterministic_path_matching_no_accidental_suffix_clash
    graph = Rubik::AST::Graph.new
    file1 = File.join(@temp_dir, "pkg1", "utils.rb")
    file2 = File.join(@temp_dir, "pkg2", "utils.rb")

    sym1 = Rubik::AST::Symbol.new(name: "util_one", kind: :function, file: file1, line_start: 1, line_end: 2)
    sym2 = Rubik::AST::Symbol.new(name: "util_two", kind: :function, file: file2, line_start: 1, line_end: 2)

    raw_file_symbols = graph.instance_variable_get(:@file_symbols)
    raw_file_symbols[file1] = [sym1]
    raw_file_symbols[file2] = [sym2]

    assert_equal [sym1], graph.send(:_get_file_symbols_unlocked, file1)
    assert_equal [sym2], graph.send(:_get_file_symbols_unlocked, file2)

    # Looking up a different path with same filename suffix does NOT return wrong file's symbols
    unrelated = File.join(@temp_dir, "other", "pkg1", "utils.rb")
    assert_empty graph.send(:_get_file_symbols_unlocked, unrelated)
  end

  def test_cache_store_valid_entry_requires_digest
    cache_store = Rubik::AST::CacheStore.new(root_dir: @temp_dir)
    test_file = File.join(@temp_dir, "example.rb")
    File.write(test_file, "def test_fn; end\n")

    stat = File.stat(test_file)
    valid_digest = Digest::SHA1.file(test_file).hexdigest

    # Missing digest -> invalid
    cached_without_digest = {
      "size" => stat.size,
      "mtime" => stat.mtime.to_i
    }
    refute cache_store.valid_entry?(test_file, cached_without_digest)

    # Mismatched digest -> invalid
    cached_with_wrong_digest = {
      "size" => stat.size,
      "mtime" => stat.mtime.to_i,
      "digest" => "0000000000000000000000000000000000000000"
    }
    refute cache_store.valid_entry?(test_file, cached_with_wrong_digest)

    # Correct digest -> valid
    cached_valid = {
      "size" => stat.size,
      "mtime" => stat.mtime.to_i,
      "digest" => valid_digest
    }
    assert cache_store.valid_entry?(test_file, cached_valid)
  end

  def test_ast_service_purge_stale_entries_handles_casing_and_removal
    graph = Rubik::AST::Graph.new
    kept_file = File.join(@temp_dir, "kept.rb")
    deleted_file = File.join(@temp_dir, "deleted.rb")

    File.write(kept_file, "def kept; end\n")

    sym_kept = Rubik::AST::Symbol.new(name: "kept", kind: :function, file: kept_file, line_start: 1, line_end: 2)
    sym_deleted = Rubik::AST::Symbol.new(name: "deleted", kind: :function, file: deleted_file, line_start: 1, line_end: 2)

    raw_file_symbols = graph.instance_variable_get(:@file_symbols)
    raw_file_symbols[kept_file] = [sym_kept]
    raw_file_symbols[deleted_file] = [sym_deleted]

    # Mock context_index with kept file (rel path)
    context_index = Struct.new(:files).new({ "kept.rb" => { size: 10 } })

    purged = Rubik::Runtime::ASTService.purge_stale_entries!(graph, context_index, @temp_dir)
    assert_equal 1, purged
    assert_equal [sym_kept], graph.file_symbols[kept_file]
    refute graph.file_symbols.key?(deleted_file)
  end

  def test_python_walker_depth_ceiling
    walker = Rubik::AST::TreeSitter::PythonWalker.new("test.py", "")
    symbols = []

    # Mock a deeply recursive AST node
    deep_node = Object.new
    deep_node.define_singleton_method(:named_child_count) { 1 }
    deep_node.define_singleton_method(:named_child) { |_i| deep_node }
    deep_node.define_singleton_method(:kind) { "other_expression" }

    # Should safely return without SystemStackError
    walker.send(:walk_children, deep_node, symbols, nil, depth: 50)
    walker.send(:walk_children, deep_node, symbols, nil, depth: 51)
    assert_empty symbols
  end
end
