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

  def test_resilience_to_garbage_input
    garbage = "Random build failure system crash without file references\n"
    entries = Rubik::Diagnostics::Parser.parse(garbage, :c)

    refute_empty entries
    assert_equal :unknown, entries.first.category
  end
end
