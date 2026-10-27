# frozen_string_literal: true

require_relative "../test_helper"

class TestDiagnosticsParser < Minitest::Test
  def test_parse_ruby_syntax_error
    stderr = "lib/foo.rb:12: syntax error, unexpected end-of-input"
    entries = Rubik::Diagnostics::Parser.parse(stderr, :ruby)

    assert_equal 1, entries.size
    e = entries.first
    assert_equal "lib/foo.rb", e.file
    assert_equal 12, e.line
    assert_equal :syntax, e.category
  end

  def test_parse_go_undefined_error
    stderr = "main.go:10:5: undefined: my_var"
    entries = Rubik::Diagnostics::Parser.parse(stderr, :go)

    assert_equal 1, entries.size
    e = entries.first
    assert_equal "main.go", e.file
    assert_equal 10, e.line
    assert_equal 5, e.col
    assert_equal :undefined_ref, e.category
  end

  def test_parse_rust_error
    stderr = "error[E0382]: use of moved value: `x` \n  --> src/main.rs:15:9"
    entries = Rubik::Diagnostics::Parser.parse(stderr, :rust)

    assert_equal 1, entries.size
    e = entries.first
    assert_equal "src/main.rs", e.file
    assert_equal 15, e.line
    assert_equal 9, e.col
    assert_equal "E0382", e.code
    assert_equal :type, e.category
  end

  def test_parse_cpp_error
    stderr = "main.cpp:10:5: error: use of undeclared identifier 'my_var'"
    entries = Rubik::Diagnostics::Parser.parse(stderr, :cpp)

    assert_equal 1, entries.size
    e = entries.first
    assert_equal "main.cpp", e.file
    assert_equal 10, e.line
    assert_equal 5, e.col
    assert_equal :undefined_ref, e.category
  end

  def test_parse_python_traceback
    stderr = "Traceback (most recent call last):\n  File \"app.py\", line 12, in <module>\n    print(x)\nNameError: name 'x' is not defined"
    entries = Rubik::Diagnostics::Parser.parse(stderr, :python)

    assert_equal 1, entries.size
    e = entries.first
    assert_equal "app.py", e.file
    assert_equal 12, e.line
    assert_equal "NameError: name 'x' is not defined", e.message
    assert_equal :type, e.category
  end

  def test_parse_python_indentation_error
    stderr = "  File \"app.py\", line 4\n    return x\nIndentationError: unexpected indent"
    entries = Rubik::Diagnostics::Parser.parse(stderr, :python)

    assert_equal 1, entries.size
    e = entries.first
    assert_equal "app.py", e.file
    assert_equal 4, e.line
    assert_equal "IndentationError: unexpected indent", e.message
    assert_equal :syntax, e.category
  end

  def test_parse_ts_js_tsc_error
    stderr = "src/app.ts(12,5): error TS2304: Cannot find name 'foo'."
    entries = Rubik::Diagnostics::Parser.parse(stderr, :typescript)

    assert_equal 1, entries.size
    e = entries.first
    assert_equal "src/app.ts", e.file
    assert_equal 12, e.line
    assert_equal 5, e.col
    assert_equal "TS2304", e.code
    assert_equal "Cannot find name 'foo'.", e.message
    assert_equal :syntax, e.category
  end

  def test_parse_ts_js_tsc_error_windows_path
    stderr = "C:\\src\\app.ts(12,5): error TS2304: Cannot find name 'foo'."
    entries = Rubik::Diagnostics::Parser.parse(stderr, :typescript)

    assert_equal 1, entries.size
    e = entries.first
    assert_equal "C:\\src\\app.ts", e.file
    assert_equal 12, e.line
    assert_equal 5, e.col
    assert_equal "TS2304", e.code
    assert_equal "Cannot find name 'foo'.", e.message
    assert_equal :syntax, e.category
  end

  def test_resilience_to_garbage_input
    garbage = "Random build failure system crash without file references\n"
    entries = Rubik::Diagnostics::Parser.parse(garbage, :c)

    refute_empty entries
    assert_equal :unknown, entries.first.category
  end
end
