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

    # Stub TreeSitterExtractor.available? to true, supports? to true, but extract to nil
    Rubik::AST::TreeSitterExtractor.stub(:available?, true) do
      Rubik::AST::TreeSitterExtractor.stub(:supports?, true) do
        Rubik::AST::TreeSitterExtractor.stub(:extract, nil) do
          symbols = Rubik::AST::Extractor.extract("helper.go", code)
          refute_empty symbols
          names = symbols.map(&:name)
          assert(names.any? { |n| n.include?("Helper") })
        end
      end
    end
  end

  def test_extract_graceful_rescue_on_exception
    Rubik::AST::RubyExtractor.stub(:extract, ->(*_args) { raise StandardError, "Parse error" }) do
      symbols = Rubik::AST::Extractor.extract("broken.rb", "class Broken")
      assert_equal [], symbols
    end
  end
end
