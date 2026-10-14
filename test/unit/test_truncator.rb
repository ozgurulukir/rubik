# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/tools/truncator"

class TestTruncator < Minitest::Test
  def test_untruncated_short_text_passes_through_unchanged
    text = "Hello world\nThis is a short output\nLine 3\n"
    res = Rubik::Tools::Truncator.truncate(text, max_chars: 1000, max_lines: 50)

    assert_equal text, res[:text]
    refute res[:truncated]
    assert_equal 0, res[:omitted_lines]
    assert_equal 0, res[:omitted_chars]
  end

  def test_empty_string_untruncated
    res = Rubik::Tools::Truncator.truncate("", max_chars: 10, max_lines: 5)

    assert_equal "", res[:text]
    refute res[:truncated]
    assert_equal 0, res[:omitted_lines]
    assert_equal 0, res[:omitted_chars]
  end

  def test_text_without_trailing_newline_untruncated
    text = "line1\nline2\nline3"
    res = Rubik::Tools::Truncator.truncate(text, max_chars: 100, max_lines: 3)

    assert_equal text, res[:text]
    refute res[:truncated]
    assert_equal 0, res[:omitted_lines]
  end

  def test_text_exceeding_max_lines_triggers_truncation
    lines = (1..10).map { |i| "Line #{i}\n" }.join
    res = Rubik::Tools::Truncator.truncate(lines, max_chars: 1000, max_lines: 4, strategy: :head_tail)

    assert res[:truncated]
    assert_equal 6, res[:omitted_lines]
    assert_includes res[:text], "Line 1\n"
    assert_includes res[:text], "Line 10\n"
    assert_includes res[:text], "[Truncated: 6 lines"
  end

  def test_text_exceeding_max_chars_triggers_truncation
    text = "a" * 500
    res = Rubik::Tools::Truncator.truncate(text, max_chars: 100, max_lines: 50, strategy: :head_only)

    assert res[:truncated]
    assert_equal 400, res[:omitted_chars]
    assert_includes res[:text], "[Truncated: omitted 0 lines / 400 chars]"
  end

  def test_head_only_and_tail_only_strategies
    text = "line1\nline2\nline3\nline4\nline5\n"

    head_res = Rubik::Tools::Truncator.truncate(text, max_chars: 1000, max_lines: 2, strategy: :head_only)
    assert head_res[:truncated]
    assert_includes head_res[:text], "line1\n"
    refute_includes head_res[:text], "line5\n"

    tail_res = Rubik::Tools::Truncator.truncate(text, max_chars: 1000, max_lines: 2, strategy: :tail_only)
    assert tail_res[:truncated]
    assert_includes tail_res[:text], "line5\n"
    refute_includes tail_res[:text], "line1\n"
  end

  def test_crlf_line_endings
    crlf_text = "line1\r\nline2\r\nline3\r\n"
    res = Rubik::Tools::Truncator.truncate(crlf_text, max_chars: 100, max_lines: 3)

    assert_equal crlf_text, res[:text]
    refute res[:truncated]
  end

  def test_multibyte_utf8_handling
    multibyte = "#{'🔥' * 50}\n"
    res = Rubik::Tools::Truncator.truncate(multibyte, max_chars: 200, max_lines: 5)

    assert res[:text].valid_encoding?
  end
end
