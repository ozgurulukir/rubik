# frozen_string_literal: true

require_relative "../test_helper"

class TestRuntimeASTService < Minitest::Test
  def setup
    @ctx = Rubik::Runtime::Context.new
    @manager = Rubik::Runtime::Manager.new(@ctx)
    @graph = Rubik::AST::Graph.new
    @temp_dir = Dir.mktmpdir("ast_service_test")
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
    @ctx.dispose unless @ctx.disposed?
  end

  def make_file_with_symbol(rel, sym_content = "def foo; end")
    full = File.join(@temp_dir, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, "# frozen_string_literal: true\n#{sym_content}\n")
  end

  # ── register ───────────────────────────────────────────────────────

  def test_registers_ast_graph_into_context
    result = Rubik::Runtime::ASTService.register(@ctx, @graph)

    assert_same @graph, result
    assert_same @graph, @ctx.get("ast_graph")
    # Canonical key only: the legacy "ast" alias is not stored literally by
    # the service, but reads through the alias resolve to the canonical graph
    # (Runtime::Context alias bridge, Rubik::Coeffects SSOT).
    refute @ctx.services.key?("ast")
    assert_same @graph, @ctx.get("ast")
  end

  def test_registers_via_manager_and_reconciles
    Rubik::Runtime::ASTService.register(@manager, @graph)

    assert_same @graph, @manager.context.get("ast_graph")
  end

  def test_returns_graph_when_context_unavailable
    result = Rubik::Runtime::ASTService.register(nil, @graph)
    assert_same @graph, result
  end

  def test_on_dispose_clears_graph
    make_file_with_symbol("test.rb")
    Rubik::Runtime::ASTService.register(@ctx, @graph)
    @graph.index_file(File.join(@temp_dir, "test.rb"))

    refute_empty @graph.file_symbols

    @ctx.dispose

    assert_empty @graph.file_symbols
  end

  def test_on_dispose_saves_to_cache_if_cache_store_provided
    cache_store = Rubik::AST::CacheStore.new(root_dir: @temp_dir)
    make_file_with_symbol("dummy.rb")

    Rubik::Runtime::ASTService.register(@ctx, @graph, cache_store: cache_store)
    @graph.index_file(File.join(@temp_dir, "dummy.rb"))

    @ctx.dispose

    cache_file = cache_store.cache_path
    assert File.exist?(cache_file), "cache file should exist after dispose"
  end

  def test_on_dispose_cache_save_error_suppressed
    failing_cache = Object.new
    def failing_cache.save(*, **)
      raise "disk full"
    end

    Rubik::Runtime::ASTService.register(@ctx, @graph, cache_store: failing_cache)

    # Should not raise on dispose
    @ctx.dispose

    assert @ctx.disposed?
  end

  # ── purge_stale_entries! ───────────────────────────────────────────

  def test_purges_files_not_in_context_index
    make_file_with_symbol("lib/active.rb", "class Active; end")
    make_file_with_symbol("lib/stale.rb", "class Stale; end")

    @graph.index_file(File.join(@temp_dir, "lib", "active.rb"))
    @graph.index_file(File.join(@temp_dir, "lib", "stale.rb"))

    index = Rubik::Context::Index.new(root_dir: @temp_dir)
    index.files.replace({ "lib/active.rb" => { mtime: Time.now, size: 5, hash: "abc" } })

    purged = Rubik::Runtime::ASTService.purge_stale_entries!(@graph, index, @temp_dir)

    assert_equal 1, purged
    stale_key = @graph.file_symbols.keys.find { |k| k.to_s.include?("stale.rb") }
    refute stale_key, "stale.rb should have been purged"
    active_key = @graph.file_symbols.keys.find { |k| k.to_s.include?("active.rb") }
    assert active_key, "active.rb should remain"
  end

  def test_no_purge_when_index_files_empty
    make_file_with_symbol("lib/file.rb", "class Filez; end")
    @graph.index_file(File.join(@temp_dir, "lib", "file.rb"))

    index = Rubik::Context::Index.new(root_dir: @temp_dir)
    # index.files is empty after initialization

    purged = Rubik::Runtime::ASTService.purge_stale_entries!(@graph, index, @temp_dir)

    assert_equal 0, purged
    # empty guard protects the graph from wipe
    assert(@graph.file_symbols.keys.any? { |k| k.to_s.include?("file.rb") })
  end

  def test_does_not_purge_files_outside_root
    external = File.join(Dir.tmpdir, "external.rb")
    File.write(external, "def helper; end")
    begin
      @graph.index_file(external)

      index = Rubik::Context::Index.new(root_dir: @temp_dir)
      index.files.replace({})

      purged = Rubik::Runtime::ASTService.purge_stale_entries!(@graph, index, @temp_dir)

      assert_equal 0, purged
      # external file outside root_prefix untouched
      assert(@graph.file_symbols.keys.any? { |k| k.to_s == external },
             "external file should remain")
    ensure
      FileUtils.rm_f(external)
    end
  end

  def test_purge_ignores_unsupported_extensions_unless_indexed
    make_file_with_symbol("lib/app.rb", "def foo; end")
    full_txt = File.join(@temp_dir, "lib", "notes.txt")
    FileUtils.mkdir_p(File.dirname(full_txt))
    File.write(full_txt, "just text")

    @graph.index_file(full_txt)
    @graph.index_file(File.join(@temp_dir, "lib", "app.rb"))

    index = Rubik::Context::Index.new(root_dir: @temp_dir)
    index.files.replace({ "lib/app.rb" => { mtime: Time.now, size: 8, hash: "abc" } })

    purged = Rubik::Runtime::ASTService.purge_stale_entries!(@graph, index, @temp_dir)

    # notes.txt has unsupported extension (.txt), skipped by extension check
    # app.rb is present, so nothing purged
    assert_equal 0, purged
  end

  def test_purge_returns_purged_count
    make_file_with_symbol("a.rb", "class A; end")
    make_file_with_symbol("b.rb", "class B; end")

    @graph.index_file(File.join(@temp_dir, "a.rb"))
    @graph.index_file(File.join(@temp_dir, "b.rb"))

    index = Rubik::Context::Index.new(root_dir: @temp_dir)
    index.files.replace({ "a.rb" => { mtime: Time.now, size: 3, hash: "x" } })

    purged = Rubik::Runtime::ASTService.purge_stale_entries!(@graph, index, @temp_dir)

    assert_equal 1, purged
  end
end
