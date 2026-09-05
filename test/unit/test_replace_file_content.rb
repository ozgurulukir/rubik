# frozen_string_literal: true

require_relative "../test_helper"

class TestReplaceFileContent < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_replace_test")
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @tool = Rubik::Tools::ReplaceFileContentTool.new(@buffer_manager)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  def test_single_unique_match_replacement
    code = <<~RUBY
      class Calculator
        def add(a, b)
          a - b
        end
      end
    RUBY
    @buffer_manager.write("calc.rb", code)

    res = @tool.execute(
      "path" => "calc.rb",
      "target_content" => "    a - b",
      "replacement_content" => "    a + b"
    )

    assert_includes res, "Successfully replaced content in in-memory buffer: calc.rb"
    updated = @buffer_manager.read("calc.rb")
    assert_includes updated, "    a + b"
    refute_includes updated, "    a - b"
    assert @buffer_manager.dirty?
  end

  def test_scoped_line_range_replacement
    code = <<~RUBY
      # Header
      val = 1
      # Section A
      val = 1
      # Section B
      val = 1
    RUBY
    @buffer_manager.write("data.rb", code)

    res = @tool.execute(
      "path" => "data.rb",
      "target_content" => "val = 1",
      "replacement_content" => "val = 42",
      "start_line" => 3,
      "end_line" => 5
    )

    assert_includes res, "Successfully replaced content in in-memory buffer: data.rb (scoped to lines 3..5)"
    updated = @buffer_manager.read("data.rb")
    lines = updated.lines
    assert_equal "val = 1\n", lines[1]
    assert_equal "val = 42\n", lines[3]
    assert_equal "val = 1\n", lines[5]
  end

  def test_ambiguous_target_fails_when_allow_multiple_is_false
    code = <<~RUBY
      def first
        return true
      end

      def second
        return true
      end
    RUBY
    @buffer_manager.write("methods.rb", code)

    res = @tool.execute(
      "path" => "methods.rb",
      "target_content" => "  return true",
      "replacement_content" => "  return false"
    )

    assert_includes res, "-- TARGET CONTENT NOT UNIQUE --"
    assert_includes res, "found 2 times in `methods.rb`"
    assert_includes res, "allow_multiple: true"
    # Ensure buffer is not touched
    assert_equal code, @buffer_manager.read("methods.rb")
  end

  def test_allow_multiple_replaces_all_occurrences
    code = <<~RUBY
      val = 10
      other = 10
    RUBY
    @buffer_manager.write("vars.rb", code)

    res = @tool.execute(
      "path" => "vars.rb",
      "target_content" => "10",
      "replacement_content" => "20",
      "allow_multiple" => true
    )

    assert_includes res, "Successfully replaced content"
    updated = @buffer_manager.read("vars.rb")
    assert_equal "val = 20\nother = 20\n", updated
  end

  def test_target_not_found_returns_closest_snippet_elm_diagnostic
    code = <<~RUBY
      def calculate_summary(items)
        items.sum(&:amount)
      end
    RUBY
    @buffer_manager.write("summary.rb", code)

    res = @tool.execute(
      "path" => "summary.rb",
      "target_content" => "def calculate_sum(items)\n  items.sum(&:amount)\nend",
      "replacement_content" => "def calculate_sum(items)\n  0\nend"
    )

    assert_includes res, "-- TARGET CONTENT NOT FOUND --"
    assert_includes res, "Closest matching snippet found"
    assert_includes res, "calculate_summary"
    assert_includes res, "read_file(path: 'summary.rb'"
  end

  def test_file_not_found_elm_diagnostic
    res = @tool.execute(
      "path" => "nonexistent.rb",
      "target_content" => "foo",
      "replacement_content" => "bar"
    )

    assert_includes res, "-- FILE NOT FOUND --"
    assert_includes res, "I cannot find the file `nonexistent.rb`"
  end

  def test_crlf_lf_newline_normalization
    code = "def foo\r\n  1\r\nend\r\n"
    @buffer_manager.write("windows.rb", code)

    res = @tool.execute(
      "path" => "windows.rb",
      "target_content" => "def foo\n  1\nend",
      "replacement_content" => "def foo\n  2\nend"
    )

    assert_includes res, "Successfully replaced content in in-memory buffer: windows.rb"
    updated = @buffer_manager.read("windows.rb")
    assert_includes updated, "def foo\n  2\nend"
  end

  def test_replacement_with_backslashes_preserved_verbatim
    code = <<~GO
      func cleanPath(p string) string {
        return strings.ReplaceAll(p, "/", "-")
      }
    GO
    @buffer_manager.write("store.go", code)

    res = @tool.execute(
      "path" => "store.go",
      "target_content" => 'strings.ReplaceAll(p, "/", "-")',
      "replacement_content" => 'strings.ReplaceAll(p, "\\\\", "/")'
    )

    assert_includes res, "Successfully replaced content in in-memory buffer: store.go"
    updated = @buffer_manager.read("store.go")
    assert_includes updated, 'strings.ReplaceAll(p, "\\\\", "/")'
    refute_includes updated, 'strings.ReplaceAll(p, "\\", "/")'
  end

  def test_replacement_with_single_quote_backreference_does_not_duplicate_file_tail
    code = <<~GO
      package main
      func Step1() {
        println("step 1")
      }
      func Step2() {
        replace_me()
      }
      func Step3() {
        println("step 3 tail of file")
      }
    GO
    @buffer_manager.write("main.go", code)

    # In unpatched String#sub, "\\'" expands to the entire post-match string, duplicating Step3!
    rep_content = "res = replace(path, '\\', '/')"
    res = @tool.execute(
      "path" => "main.go",
      "target_content" => "replace_me()",
      "replacement_content" => rep_content
    )

    assert_includes res, "Successfully replaced content in in-memory buffer: main.go"
    updated = @buffer_manager.read("main.go")
    assert_includes updated, rep_content
    # Ensure Step3 only appears once in the entire file, not duplicated!
    assert_equal 1, updated.scan("Step3").size
    assert_equal 1, updated.scan("step 3 tail of file").size
  end

  def test_scoped_replacement_with_backreferences_preserved_verbatim
    code = <<~TEXT
      line 1
      TARGET_TO_REPLACE
      line 3
    TEXT
    @buffer_manager.write("sample.txt", code)

    # Test \\&, \\`, \\', \\1 in scoped replace
    rep_content = "FOO \\& \\' \\` \\1 BAR"
    res = @tool.execute(
      "path" => "sample.txt",
      "target_content" => "TARGET_TO_REPLACE",
      "replacement_content" => rep_content,
      "start_line" => 1,
      "end_line" => 3
    )

    assert_includes res, "Successfully replaced content in in-memory buffer: sample.txt"
    updated = @buffer_manager.read("sample.txt")
    assert_includes updated, rep_content
    assert_equal 3, updated.lines.size
  end
end
