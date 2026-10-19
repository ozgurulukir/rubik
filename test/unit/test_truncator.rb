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

  def test_custom_separator_preserves_line_count_and_untruncated_pass_through
    # Truncated when line count exceeds max_lines
    res = Rubik::Tools::Truncator.truncate("a|b|c", max_chars: 100, max_lines: 2, strategy: :head_only, separator: "|")
    assert res[:truncated]
    assert_equal 1, res[:omitted_lines]
    assert_includes res[:text], "a|"

    # Untruncated when within limits with custom separator (verifies bypass bug fix)
    pass_res = Rubik::Tools::Truncator.truncate("a|b", max_chars: 100, max_lines: 5, separator: "|")
    assert_equal "a|b", pass_res[:text]
    refute pass_res[:truncated]
    assert_equal 0, pass_res[:omitted_lines]
    assert_equal 0, pass_res[:omitted_chars]
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

  def test_head_tail_preserves_large_budgets_without_clamp
    text = (1..600).map { |i| "line #{i}\n" }.join
    res = Rubik::Tools::Truncator.truncate(text, max_chars: 50_000, max_lines: 500, strategy: :head_tail)

    assert res[:truncated]
    assert_equal 100, res[:omitted_lines]
    assert_includes res[:text], "line 1\n"
    assert_includes res[:text], "line 250\n"
    assert_includes res[:text], "line 600\n"
    refute_includes res[:text], "line 300\n"
  end

  def test_head_tail_handles_small_line_budget
    text = "line 1\nline 2\nline 3\n"
    res1 = Rubik::Tools::Truncator.truncate(text, max_chars: 100, max_lines: 1, strategy: :head_tail)
    assert res1[:truncated]
    assert_equal 2, res1[:omitted_lines]
    assert_includes res1[:text], "line 1\n"
    refute_includes res1[:text], "line 2\n"
    refute_includes res1[:text], "line 3\n"

    res0 = Rubik::Tools::Truncator.truncate(text, max_chars: 100, max_lines: 0, strategy: :head_tail)
    assert res0[:truncated]
    assert_equal 3, res0[:omitted_lines]
    refute_includes res0[:text], "line 1\n"
  end

  def test_head_tail_prevents_line_duplication_when_few_long_lines
    line1 = "FIRST_LINE_START_#{'a' * 2000}\n"
    line2 = "MIDDLE_LINE_#{'b' * 2000}\n"
    line3 = "#{'c' * 2000}_END_OF_LAST_LINE\n"
    text = "#{line1}#{line2}#{line3}"

    res = Rubik::Tools::Truncator.truncate(text, max_chars: 3000, max_lines: 10, strategy: :head_tail)
    assert res[:truncated]
    assert_includes res[:text], "FIRST_LINE_START_"
    assert_includes res[:text], "_END_OF_LAST_LINE"
    # line 1 is in head, line 3 is in tail; neither should be duplicated
    assert_equal 1, res[:text].scan("FIRST_LINE_START_").size
    assert_equal 1, res[:text].scan("_END_OF_LAST_LINE").size
    refute_includes res[:text], "MIDDLE_LINE_"
  end

  def test_omitted_lines_accurately_reflects_byte_sliced_dropped_lines
    # 5 lines of exactly 100 chars each = 500 chars. max_lines: 10 allows all 5 lines.
    # But max_chars: 200 cuts off after 2 lines in head_only and tail_only.
    lines = (1..5).map { |i| "Line #{i}: #{'x' * 91}\n" }.join
    res_head = Rubik::Tools::Truncator.truncate(lines, max_chars: 200, max_lines: 10, strategy: :head_only)
    assert res_head[:truncated]
    # Kept: Line 1 and Line 2 -> 3 lines omitted
    assert_equal 3, res_head[:omitted_lines]
    assert_includes res_head[:text], "omitted 3 lines"

    res_tail = Rubik::Tools::Truncator.truncate(lines, max_chars: 200, max_lines: 10, strategy: :tail_only)
    assert res_tail[:truncated]
    assert_equal 3, res_tail[:omitted_lines]
    assert_includes res_tail[:text], "omitted 3 lines"

    # head_tail with max_chars: 200 (100 head, 100 tail)
    # Head keeps Line 1 (100 chars), Tail keeps Line 5 (100 chars) -> 3 lines omitted
    res_ht = Rubik::Tools::Truncator.truncate(lines, max_chars: 200, max_lines: 10, strategy: :head_tail)
    assert res_ht[:truncated]
    assert_equal 3, res_ht[:omitted_lines]
    assert_includes res_ht[:text], "3 lines"
  end
end
