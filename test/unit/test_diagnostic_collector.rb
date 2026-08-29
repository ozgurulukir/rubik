# frozen_string_literal: true

require_relative "../test_helper"

class TestDiagnosticCollector < Minitest::Test
  def setup
    @collector = Rubik::Diagnostics::Collector.new(root_dir: Dir.pwd)
  end

  def test_add_and_deduplicate_entries
    entry1 = Rubik::Diagnostics::Entry.new(file: "app.rb", line: 10, col: 2, severity: :error, message: "undefined local variable 'foo'")
    entry2 = Rubik::Diagnostics::Entry.new(file: "app.rb", line: 10, col: 2, severity: :error, message: "undefined local variable 'foo'")
    entry3 = Rubik::Diagnostics::Entry.new(file: "app.rb", line: 20, col: 5, severity: :warning, message: "unused variable 'bar'")

    @collector.add_entry(entry1)
    @collector.add_entry(entry2)
    @collector.add_entry(entry3)

    assert_equal 2, @collector.count
    assert_equal 1, @collector.error_count
    assert_equal 1, @collector.warning_count
    refute @collector.empty?
  end

  def test_priority_sorting_errors_before_warnings
    entry_warn = Rubik::Diagnostics::Entry.new(file: "b.rb", line: 1, severity: :warning, message: "lint warning")
    entry_err = Rubik::Diagnostics::Entry.new(file: "a.rb", line: 5, severity: :error, message: "syntax error")

    @collector.add_entry(entry_warn)
    @collector.add_entry(entry_err)

    sorted = @collector.entries
    assert_equal :error, sorted.first.severity
    assert_equal :warning, sorted.last.severity
  end

  def test_add_lsp_diagnostics_normalization
    raw_lsp = [
      {
        "range" => { "start" => { "line" => 14, "character" => 3 }, "end" => { "line" => 14, "character" => 10 } },
        "severity" => 1,
        "message" => "Type mismatch: expected String, got Integer",
        "code" => "E0308"
      },
      {
        "range" => { "start" => { "line" => 25, "character" => 1 }, "end" => { "line" => 25, "character" => 5 } },
        "severity" => 2,
        "message" => "Variable 'x' is never read",
        "code" => "unused"
      }
    ]

    @collector.add_lsp_diagnostics("lib/calc.rb", raw_lsp)

    assert_equal 2, @collector.count
    assert_equal 1, @collector.error_count
    assert_equal 1, @collector.warning_count

    first_err = @collector.errors.first
    assert_equal 15, first_err.line # 1-based
    assert_equal 4, first_err.col
    assert_equal "Type mismatch: expected String, got Integer", first_err.message
  end

  def test_add_parsed_compiler_output
    compiler_out = "lib/main.rb:12: syntax error, unexpected end-of-input"
    @collector.add_parsed(compiler_out, lang: :ruby)

    assert_equal 1, @collector.count
    err = @collector.entries.first
    assert_equal "lib/main.rb", err.file
    assert_equal 12, err.line
    assert_includes err.message, "syntax error"
  end

  def test_format_for_context_xml
    entry = Rubik::Diagnostics::Entry.new(file: "lib/auth.rb", line: 42, col: 8, severity: :error, category: :syntax, message: "unexpected token '<'")
    @collector.add_entry(entry)

    xml = @collector.format_for_context
    assert_includes xml, "<diagnostics>"
    assert_includes xml, 'file="lib/auth.rb"'
    assert_includes xml, 'line="42"'
    assert_includes xml, 'severity="error"'
    assert_includes xml, 'category="syntax"'
    assert_includes xml, "unexpected token '&lt;'"
    assert_includes xml, "</diagnostics>"
  end

  def test_format_for_terminal
    entry = Rubik::Diagnostics::Entry.new(file: "lib/auth.rb", line: 42, col: 8, severity: :error, category: :syntax, message: "unexpected token")
    @collector.add_entry(entry)

    term = @collector.format_for_terminal
    assert_includes term, "Diagnostic Fusion Summary (1 error(s), 0 warning(s)):"
    assert_includes term, "❌ [ERROR] lib/auth.rb:42:8 - unexpected token (syntax)"
  end
end
