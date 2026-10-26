# frozen_string_literal: true

require_relative "../test_helper"

class TestASTIndex < Minitest::Test
  def setup
    @graph = Rubik::AST::Graph.new
  end

  def test_extract_ruby_symbols
    code = <<~RUBY
      module Calculator
        class Engine
          def add(a, b)
            validate(a)
            a + b
          end

          def validate(n)
            raise unless n.is_a?(Numeric)
          end
        end
      end
    RUBY

    @graph.index_file("lib/engine.rb", code)

    assert @graph.symbols.key?("Calculator")
    assert @graph.symbols.key?("Engine")
    assert @graph.symbols.key?("Engine#add")

    add_sym = @graph.symbols["Engine#add"]
    assert_equal :function, add_sym.kind
    assert_includes add_sym.calls, "validate"
  end

  def test_smart_context_selection
    code_a = <<~RUBY
      class Service
        def process(data)
          format(data)
        end

        def format(d)
          d.to_s
        end
      end
    RUBY

    @graph.index_file("service.rb", code_a)
    smart_ctx = @graph.smart_context_for("Service#process")

    assert_includes smart_ctx, "def process(data)"
    assert_includes smart_ctx, "Dependency signature:"
  end

  def test_incremental_reindexing
    @graph.index_file("a.rb", "class A\n  def foo\n  end\nend")
    @graph.index_file("b.rb", "class B\nend")

    assert_equal 3, @graph.symbols.size

    @graph.index_file("b.rb", "class B\n  def bar\n  end\nend")

    assert @graph.symbols.key?("A#foo")
    assert @graph.symbols.key?("B#bar")
  end
end
