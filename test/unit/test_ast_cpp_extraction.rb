# frozen_string_literal: true

require_relative "../test_helper"

# Issue #147: C++ extraction (Tree-Sitter) and extraction-status visibility.
# Fixture scope per the CWalker contract: classes/structs/unions, in-class
# member definitions AND declarations (Class#method), namespaces (ns::name),
# out-of-line definitions, constructors/destructors/operators, unwrapped
# templates, and brace traps inside comments/strings. Out of scope (also
# documented at CWalker): macro bodies, free-function prototypes outside a
# class, local classes inside function bodies.
class TestASTCPPExtraction < Minitest::Test
  def setup
    @graph = Rubik::AST::Graph.new
    Rubik::AST::TreeSitterExtractor.clear_parsers!
  end

  def extract(code, file = "sample.cpp")
    Rubik::AST::Extractor.extract_result(file, code)
  end

  def names(result)
    result.symbols.map(&:name)
  end

  def test_issue_example_class_and_method_are_extracted
    code = <<~CPP
      class Widget { public: void run() { helper(); } };
      int main() { Widget w; w.run(); }
    CPP

    result = extract(code)
    assert_equal :ok, result.status
    assert_equal :tree_sitter, result.source
    assert_includes names(result), "Widget"
    assert_includes names(result), "Widget#run"
    assert_includes names(result), "main"

    widget = result.symbols.find { |s| s.name == "Widget" }
    assert_equal :class, widget.kind

    run_sym = result.symbols.find { |s| s.name == "Widget#run" }
    assert_equal :function, run_sym.kind
    assert_includes run_sym.calls, "helper", "the method's helper call must be preserved"

    main_sym = result.symbols.find { |s| s.name == "main" }
    assert_includes main_sym.calls, "w.run"
  end

  def test_namespace_and_scoped_method_qualification
    code = <<~CPP
      namespace app {
        void run() {}
        class W { void m(); void n() { m(); } };
      }
      void W::outofline() {}
    CPP

    result = extract(code)
    names_ = names(result)
    assert_includes names_, "app::run"
    assert_includes names_, "app::W"
    assert_includes names_, "app::W#m"
    assert_includes names_, "app::W#n"
    assert_includes names_, "W::outofline"
    assert_includes result.symbols.find { |s| s.name == "app::W#n" }.calls, "m"
  end

  def test_constructors_destructors_and_operators
    code = <<~CPP
      class C {
        C();
        ~C();
        void m();
        int x;
        void operator+(int v);
        operator bool() const;
      };
    CPP

    result = extract(code)
    names_ = names(result)
    assert_includes names_, "C#C"
    assert_includes names_, "C#~C"
    assert_includes names_, "C#m"
    assert_includes names_, "C#operator+"
    assert_includes names_, "C#operator bool"
    refute_includes names_, "C#x", "plain field declarations are not symbols"
  end

  def test_templates_are_unwrapped
    code = <<~CPP
      template <typename T> class Box { T get() { return value; } };
      template <typename T> T id(T x) { return x; }
    CPP

    result = extract(code)
    names_ = names(result)
    assert_includes names_, "Box"
    assert_includes names_, "Box#get"
    assert_includes names_, "id"
  end

  def test_braces_in_comments_and_strings_are_not_symbols
    code = <<~CPP
      // class Fake { void nope(); };
      /* struct AlsoFake { void nope2(); }; */
      const char* s = "void fake() { }";
      class Real { void ok(); };
    CPP

    result = extract(code)
    names_ = names(result)
    assert_includes names_, "Real"
    assert_includes names_, "Real#ok"
    refute_includes names_, "Fake"
    refute_includes names_, "AlsoFake"
  end

  def test_struct_specifier_with_methods
    code = "struct Point { int x; void move(); };\n"
    result = extract(code)
    names_ = names(result)
    assert_includes names_, "Point"
    assert_includes names_, "Point#move"
    assert_equal :struct, result.symbols.find { |s| s.name == "Point" }.kind
  end

  def test_c_extraction_is_not_regressed
    code = <<~C
      #include <stdio.h>
      typedef struct Point { int x; } Point;
      int main(void) { printf("hi"); return 0; }
    C

    result = extract(code, "sample.c")
    assert_equal :ok, result.status
    names_ = names(result)
    assert_includes names_, "Point"
    assert_includes names_, "main"
    assert_includes names_, "#include <stdio.h>"
    assert_includes result.symbols.find { |s| s.name == "main" }.calls, "printf"
  end

  # ── parse status: empty ≠ failed ≠ unsupported ───────────────────────

  def test_parse_error_is_failed_not_empty
    result = extract("class {{{ ;\n")
    assert_equal :failed, result.status
    assert_empty result.symbols
    refute_nil result.detail
  end

  def test_legitimately_empty_file_is_ok
    result = extract("", "empty.cpp")
    assert_equal :ok, result.status
    assert_empty result.symbols
  end

  def test_unknown_extension_is_unavailable_but_keeps_legacy_fallback
    result = Rubik::AST::Extractor.extract_result("script.unknown", "class DefaultFallback; end")
    assert_equal :unavailable, result.status
    assert_includes names(result), "DefaultFallback"
  end

  def test_partial_parse_reports_symbols_with_partial_status
    result = extract("int good() { return 1; }\nint broken( {\n")
    assert_equal :partial, result.status
    assert_equal :tree_sitter, result.source
    assert_includes names(result), "good"
  end

  # ── graph: a failed extraction must not silently empty the index ─────

  def test_failed_reindex_keeps_previously_indexed_symbols_and_warns
    good = "class Widget { public: void run() { helper(); } };\nint main() { Widget w; w.run(); }\n"
    @graph.index_file("sample.cpp", good)
    assert_equal :ok, @graph.extraction_status("sample.cpp")
    kept = @graph.file_symbols["sample.cpp"].map(&:name)
    assert_equal ["Widget", "Widget#run", "main"], kept

    _out, err = capture_io { @graph.index_file("sample.cpp", "class {{{ ;\n") }
    assert_equal :failed, @graph.extraction_status("sample.cpp")
    assert_equal kept, @graph.file_symbols["sample.cpp"].map(&:name),
                 "valid symbols must not be silently deleted by a failed extraction"
    assert_includes err, "keeping previously indexed symbols"
  end

  def test_broken_new_file_is_failed_not_a_successful_empty_index
    _out, err = capture_io { @graph.index_file("broken.cpp", "class {{{ ;\n") }
    assert_equal :failed, @graph.extraction_status("broken.cpp")
    assert_empty @graph.file_symbols["broken.cpp"]
    assert_includes err, "indexing 0 best-effort fallback symbols"
  end

  def test_remove_file_clears_extraction_status
    @graph.index_file("empty.cpp", "")
    assert_equal :ok, @graph.extraction_status("empty.cpp")
    @graph.remove_file("empty.cpp")
    assert_nil @graph.extraction_status("empty.cpp")
  end

  def test_extract_array_seam_still_returns_symbols
    symbols = Rubik::AST::Extractor.extract("sample.cpp", "class Widget { void run(); };\n")
    assert_includes symbols.map(&:name), "Widget#run"
  end
end
