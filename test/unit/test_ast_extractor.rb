# frozen_string_literal: true

require_relative "../test_helper"

class TestASTExtractor < Minitest::Test
  def test_supported_extensions
    exts = Rubik::AST::Extractor.supported_extensions
    assert_includes exts, ".rb"
    assert_includes exts, ".py"
    assert_includes exts, ".go"
    assert_includes exts, ".rs"
    assert_includes exts, ".c"
    assert_includes exts, ".ts"
    assert_includes exts, ".tsx"
    assert_includes exts, ".js"
    assert_includes exts, ".jsx"
  end

  def test_extract_ruby_content
    code = <<~RUBY
      class Calculator
        def add(a, b)
          a + b
        end
      end
    RUBY

    symbols = Rubik::AST::Extractor.extract("calculator.rb", code)
    refute_empty symbols
    names = symbols.map(&:name)
    assert_includes names, "Calculator"
  end

  def test_extract_python_content
    code = <<~PYTHON
      class User:
          def get_name(self):
              return "Alice"
    PYTHON

    symbols = Rubik::AST::Extractor.extract("user.py", code)
    refute_empty symbols
    names = symbols.map(&:name)
    assert_includes names, "User"
  end

  def test_extract_go_content
    code = <<~GO
      package main

      type Server struct{}

      func StartServer() {}
    GO

    symbols = Rubik::AST::Extractor.extract("server.go", code)
    refute_empty symbols
    names = symbols.map(&:name)
    assert(names.any? { |n| n.include?("Server") || n.include?("StartServer") })
  end

  def test_extract_reading_file_from_disk_when_content_nil
    Dir.mktmpdir("ast_extractor_test") do |dir|
      file_path = File.join(dir, "sample.rb")
      File.write(file_path, "class SampleDisk; def run; end; end")

      symbols = Rubik::AST::Extractor.extract(file_path, nil)
      refute_empty symbols
      assert_equal "SampleDisk", symbols.first.name
    end
  end

  def test_extract_case_insensitivity
    code = "class UpperExt; end"
    symbols = Rubik::AST::Extractor.extract("UPPER.RB", code)
    refute_empty symbols
    assert_equal "UpperExt", symbols.first.name
  end

  def test_extract_fallback_for_unknown_extension
    code = "class DefaultFallback; end"
    symbols = Rubik::AST::Extractor.extract("script.unknown", code)
    refute_empty symbols
    assert_equal "DefaultFallback", symbols.first.name
  end

  def test_extract_treesitter_fallback_when_treesitter_returns_nil
    code = "func Helper() {}"
    failed = Rubik::AST::ExtractionResult.new(symbols: [], status: :failed,
                                              source: :none, detail: "simulated parser failure")

    # Tree-Sitter claims the file but fails -> regex fallback takes over
    Rubik::AST::TreeSitterExtractor.stub(:available?, true) do
      Rubik::AST::TreeSitterExtractor.stub(:supports?, true) do
        Rubik::AST::TreeSitterExtractor.stub(:extract_result, failed) do
          symbols = Rubik::AST::Extractor.extract("helper.go", code)
          refute_empty symbols
          names = symbols.map(&:name)
          assert(names.any? { |n| n.include?("Helper") })
        end
      end
    end
  end

  def test_broken_ruby_parse_is_reported_as_failed_not_ok
    skip "prism unavailable" unless Rubik::AST::RubyExtractor::PRISM_AVAILABLE

    broken = "class Foo\n  def ok; end\nend\ndef baz(; end\n"
    result = Rubik::AST::Extractor.extract_result("broken.rb", broken)

    assert_equal :failed, result.status
    assert_equal :ruby, result.source
    refute result.trustworthy?
    assert_match(/Prism/, result.detail.to_s)
  end

  def test_binary_tagged_source_with_invalid_bytes_is_not_a_syntax_error
    skip "prism unavailable" unless Rubik::AST::RubyExtractor::PRISM_AVAILABLE

    source = "class Foo\n  def \xFF; end\nend".b
    result = Rubik::AST::Extractor.extract_result("binary.rb", source)

    assert_equal :ok, result.status
    assert_equal :ruby, result.source
  end

  def test_broken_ruby_file_is_not_cached_or_indexed_as_valid
    skip "prism unavailable" unless Rubik::AST::RubyExtractor::PRISM_AVAILABLE

    Dir.mktmpdir("ast_broken_ruby") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".rubik"))
      path = File.join(dir, "broken.rb")
      File.write(path, "class Foo\n  def ok; end\nend\ndef baz(; end\n")

      graph = Rubik::AST::Graph.new
      graph.index_file(path)
      assert_equal :failed, graph.extraction_status(path)

      store = Rubik::AST::CacheStore.new(root_dir: dir)
      assert graph.save_to_cache(store)
      assert_empty store.load, "a failed extraction must not be persisted as a valid cache entry"
    end
  end

  def test_extract_graceful_rescue_on_exception
    Rubik::AST::RubyExtractor.stub(:extract_result, ->(*_args) { raise StandardError, "Parse error" }) do
      symbols = Rubik::AST::Extractor.extract("broken.rb", "class Broken")
      assert_equal [], symbols
    end
  end
end
