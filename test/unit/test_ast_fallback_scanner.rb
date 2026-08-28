# frozen_string_literal: true

require_relative "../test_helper"

class TestAstFallbackScanner < Minitest::Test
  def fallback_symbols(src)
    Rubik::AST::RubyExtractor.new("test.rb", src, force_fallback: true).extract
  end

  def prism_symbols(src)
    Rubik::AST::RubyExtractor.new("test.rb", src).extract
  end

  def sym(symbols, name)
    symbols.find { |s| s.name == name }
  end

  def test_string_containing_keywords
    src = <<~RUBY
      class Demo
        def label
          "end if you dare"
        end
      end
    RUBY
    symbols = fallback_symbols(src)
    assert_equal [1, 5], [sym(symbols, "Demo").line_start, sym(symbols, "Demo").line_end]
    assert_equal [2, 4], [sym(symbols, "Demo#label").line_start, sym(symbols, "Demo#label").line_end]
  end

  def test_inline_comment_with_keywords
    src = <<~RUBY
      class Demo
        def label # end
          1
        end
      end
    RUBY
    symbols = fallback_symbols(src)
    assert_equal [2, 4], [sym(symbols, "Demo#label").line_start, sym(symbols, "Demo#label").line_end]
  end

  def test_heredoc_body_is_ignored
    src = <<~RUBY
      class Demo
        SQL = <<~SQL
          def fake
          end
        SQL

        def real
          2
        end
      end
    RUBY
    symbols = fallback_symbols(src)
    assert_nil sym(symbols, "Demo#fake"), "heredoc body must not produce symbols"
    assert_equal [7, 9], [sym(symbols, "Demo#real").line_start, sym(symbols, "Demo#real").line_end]
    assert_equal [1, 10], [sym(symbols, "Demo").line_start, sym(symbols, "Demo").line_end]
  end

  def test_modifier_if_consumes_no_end
    src = <<~RUBY
      class Demo
        def guard(x)
          return :no if x
          :yes
        end
      end
    RUBY
    symbols = fallback_symbols(src)
    assert_equal [2, 5], [sym(symbols, "Demo#guard").line_start, sym(symbols, "Demo#guard").line_end]
  end

  def test_endless_def_consumes_no_end
    src = <<~RUBY
      class Demo
        def double(x) = x * 2

        def triple(x)
          x * 3
        end
      end
    RUBY
    symbols = fallback_symbols(src)
    double = sym(symbols, "Demo#double")
    assert_equal [2, 2], [double.line_start, double.line_end]
    assert_equal [4, 6], [sym(symbols, "Demo#triple").line_start, sym(symbols, "Demo#triple").line_end]
  end

  def test_begin_and_while_blocks_are_openers
    src = <<~RUBY
      class Demo
        def spin
          begin
            x = 1
          end while false
        end
      end
    RUBY
    symbols = fallback_symbols(src)
    assert_equal [2, 6], [sym(symbols, "Demo#spin").line_start, sym(symbols, "Demo#spin").line_end]
    assert_equal [1, 7], [sym(symbols, "Demo").line_start, sym(symbols, "Demo").line_end]
  end

  def test_keyword_symbol_literal
    src = <<~RUBY
      class Demo
        def kind
          :end
        end
      end
    RUBY
    symbols = fallback_symbols(src)
    assert_equal [2, 4], [sym(symbols, "Demo#kind").line_start, sym(symbols, "Demo#kind").line_end]
  end

  def test_multiline_string_body
    src = <<~RUBY
      class Demo
        POEM = "line one
      end of poem
      "
        def after
          1
        end
      end
    RUBY
    symbols = fallback_symbols(src)
    assert_equal [5, 7], [sym(symbols, "Demo#after").line_start, sym(symbols, "Demo#after").line_end]
    assert_equal [1, 8], [sym(symbols, "Demo").line_start, sym(symbols, "Demo").line_end]
  end

  def test_regex_containing_quotes_does_not_open_phantom_string
    src = <<~RUBY
      class Config
        QUOTE = /["']/
        def load
          parse
        end
      end
    RUBY
    symbols = fallback_symbols(src)
    assert_equal [3, 5], [sym(symbols, "Config#load").line_start, sym(symbols, "Config#load").line_end]
    assert_equal [1, 6], [sym(symbols, "Config").line_start, sym(symbols, "Config").line_end]
  end

  def test_division_slash_is_not_treated_as_regex
    src = <<~RUBY
      class Calc
        def ratio(total)
          total / 4
        end
      end
    RUBY
    symbols = fallback_symbols(src)
    assert_equal [2, 4], [sym(symbols, "Calc#ratio").line_start, sym(symbols, "Calc#ratio").line_end]
  end

  def test_plain_heredoc_ignores_indented_terminator_lookalike
    src = ["class Demo",
           "  MSG = <<EOS",
           "  EOS",
           "    def ghost",
           "    end",
           "EOS",
           "  def real",
           "    1",
           "  end",
           "end"].join("\n") + "\n"
    symbols = fallback_symbols(src)
    assert_nil sym(symbols, "Demo#ghost"), "indented EOS must not close a plain <<EOS heredoc"
    assert_equal [7, 9], [sym(symbols, "Demo#real").line_start, sym(symbols, "Demo#real").line_end]
    assert_equal [1, 10], [sym(symbols, "Demo").line_start, sym(symbols, "Demo").line_end]
  end

  def test_fallback_ranges_match_prism_on_clean_source
    src = <<~RUBY
      class Demo
        def label
          "plain string"
        end
      end
    RUBY
    fallback = fallback_symbols(src)
    prism = prism_symbols(src)
    assert_equal prism.map { |s| [s.name, s.line_start, s.line_end] }.sort,
                 fallback.map { |s| [s.name, s.line_start, s.line_end] }.sort,
                 "on Prism-clean source both engines must agree on ranges"
  end

  def test_force_fallback_switches_engine
    skip "prism is not available on this install" unless Rubik::AST::RubyExtractor::PRISM_AVAILABLE

    src = "class Demo < Base\nend\n"
    # Prism rewrites the signature as "class Demo"; the fallback scanner
    # keeps the raw stripped line — an observable engine difference.
    assert_equal "class Demo", sym(prism_symbols(src), "Demo").signature
    assert_equal "class Demo < Base", sym(fallback_symbols(src), "Demo").signature
  end
end
