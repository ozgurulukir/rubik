# frozen_string_literal: true

require_relative "../test_helper"

class TestRuntimeIndexService < Minitest::Test
  def setup
    @ctx = Rubik::Runtime::Context.new
    @manager = Rubik::Runtime::Manager.new(@ctx)
    @temp_dir = Dir.mktmpdir("index_service_test")
    @index = Rubik::Context::Index.new(root_dir: @temp_dir)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
    @ctx.dispose unless @ctx.disposed?
  end

  def make_marker_file(name = "Gemfile")
    FileUtils.touch(File.join(@temp_dir, name))
  end

  def make_ruby_file(rel, content = "# frozen_string_literal: true\ndef x; end\n")
    full = File.join(@temp_dir, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  # ── register ───────────────────────────────────────────────────────

  def test_registers_index_into_context
    result = Rubik::Runtime::IndexService.register(@ctx, @index)

    assert_same @index, result
    assert_same @index, @ctx.get("context_index")
    # Canonical key only: the legacy "index" alias is not stored literally by
    # the service, but reads through the alias resolve to the canonical index
    # (Runtime::Context alias bridge, Rubik::Coeffects SSOT).
    refute @ctx.services.key?("index")
    assert_same @index, @ctx.get("index")
  end

  def test_registers_via_manager_and_reconciles
    Rubik::Runtime::IndexService.register(@manager, @index)

    assert_same @index, @manager.context.get("context_index")
  end

  def test_returns_index_when_context_unavailable
    result = Rubik::Runtime::IndexService.register(nil, @index)
    assert_same @index, result
  end

  # ── sync_roots ─────────────────────────────────────────────────────

  def test_sync_roots_updates_additional_roots_and_scans
    make_marker_file("Gemfile")
    sub_dir = File.join(@temp_dir, "lib")
    FileUtils.mkdir_p(sub_dir)
    FileUtils.touch(File.join(sub_dir, "core.rb"))

    Rubik::Runtime::IndexService.sync_roots(@ctx, @index, additional_roots: ["lib"])

    # additional_roots stores absolute paths
    expanded = @index.additional_roots.map { |r| File.expand_path(r) }
    assert_includes expanded, File.expand_path("lib", @temp_dir)
    assert @index.files.key?("Gemfile"), "should have scanned root files"
    assert @index.files.key?("lib/core.rb"), "should have scanned additional root files"
  end

  def test_sync_roots_does_nothing_with_nil_index
    result = Rubik::Runtime::IndexService.sync_roots(@ctx, nil, additional_roots: [])
    assert_nil result
  end

  def test_sync_roots_with_ast_graph_indexes_new_files
    make_ruby_file("test.rb", "module TestMod; end")

    graph = Rubik::AST::Graph.new

    Rubik::Runtime::IndexService.sync_roots(@ctx, @index,
                                            additional_roots: [],
                                            ast_graph: graph)

    assert graph.file_symbols.keys.any? { |k| k.to_s.end_with?("test.rb") },
           "test.rb should be indexed into the ast graph"
  end

  def test_sync_roots_skips_already_indexed_files_in_ast_graph
    make_ruby_file("dup.rb")
    graph = Rubik::AST::Graph.new
    graph.index_file(File.join(@temp_dir, "dup.rb"))
    before_count = graph.file_symbols.size

    Rubik::Runtime::IndexService.sync_roots(@ctx, @index,
                                            additional_roots: [],
                                            ast_graph: graph)

    # No duplicate indexing (file_symbols size should not increase significantly)
    assert_operator graph.file_symbols.size, :<=, before_count
  end

  def test_sync_roots_saves_cache_when_cache_store_given
    make_ruby_file("cached.rb", "module Cache; end")
    cache_store = Rubik::AST::CacheStore.new(root_dir: @temp_dir)
    graph = Rubik::AST::Graph.new

    Rubik::Runtime::IndexService.sync_roots(@ctx, @index,
                                            additional_roots: [],
                                            ast_graph: graph,
                                            cache_store: cache_store)

    cache_file = cache_store.cache_path
    assert File.exist?(cache_file), "cache file should have been created"
  end

  def test_sync_roots_via_manager_reconciles
    make_marker_file("Gemfile")
    Rubik::Runtime::IndexService.register(@manager, @index)

    Rubik::Runtime::IndexService.sync_roots(@manager, @index,
                                            additional_roots: [])

    assert @index.files.key?("Gemfile")
  end

  def test_sync_roots_save_cache_error_suppressed
    make_ruby_file("err.rb", "def err; end")
    graph = Rubik::AST::Graph.new
    graph.index_file(File.join(@temp_dir, "err.rb"))

    failing_cache = Object.new
    def failing_cache.save(_data)
      raise "cache write failure"
    end

    # Should not raise
    Rubik::Runtime::IndexService.sync_roots(@ctx, @index,
                                            additional_roots: [],
                                            ast_graph: graph,
                                            cache_store: failing_cache)
  end
end
