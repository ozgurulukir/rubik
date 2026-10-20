# frozen_string_literal: true

require_relative "../test_helper"

class TestASTSymbolQueryOutcomes < Minitest::Test
  SearchSymbol = Struct.new(:kind, :name, :file, :line_start, :line_end, :signature, :calls)

  def setup
    @temp_dir = Dir.mktmpdir("rubik_ast_symbol_queries_")
    @graph = Rubik::AST::Graph.new
  end

  def teardown
    remove_temp_dir(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
  end

  def test_qualified_queries_isolate_duplicate_names_and_bare_queries_are_ambiguous
    alpha_file = write_file("alpha.rb", "def render; end\ndef alpha_caller; render; end\n")
    beta_file = write_file("beta.rb", "def render; end\ndef beta_caller; render; end\n")
    dynamic_file = write_file("dynamic.rb", "def render; end\ndef dynamic_caller(view); view.render; end\n")

    [alpha_file, beta_file, dynamic_file].each { |path| @graph.index_file(path) }

    candidates = @graph.symbol_candidates("render")
    assert_equal 3, candidates.length
    assert_equal candidates.sort, candidates

    alpha_key = candidates.find { |key| key.include?("alpha.rb") }
    beta_key = candidates.find { |key| key.include?("beta.rb") }

    alpha_callers = @graph.callers_of(alpha_key)
    beta_callers = @graph.callers_of(beta_key)
    assert_equal ["alpha_caller"], alpha_callers.map(&:name)
    assert_equal ["beta_caller"], beta_callers.map(&:name)

    # A receiver call whose type is unknown is retained by extraction but is
    # not assigned to each same-named definition.
    dynamic_symbol = @graph.symbols.qualified_symbols.values.find do |symbol|
      symbol.name == "dynamic_caller"
    end
    assert_includes dynamic_symbol.calls, "view.render"
    refute_includes @graph.callers_of(candidates.find { |key| key.include?("dynamic.rb") }).map(&:name), "dynamic_caller"

    scoped_graph = Rubik::AST::Graph.new
    scoped_file = write_file("scoped.rb", <<~RUBY)
      class Alpha
        def render; end
        def caller; render; end
      end
      class Beta
        def render; end
        def caller; render; end
      end
    RUBY
    scoped_graph.index_file(scoped_file)
    alpha_render = scoped_graph.symbol_candidates("Alpha#render").first
    beta_render = scoped_graph.symbol_candidates("Beta#render").first
    assert_equal ["Alpha#caller"], scoped_graph.callers_of(alpha_render).map(&:name)
    assert_equal ["Beta#caller"], scoped_graph.callers_of(beta_render).map(&:name)

    error = assert_raises(Rubik::AST::Graph::AmbiguousSymbolError) do
      @graph.callers_of("render")
    end
    assert_equal candidates, error.candidates
    assert_nil @graph.symbol_definition("render")

    refs = Rubik::Tools::FindReferencesTool.new(@graph).execute(symbol_name: "render")
    assert refs.error?
    assert_includes refs, "Ambiguous symbol 'render'"
    candidates.each { |key| assert_includes refs, key }

    get_symbol = Rubik::Tools::GetSymbolTool.new(@graph).execute(symbol_name: "render")
    assert get_symbol.error?
    assert_includes get_symbol, "Ambiguous symbol 'render'"
    candidates.each { |key| assert_includes get_symbol, key }

    alpha = Rubik::Tools::GetSymbolTool.new(@graph).execute(symbol_name: alpha_key)
    assert_includes alpha, "Symbol: render"
    assert_includes alpha, alpha_file
  end

  def test_qualified_values_are_enumerated_once_and_search_is_ranked_stably
    first = write_file("first.rb", "def renderer; end\ndef prerender; end\ndef render; end\n")
    second = write_file("second.rb", "def render_window; end\n")
    [first, second].each { |path| @graph.index_file(path) }

    qualified = @graph.symbols.qualified_symbols.values.uniq
    assert_equal qualified.length, @graph.symbols.values.uniq.length
    assert_equal 4, @graph.search_symbols("render").length

    names = @graph.search_symbols("render").map(&:name)
    assert_equal ["render", "renderer", "render_window", "prerender"], names
    assert_equal 4, @graph.search_symbols("r").length
  end

  def test_file_symbols_returns_deep_snapshots_used_by_future_cache_saves
    path = write_file("snapshot.rb", "def original; end\n")
    @graph.index_file(path)
    symbol = @graph.file_symbols.fetch(path).first

    snapshot = @graph.file_symbols
    snapshot.fetch(path).clear
    snapshot.delete(path)

    assert_equal [symbol], @graph.file_symbols.fetch(path)

    saved = nil
    cache = Object.new
    cache.define_singleton_method(:save) do |file_symbols|
      saved = file_symbols
      true
    end

    assert @graph.save_to_cache(cache)
    assert_equal [symbol], saved.fetch(path)
  end

  def test_search_tool_accepts_single_character_and_bounds_utf8_results
    symbols = 65.times.map do |index|
      SearchSymbol.new(:method, "a_symbol_#{index}", "lib/#{index}.rb", 1, 2,
                       "def a_symbol_#{index}", ["é" * 180])
    end
    graph = Object.new
    graph.define_singleton_method(:search_symbols) { |query| query == "a" ? symbols : [] }
    graph.define_singleton_method(:symbols) { {} }

    output = Rubik::Tools::SearchSymbolsTool.new(graph).execute(query: "a")

    assert output.valid_encoding?
    assert_operator output.bytesize, :<=, Rubik::Tools::Truncator::DEFAULT_MAX_CHARS
    assert_operator output.lines.count, :<=, Rubik::Tools::Truncator::DEFAULT_MAX_LINES
    shown = output.scan(/^•/).length
    assert_operator shown, :<=, 50
    omitted = output[/^(?:\.\.\. )?(\d+) additional matches omitted\.$/, 1]
    assert_equal symbols.length, shown + omitted.to_i
  end

  def test_search_tool_reports_no_match_on_error_channel_and_rejects_bad_schema_values
    tool = Rubik::Tools::SearchSymbolsTool.new(@graph)

    no_match = tool.execute(query: "does_not_exist")
    assert_kind_of Rubik::Tools::ToolOutput, no_match
    assert no_match.error?

    invalid_query = tool.execute(query: 42)
    assert invalid_query.error?
    assert_includes invalid_query, "query must be a string"

    invalid_smart_context = tool.execute(query: "render", smart_context: "yes")
    assert invalid_smart_context.error?
    assert_includes invalid_smart_context, "smart_context must be a boolean"
  end

  def test_outline_distinguishes_failed_empty_and_partial_extraction
    path = write_file("outline.rb", "")
    tool = Rubik::Tools::GetOutlineTool.new(@graph)

    failed = Rubik::AST::ExtractionResult.new(symbols: [], status: :failed, source: :none, detail: "bad parse")
    failed_output = Rubik::AST::Extractor.stub(:extract_result, failed) do
      tool.execute(file_path: path)
    end
    assert failed_output.error?
    assert_includes failed_output, "Outline extraction failed"

    empty = Rubik::AST::ExtractionResult.new(symbols: [], status: :ok, source: :ruby)
    empty_output = Rubik::AST::Extractor.stub(:extract_result, empty) do
      tool.execute(file_path: path)
    end
    assert_includes empty_output, "No symbols found"
    refute empty_output.error? if empty_output.respond_to?(:error?)

    partial_symbol = Rubik::AST::Symbol.new(name: "Known", kind: :class, file: path, line_start: 1, line_end: 1)
    partial = Rubik::AST::ExtractionResult.new(symbols: [partial_symbol], status: :partial, source: :ruby)
    partial_output = Rubik::AST::Extractor.stub(:extract_result, partial) do
      tool.execute(file_path: path)
    end
    assert_includes partial_output, "Partial extraction"
    assert_includes partial_output, "Known"
  end

  def test_symbol_tools_report_index_warming_with_progress
    token = @graph.begin_warmup(total: 5)
    @graph.update_warmup(token, indexed: 2, total: 5)

    requests = [
      [Rubik::Tools::SearchSymbolsTool.new(@graph), { query: "render" }],
      [Rubik::Tools::GetOutlineTool.new(@graph), { file_path: "some.rb" }],
      [Rubik::Tools::FindReferencesTool.new(@graph), { symbol_name: "render" }],
      [Rubik::Tools::GetSymbolTool.new(@graph), { symbol_name: "render" }]
    ]

    requests.each do |tool, args|
      output = tool.execute(args)
      assert output.error?
      assert_includes output, "AST index warming"
      assert_includes output, "2/5"
    end
  ensure
    @graph.finish_warmup(token) if token
  end

  def test_symbol_tools_reject_non_string_path_and_symbol_arguments
    assert Rubik::Tools::GetOutlineTool.new(@graph).execute(file_path: 7).error?
    assert Rubik::Tools::GetOutlineTool.new(@graph).execute(path: []).error?
    assert Rubik::Tools::FindReferencesTool.new(@graph).execute(symbol_name: 7).error?
    assert Rubik::Tools::FindReferencesTool.new(@graph).execute(symbol: []).error?
    assert Rubik::Tools::GetSymbolTool.new(@graph).execute(symbol_name: 7).error?
    assert Rubik::Tools::GetSymbolTool.new(@graph).execute(symbol: []).error?

    legacy_path = write_file("legacy.rb", "def legacy; end\n")
    outline = Rubik::Tools::GetOutlineTool.new(@graph).execute(path: legacy_path)
    assert_includes outline, "legacy"
    reference = Rubik::Tools::FindReferencesTool.new(@graph).execute(symbol: "legacy")
    assert_includes reference, "No references"
    definition = Rubik::Tools::GetSymbolTool.new(@graph).execute(symbol: "legacy")
    assert_includes definition, "Symbol: legacy"
  end

  def test_parser_call_extraction_keeps_receivers_and_ruby_self_recursion
    ruby_file = write_file("calls.rb", <<~RUBY)
      class Renderer
        def render; end
      def recurse; recurse(); end
        def delegate(view); view.render; end
      end
    RUBY
    ruby_symbols = Rubik::AST::RubyExtractor.extract(ruby_file)
    recursive = ruby_symbols.find { |symbol| symbol.name == "Renderer#recurse" }
    delegate = ruby_symbols.find { |symbol| symbol.name == "Renderer#delegate" }
    assert_includes recursive.calls, "recurse"
    assert_includes delegate.calls, "view.render"

    @graph.index_file(ruby_file)
    recurse_key = @graph.symbol_candidates("Renderer#recurse").first
    assert_equal ["Renderer#recurse"], @graph.callers_of(recurse_key).map(&:name)

    fixtures = {
      ".go" => ["package p\ntype Renderer struct{}\nfunc (r *Renderer) Render() {}\nfunc (r *Renderer) Delegate() { r.Render() }\n", "r.Render"],
      ".ts" => ["class Renderer { render() {} delegate(other: Renderer) { this.render(); other.render(); } }\n", "other.render"],
      ".py" => ["class Renderer:\n    def render(self): pass\ndef delegate(obj):\n    obj.render()\n", "obj.render"],
      ".rs" => ["struct Renderer; impl Renderer { fn render(&self) {} fn delegate(&self, other: &Renderer) { self.render(); other.render(); } }\n", "other.render"],
      ".c" => ["struct Renderer { int value; }; void delegate(struct Renderer *obj) { obj->render(); }\n", "obj->render"],
      ".zig" => [
        "const Renderer = struct { fn render(self: *Renderer) void {} }; " \
        "pub fn delegate(renderer: *Renderer) void { const v = renderer.value; renderer.render(foo(1, 2)); plain(bar(3)); }\n",
        "renderer.render"
      ]
    }

    fixtures.each do |extension, (code, expected_call)|
      symbols = Rubik::AST::TreeSitterExtractor.extract("calls#{extension}", code)
      refute_nil symbols, "#{extension} parser should extract calls"
      assert symbols.any? { |symbol| symbol.calls.include?(expected_call) },
             "#{extension} should retain receiver in #{expected_call.inspect}"
    end

    zig_symbols = Rubik::AST::TreeSitterExtractor.extract("calls.zig", fixtures.fetch(".zig").first)
    zig_delegate = zig_symbols.find { |symbol| symbol.name == "delegate" }
    refute_includes zig_delegate.calls, "renderer.value"
    assert_includes zig_delegate.calls, "renderer.render"
    assert_includes zig_delegate.calls, "foo"
    assert_includes zig_delegate.calls, "plain"
    assert_includes zig_delegate.calls, "bar"
  end

  def test_cross_file_scoped_collisions_and_go_receiver_callers_stay_isolated
    alpha_one = write_file("alpha_one.rb", "class Alpha\n  def render; end\n  def run; Alpha.render; end\nend\n")
    alpha_two = write_file("alpha_two.rb", "class Alpha\n  def render; end\n  def run; Alpha.render; end\nend\n")
    [alpha_one, alpha_two].each { |path| @graph.index_file(path) }

    candidates = @graph.symbol_candidates("Alpha#render")
    assert_equal 2, candidates.length
    one_key = candidates.find { |key| key.include?("alpha_one.rb") }
    two_key = candidates.find { |key| key.include?("alpha_two.rb") }

    one_callers = @graph.callers_of(one_key)
    two_callers = @graph.callers_of(two_key)
    assert_equal [alpha_one], one_callers.map(&:file)
    assert_equal [alpha_two], two_callers.map(&:file)
    assert_equal "", @graph.smart_context_for("Alpha#render")
    assert_includes @graph.smart_context_for(one_key), alpha_one

    go_file = write_file("renderer.go", "package p\ntype Renderer struct{}\nfunc (r *Renderer) Render() {}\nfunc (r *Renderer) Delegate() { r.Render() }\n")
    @graph.index_file(go_file)
    go_render = @graph.symbol_candidates("Render").first
    assert_equal ["(r *Renderer).Delegate"], @graph.callers_of(go_render).map(&:name)
  end

  def test_single_oversized_search_match_and_canonical_extraction_status
    oversized = SearchSymbol.new(:method, "huge_symbol", "lib/huge.rb", 1, 2,
                                 "def huge_symbol", ["x" * (Rubik::Tools::Truncator::DEFAULT_MAX_CHARS + 500)])
    graph = Object.new
    graph.define_singleton_method(:search_symbols) { |_query| [oversized] }
    graph.define_singleton_method(:symbols) { {} }

    output = Rubik::Tools::SearchSymbolsTool.new(graph).execute(query: "huge", smart_context: nil)
    assert_includes output, "huge_symbol"
    assert_operator output.bytesize, :<=, Rubik::Tools::Truncator::DEFAULT_MAX_CHARS

    partial_path = write_file("partial_rel.rb", "class Known; end\n")
    partial_sym = Rubik::AST::Symbol.new(name: "Known", kind: :class, file: partial_path, line_start: 1, line_end: 1)
    partial_res = Rubik::AST::ExtractionResult.new(symbols: [partial_sym], status: :partial, source: :ruby)
    Rubik::AST::Extractor.stub(:extract_result, partial_res) do
      @graph.index_file(File.expand_path(partial_path))
    end

    Dir.chdir(@temp_dir) do
      assert_equal :partial, @graph.extraction_status("partial_rel.rb")
      outline = Rubik::Tools::GetOutlineTool.new(@graph).execute(file_path: "partial_rel.rb")
      assert_includes outline, "Partial extraction"
      @graph.remove_file("partial_rel.rb")
      assert_nil @graph.extraction_status("partial_rel.rb")
    end
  end

  def test_symbol_map_size_and_fuzzy_suggestions_use_symbol_names
    a = write_file("dup_a.rb", "def calculate_total; end\n")
    b = write_file("dup_b.rb", "def calculate_total; end\n")
    [a, b].each { |path| @graph.index_file(path) }

    assert_equal 2, @graph.symbols.size
    refute @graph.symbols.empty?

    miss = Rubik::Tools::SearchSymbolsTool.new(@graph).execute(query: "calculate_totl")
    assert miss.error?
    assert_includes miss, "calculate_total"

    sym_miss = Rubik::Tools::GetSymbolTool.new(@graph).execute(symbol_name: "calculate_totl")
    assert sym_miss.error?
    assert_includes sym_miss, "calculate_total"
  end

  private

  def write_file(name, content)
    path = File.join(@temp_dir, name)
    File.write(path, content)
    path
  end
end
