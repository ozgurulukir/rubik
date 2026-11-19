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
           "end", ""].join("\n")
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

  # --- Issue #600: scope stack + escaped slash in regex literals ------------

  def test_top_level_def_after_class_body_is_not_misattributed
    src = <<~RUBY
      class A
        def inside
          1
        end
      end

      def helper
        2
      end
    RUBY
    symbols = fallback_symbols(src)
    assert_equal [7, 9], [sym(symbols, "helper").line_start, sym(symbols, "helper").line_end],
                 "a def after the class body closed must index at top level"
    assert_nil sym(symbols, "A#helper")
    assert_equal [2, 4], [sym(symbols, "A#inside").line_start, sym(symbols, "A#inside").line_end]
  end

  def test_nested_module_and_class_yield_qualified_names
    src = <<~RUBY
      module M
        class C
          def work
            1
          end
        end
      end
    RUBY
    symbols = fallback_symbols(src)
    assert sym(symbols, "M::C"), "nested class must carry the M:: prefix"
    assert sym(symbols, "M::C#work"), "methods in a nested class must be qualified as M::C#work"
    assert_equal [1, 7], [sym(symbols, "M").line_start, sym(symbols, "M").line_end]
    assert_equal [2, 6], [sym(symbols, "M::C").line_start, sym(symbols, "M::C").line_end]
  end

  def test_defs_after_nested_module_close_at_top_level
    src = <<~RUBY
      module Outer
        class Inner
          def deep
            1
          end
        end
      end

      def top
        2
      end
    RUBY
    symbols = fallback_symbols(src)
    assert_equal [9, 11], [sym(symbols, "top").line_start, sym(symbols, "top").line_end]
    assert sym(symbols, "Outer::Inner#deep")
    assert_nil sym(symbols, "Outer::Inner#top")
  end

  def test_regex_span_end_skips_escaped_slash
    cleaner = Rubik::AST::FallbackCleaner
    raw = "/a\\/b/"
    fin = cleaner.regex_span_end(raw, 0)
    assert_equal 5, fin, "the closing delimiter is the final slash, not the escaped \\/"
  end

  def test_regex_with_escaped_slash_is_fully_blanked
    src = <<~RUBY
      class Slashy
        PATTERN = /end\\/def/
        def real
          1
        end
      end
    RUBY
    symbols = fallback_symbols(src)
    assert_equal [3, 5], [sym(symbols, "Slashy#real").line_start, sym(symbols, "Slashy#real").line_end],
                 "keywords inside a regex with \\/ must stay blanked for end-matching"
    assert_equal [1, 6], [sym(symbols, "Slashy").line_start, sym(symbols, "Slashy").line_end]
  end
end
