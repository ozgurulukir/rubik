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

  def test_multi_file_plain_symbol_restoration_on_removal
    @graph.index_file("a.rb", "def process\n  :a\nend")
    @graph.index_file("b.rb", "def process\n  :b\nend")

    assert_equal "b.rb", @graph.symbols["process"].file

    @graph.remove_file("b.rb")

    assert @graph.symbols.key?("process")
    assert_equal "a.rb", @graph.symbols["process"].file

    @graph.remove_file("a.rb")

    refute @graph.symbols.key?("process")
    assert_nil @graph.symbols["process"]
  end

  def test_symbol_map_hash_interface_parity
    @graph.index_file("calc.rb", "def calculate\n  42\nend")

    map = @graph.symbols
    plain_key = "calculate"
    qualified_key = "ruby:calc.rb#calculate"

    assert map.key?(qualified_key)
    assert map.include?(qualified_key)
    assert map.member?(qualified_key)

    assert_equal "calc.rb", map.fetch(qualified_key).file
    assert_equal "calc.rb", map.fetch(plain_key).file
    assert_equal :default, map.fetch("missing", :default)
    assert_equal "missing_val", map.fetch("missing") { |k| "#{k}_val" }
    assert_raises(KeyError) { map.fetch("missing") }

    assert_includes map.keys, qualified_key
    assert_includes map.keys, plain_key

    assoc_entry = map.assoc(qualified_key)
    refute_nil assoc_entry
    assert_equal qualified_key, assoc_entry.first

    each_keys = map.each_key.to_a
    assert_includes each_keys, qualified_key

    hash_copy = map.to_h
    assert_kind_of Hash, hash_copy
    assert_equal map[qualified_key], hash_copy[qualified_key]

    assert_equal "calc.rb", map.dig(qualified_key).file # rubocop:disable Style/SingleArgumentDig

    sliced = map.slice(qualified_key)
    assert_equal map[qualified_key], sliced[qualified_key]
  end
end
