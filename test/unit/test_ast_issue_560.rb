# frozen_string_literal: true

require_relative "../test_helper"
require "timeout"

# Issue #560 regressions: anonymous C records, nested Ruby definitions,
# typedef kinds, and keeping the graph mutex free during parse/source I/O.
class TestASTIssue560 < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  # ── High: anonymous struct/union/enum used an undefined local `kind` ───

  def test_anonymous_c_record_does_not_raise_and_yields_a_symbol
    symbols = Rubik::AST::CExtractor.extract("t.c", "struct { int x; };")

    refute_empty symbols
    assert_equal "anonymous_struct_1", symbols.first.name
    assert_equal :struct, symbols.first.kind
  end

  def test_anonymous_union_and_enum_names_use_the_captured_kind
    symbols = Rubik::AST::CExtractor.extract("t.c", "union { int x; };\nenum { A };\n")

    names = symbols.map(&:name)
    assert_includes names, "anonymous_union_1"
    assert_includes names, "anonymous_enum_2"
    assert_equal :union, symbols.find { |s| s.name == "anonymous_union_1" }.kind
    assert_equal :enum, symbols.find { |s| s.name == "anonymous_enum_2" }.kind
  end

  def test_extractor_fallback_path_keeps_symbols_for_anonymous_struct
    Rubik::AST::TreeSitterExtractor.stub(:available?, false) do
      result = Rubik::AST::Extractor.extract_result("t.c", "struct { int x; };")

      assert_equal :ok, result.status
      assert_equal :fallback, result.source
      refute_empty result.symbols
    end
  end

  # ── Low: Prism DefNode branch did not walk nested definitions ──────────

  def test_prism_extractor_includes_nested_definitions
    skip "prism unavailable" unless Rubik::AST::RubyExtractor::PRISM_AVAILABLE

    code = <<~RUBY
      class Outer
        def first
          def nested_one; end
        end
        class Inner
          def inner_method; end
        end
      end
    RUBY

    names = Rubik::AST::RubyExtractor.extract("t.rb", code).map(&:name)
    assert_includes names, "Outer#first"
    assert_includes names, "Outer#nested_one"
    assert_includes names, "Inner"
    assert_includes names, "Inner#inner_method"
  end

  def test_prism_and_fallback_agree_on_nested_definitions
    skip "prism unavailable" unless Rubik::AST::RubyExtractor::PRISM_AVAILABLE

    code = <<~RUBY
      class Outer
        def first
          def nested_one; end
        end
      end
    RUBY

    prism_names = Rubik::AST::RubyExtractor.extract("t.rb", code).map(&:name).sort
    fallback_names = Rubik::AST::RubyExtractor.new("t.rb", code, force_fallback: true).extract.map(&:name).sort
    assert_equal fallback_names, prism_names
  end

  # ── Low: typedef kind was hardcoded to :struct ────────────────────────

  def test_typedef_kinds_follow_the_underlying_type
    skip "tree-sitter unavailable" unless Rubik::AST::TreeSitterExtractor.available?

    code = <<~C
      typedef struct Point { int x; } Point;
      typedef union Value { int i; } Value;
      typedef enum Color { RED } Color;
      typedef int MyInt;
      typedef int (*Fn)(int);
    C

    symbols = Rubik::AST::Extractor.extract_result("t.c", code).symbols
    kinds = symbols.to_h { |s| [s.name, s.kind] }

    assert_equal :struct, kinds["Point"]
    assert_equal :union, kinds["Value"]
    assert_equal :enum, kinds["Color"]
    assert_equal :type, kinds["MyInt"]
    fn = symbols.find { |s| s.name.include?("Fn") }
    refute_nil fn
    assert_equal :type, fn.kind
  end

  # ── Medium: parse/source reads must happen outside the graph mutex ────

  def test_outline_for_does_not_hold_mutex_during_extraction
    graph = Rubik::AST::Graph.new
    file = File.join(@temp_dir, "outline_slow.c")
    File.write(file, "struct Slow { int x; };\n")

    started = Queue.new
    release = Queue.new
    blocking = lambda do |path, _content = nil|
      started << true
      release.pop
      Rubik::AST::ExtractionResult.new(
        symbols: [Rubik::AST::Symbol.new(name: "Slow", kind: :struct, file: path, line_start: 1, line_end: 1)],
        status: :ok,
        source: :fallback
      )
    end

    Rubik::AST::Extractor.stub(:extract_result, blocking) do
      worker = Thread.new { graph.outline_for(file) }
      probe = nil
      begin
        started.pop
        probed = Queue.new
        probe = Thread.new do
          graph.symbols
          probed << true
        end
        acquired = begin
          Timeout.timeout(2) { probed.pop }
        rescue Timeout::Error
          false
        end
        assert acquired, "outline_for must not hold the graph mutex while parsing a file"
      ensure
        release << true
        worker.join
        probe&.join
      end
    end
  end

  def test_smart_context_for_does_not_hold_mutex_during_body_read
    graph = Rubik::AST::Graph.new
    file = File.join(@temp_dir, "body_slow.rb")
    File.write(file, "def slow_target; end\n")

    body_started = Queue.new
    body_release = Queue.new
    sym = Rubik::AST::Symbol.new(
      name: "slow_target",
      kind: :function,
      file: file,
      line_start: 1,
      line_end: 1,
      body_loader: lambda {
        body_started << true
        body_release.pop
        "def slow_target; end\n"
      }
    )
    result = Rubik::AST::ExtractionResult.new(symbols: [sym], status: :ok, source: :ruby)

    Rubik::AST::Extractor.stub(:extract_result, ->(_path, _content = nil) { result }) do
      graph.index_file(file, "def slow_target; end\n")
      worker = Thread.new { graph.smart_context_for("slow_target") }
      probe = nil
      begin
        body_started.pop
        probed = Queue.new
        probe = Thread.new do
          graph.symbols
          probed << true
        end
        acquired = begin
          Timeout.timeout(2) { probed.pop }
        rescue Timeout::Error
          false
        end
        assert acquired, "smart_context_for must not hold the graph mutex while reading a body"
      ensure
        body_release << true
        worker.join
        probe&.join
      end
    end
  end

  def test_symbol_definition_does_not_hold_mutex_during_source_read
    graph = Rubik::AST::Graph.new
    file = File.join(@temp_dir, "definition_slow.rb")
    File.write(file, "def disk_target; 42; end\n")

    # No in-memory body and no body_loader: Symbol#body must fall back to
    # File.readlines, which we block to observe whether the graph lock is held.
    sym = Rubik::AST::Symbol.new(
      name: "disk_target",
      kind: :function,
      file: file,
      line_start: 1,
      line_end: 1
    )
    result = Rubik::AST::ExtractionResult.new(symbols: [sym], status: :ok, source: :ruby)

    read_started = Queue.new
    read_release = Queue.new
    real_readlines = File.method(:readlines)
    blocking_readlines = lambda do |*args, **kwargs|
      read_started << true
      read_release.pop
      real_readlines.call(*args, **kwargs)
    end

    Rubik::AST::Extractor.stub(:extract_result, ->(_path, _content = nil) { result }) do
      graph.index_file(file, "def disk_target; 42; end\n")
      File.stub(:readlines, blocking_readlines) do
        worker = Thread.new { graph.symbol_definition("disk_target") }
        probe = nil
        begin
          Timeout.timeout(2) { read_started.pop }
          probed = Queue.new
          probe = Thread.new do
            graph.symbols
            probed << true
          end
          acquired = begin
            Timeout.timeout(2) { probed.pop }
          rescue Timeout::Error
            false
          end
          assert acquired, "symbol_definition must not hold the graph mutex while reading source from disk"
        ensure
          read_release << true
          worker.join
          probe&.join
        end
        assert_equal "def disk_target; 42; end\n", worker.value[:body]
      end
    end
  end

  def test_outline_for_still_indexes_unindexed_files
    graph = Rubik::AST::Graph.new
    file = File.join(@temp_dir, "outline.c")
    File.write(file, "struct Point { int x; };\nint main(void) { return 0; }\n")

    outline = graph.outline_for(file)

    assert_includes outline, "=== Outline for #{file}"
    assert_includes outline, "Point"
    assert_includes outline, "main"
    assert graph.symbols.key?("main"), "outline_for must merge parsed symbols into the graph"
  end

  def test_smart_context_for_still_returns_target_and_dependency
    graph = Rubik::AST::Graph.new
    graph.index_file("service.rb", <<~RUBY)
      class Service
        def process
          helper
        end
        def helper
          42
        end
      end
    RUBY

    context = graph.smart_context_for("Service#process")

    assert_includes context, "Target symbol: Service#process"
    assert_includes context, "Dependency signature: Service#helper"
  end
end
