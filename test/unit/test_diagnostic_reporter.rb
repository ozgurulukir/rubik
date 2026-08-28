# frozen_string_literal: true

require_relative "../test_helper"

class TestDiagnosticReporter < Minitest::Test
  def test_render_file_not_found_elm_style
    rendered = Rubik::Tools::DiagnosticReporter.render_file_not_found(
      "lib/rubik/tool/files.rb",
      candidates: ["lib/rubik/tools/files.rb"],
      existing_dir_files: ["lib/rubik/tools/base.rb", "lib/rubik/tools/files.rb"]
    )

    assert_includes rendered, "-- FILE NOT FOUND --"
    assert_includes rendered, "I cannot find the file `lib/rubik/tool/files.rb` in the project workspace."
    assert_includes rendered, "Did you mean this?"
    assert_includes rendered, "• lib/rubik/tools/files.rb"
    assert_includes rendered, "Actionable Next Steps:"
    assert_includes rendered, "call `read_file(path: 'lib/rubik/tools/files.rb')`"
    assert_includes rendered, "call `write_file(path: 'lib/rubik/tool/files.rb'"
  end

  def test_render_target_not_found_elm_style
    rendered = Rubik::Tools::DiagnosticReporter.render_target_not_found(
      "lib/app.rb",
      "def foo\n  1\nend",
      closest_snippet: "def foo_bar\n  1\nend",
      closest_range: 10..12,
      similarity: 85,
      start_line: 5,
      end_line: 20
    )

    assert_includes rendered, "-- TARGET CONTENT NOT FOUND --"
    assert_includes rendered, "I could not find the exact `target_content` in `lib/app.rb` within lines 5..20."
    assert_includes rendered, "Closest matching snippet found at lines 10..12 (85% similarity):"
    assert_includes rendered, "def foo_bar"
    assert_includes rendered, "Actionable Next Steps:"
    assert_includes rendered, "read_file(path: 'lib/app.rb', offset:"
  end

  def test_render_target_not_unique_elm_style
    rendered = Rubik::Tools::DiagnosticReporter.render_target_not_unique(
      "lib/config.rb",
      "end",
      3,
      [12, 45, 88]
    )

    assert_includes rendered, "-- TARGET CONTENT NOT UNIQUE --"
    assert_includes rendered, "found 3 times in `lib/config.rb` at lines: 12, 45, 88."
    assert_includes rendered, "Actionable Next Steps:"
    assert_includes rendered, "Provide more surrounding context lines"
    assert_includes rendered, "start_line: 10, end_line: 15"
    assert_includes rendered, "allow_multiple: true"
  end

  def test_render_unknown_tool_with_synthesis_tip
    rendered = Rubik::Tools::DiagnosticReporter.render_unknown_tool(
      "view_file",
      candidate_tools: ["read_file"],
      all_tools: %w[read_file write_file list_files]
    )

    assert_includes rendered, "-- UNKNOWN TOOL --"
    assert_includes rendered, "I cannot find an active tool named `view_file`."
    assert_includes rendered, "Did you mean one of these?"
    assert_includes rendered, "• read_file"
    assert_includes rendered, "💡 Need a specialized capability?"
    assert_includes rendered, "synthesize_tool(name: 'view_file'"
  end

  def test_render_symbol_not_found_elm_style
    rendered = Rubik::Tools::DiagnosticReporter.render_symbol_not_found(
      "UserMode",
      candidate_symbols: ["UserModel", "UserNode"]
    )

    assert_includes rendered, "-- SYMBOL NOT FOUND --"
    assert_includes rendered, "I could not find the symbol `UserMode` in the AST semantic graph."
    assert_includes rendered, "• UserModel"
    assert_includes rendered, "Actionable Next Steps:"
    assert_includes rendered, "search_symbols(query: 'UserM')"
  end

  def test_render_command_failed_elm_style
    rendered = Rubik::Tools::DiagnosticReporter.render_command_failed(
      "bundle exec rspec",
      1,
      "rspec: command not found",
      suggestions: ["Run bundle install", "Check Gemfile"]
    )

    assert_includes rendered, "-- COMMAND EXECUTION FAILED --"
    assert_includes rendered, "Command `bundle exec rspec` failed with exit code 1."
    assert_includes rendered, "rspec: command not found"
    assert_includes rendered, "1. Run bundle install"
  end
end
