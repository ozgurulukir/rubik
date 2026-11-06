# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/orchestrator/subagent/paging"

class TestSubagentPaging < Minitest::Test
  Paging = Rubik::Orchestrator::Subagent::Paging

  def test_window_standard_paging
    text = "0123456789"
    win = Paging.window(text, cursor: 2, limit: 4, default: 5, max: 10)

    assert_instance_of Paging::Window, win
    assert win.frozen?
    assert_equal 2, win.cursor
    assert_equal "2345", win.body
    assert_equal 6, win.next_cursor
    assert win.has_more
    assert win.has_more?
    assert_equal 10, win.total_chars
    assert_equal 4, win.returned_chars
  end

  def test_window_reaches_end
    text = "0123456789"
    win = Paging.window(text, cursor: 6, limit: 4, default: 5, max: 10)

    assert_equal 6, win.cursor
    assert_equal "6789", win.body
    assert_nil win.next_cursor
    refute win.has_more
    refute win.has_more?
    assert_equal 10, win.total_chars
    assert_equal 4, win.returned_chars
  end

  def test_window_clamps_negative_cursor_to_zero
    text = "hello world"
    win = Paging.window(text, cursor: -5, limit: 5, default: 5, max: 20)

    assert_equal 0, win.cursor
    assert_equal "hello", win.body
    assert_equal 5, win.next_cursor
    assert win.has_more
  end

  def test_window_cursor_equal_to_total_returns_empty_page
    text = "hello"
    win = Paging.window(text, cursor: 5, limit: 10, default: 5, max: 20)

    assert_equal 5, win.cursor
    assert_equal "", win.body
    assert_nil win.next_cursor
    refute win.has_more
    assert_equal 5, win.total_chars
    assert_equal 0, win.returned_chars
  end

  def test_window_cursor_exceeding_total_returns_nil
    text = "hello"
    win = Paging.window(text, cursor: 6, limit: 10, default: 5, max: 20)

    assert_nil win
  end

  def test_window_falls_back_to_default_when_limit_zero_or_negative
    text = "0123456789"
    win_zero = Paging.window(text, cursor: 0, limit: 0, default: 3, max: 10)
    assert_equal "012", win_zero.body

    win_neg = Paging.window(text, cursor: 0, limit: -5, default: 4, max: 10)
    assert_equal "0123", win_neg.body
  end

  def test_window_clamps_limit_to_max
    text = "0123456789abcdef"
    win = Paging.window(text, cursor: 0, limit: 100, default: 5, max: 8)

    assert_equal 8, win.returned_chars
    assert_equal "01234567", win.body
    assert_equal 8, win.next_cursor
    assert win.has_more
  end
end
