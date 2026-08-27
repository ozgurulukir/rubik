# frozen_string_literal: true

require_relative "../test_helper"

# Plan 52 Faz A: lazy hash contract (git's stat-dirty model), in-memory lazy
# symbol bodies, and the duplicate-free graph search.
class TestLazyHashAndLazyBody < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    File.write(File.join(@temp_dir, "sample.rb"), <<~RUBY)
      class Sample
        def alpha
          42
        end
      end
    RUBY
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  # --- Scanner lazy hash contract (D3) ---

  def test_cold_scan_starts_hash_less_without_reading_content
    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir, native: "off")
    files = scanner.scan

    assert_nil files["sample.rb"][:hash], "cold entries must not pay for reads+hashing"
    assert_equal File.size(File.join(@temp_dir, "sample.rb")), files["sample.rb"][:size]
  end

  def test_stat_clean_rescan_stays_hash_less
    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir, native: "off")
    first = scanner.scan
    second = scanner.scan(first)

    assert_nil second["sample.rb"][:hash]
  end

  def test_stat_change_computes_hash_and_flags_modification
    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir, native: "off")
    first = scanner.scan

    File.write(File.join(@temp_dir, "sample.rb"), "class Sample\nend\n")
    second = scanner.scan(first)

    assert !second["sample.rb"][:hash].nil?, "stat-dirty entries are hashed eagerly"
    assert_nil first["sample.rb"][:hash]
  end

  def test_update_file_stays_eager_and_detects_content_change
    index = Rubik::Context::Index.new(root_dir: @temp_dir, native: "off")
    index.full_scan
    assert_nil index.files["sample.rb"][:hash]

    File.write(File.join(@temp_dir, "sample.rb"), "class Sample\n  def beta\n  end\nend\n")
    assert index.update_file("sample.rb"), "single-file probe must hash eagerly"
    assert !index.files["sample.rb"][:hash].nil?
    refute index.update_file("sample.rb"), "second probe with same content is unchanged"
  end

  # --- Extractor lazy body (D6.3) ---

  def test_extracted_symbols_defer_body_until_accessed
    path = File.join(@temp_dir, "sample.rb")
    syms = Rubik::AST::RubyExtractor.extract(path)

    alpha = syms.find { |s| s.name == "Sample#alpha" }
    refute_nil alpha
    assert_includes alpha.body, "42", "first access loads the body"

    # Loader fires at most once; value is cached afterwards.
    assert_same alpha.body, alpha.body
  end

  def test_lazy_body_matches_eager_slice
    path = File.join(@temp_dir, "sample.rb")
    lazy = Rubik::AST::RubyExtractor.extract(path).find { |s| s.name == "Sample#alpha" }

    eager = Rubik::AST::RubyExtractor.new(path)
    eager_symbols = eager.extract
    # Simulate the historical eager path by materializing lines up front.
    eager.send(:lines)
    alpha_eager = eager_symbols.find { |s| s.name == "Sample#alpha" }

    assert_equal alpha_eager.body, lazy.body
  end

  # Regression for the while-loop closure binding bug: loaders built inside a
  # `while` loop must resolve to THEIR OWN symbol's slice, not the loop's
  # final line_num/end_line (lambda default args evaluate at call time).
  def test_multi_symbol_file_bodies_are_per_symbol
    path = File.join(@temp_dir, "multi.py")
    File.write(path, "def first():\n    return 1\n\ndef second():\n    return 2\n")

    syms = Rubik::AST::PythonExtractor.extract(path)
    first = syms.find { |s| s.name == "first" }
    second = syms.find { |s| s.name == "second" }

    assert_includes first.body, "return 1", "first symbol's body must be its own slice"
    refute_includes first.body, "return 2"
    assert_includes second.body, "return 2", "second symbol's body must be its own slice"
    refute_includes second.body, "return 1"
  end

  def test_cache_loaded_symbol_body_still_reads_from_source
    graph = Rubik::AST::Graph.new
    path = File.join(@temp_dir, "sample.rb")
    graph.index_file(path)
    snapshot = { path => graph.file_symbols[path].map { |s| Rubik::AST::Symbol.from_h(s.to_h(include_body: true), path) } }
    other_path = File.join(@temp_dir, "sample.rb")

    reloaded = snapshot[path].map { |h| Rubik::AST::Symbol.from_h(h.to_h(include_body: false), other_path) }
    alpha = reloaded.find { |s| s.name == "Sample#alpha" }
    assert_includes alpha.body, "42"
  end

  # --- Graph#search_symbols (D6.1) ---

  def test_search_symbols_matches_substring_case_insensitive
    graph = Rubik::AST::Graph.new
    graph.index_file(File.join(@temp_dir, "sample.rb"))

    hits = graph.search_symbols("ALPH")
    assert_equal 1, hits.size
    assert_equal "Sample#alpha", hits.first.name
    assert_empty graph.search_symbols("zzz")
  end
end
