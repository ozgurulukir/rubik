# frozen_string_literal: true

require_relative "../test_helper"

class TestUIFrame < Minitest::Test
  def theme
    Rubik::UI::Theme.new(enabled: false)
  end

  def test_draw_produces_uniform_width_lines
    frame = Rubik::UI::Frame.draw(["short", "a much longer content line"], theme: theme, width: 40, title: "rubik")
    widths = frame.lines.map { |l| l.chomp.length }
    assert_equal 4, widths.size # top + 2 content + bottom
    assert widths.uniq.one?, "all frame lines must share one width, got #{widths.inspect}"
  end

  def test_draw_keeps_uniform_width_when_content_overflows
    long = "x" * 200
    frame = Rubik::UI::Frame.draw([long], theme: theme, width: 40)
    widths = frame.lines.map { |l| l.chomp.length }
    assert widths.uniq.one?, "truncation must not break uniform frame width, got #{widths.inspect}"
    assert_includes frame.lines[1].chomp, "…"
  end

  def test_ascii_theme_truncates_with_ascii_ellipsis
    ascii_theme = Rubik::UI::Theme.new(enabled: false, glyph_set: :ascii)
    frame = Rubik::UI::Frame.draw(["y" * 200], theme: ascii_theme, width: 40)
    refute_includes frame, "…"
    assert_includes frame, "..."
    widths = frame.lines.map { |l| l.chomp.length }
    assert widths.uniq.one?
  end

  def test_display_width_counts_wide_glyphs_as_two_columns
    assert_equal 1, Rubik::UI::Frame.display_width("a")
    assert_equal 2, Rubik::UI::Frame.display_width("🎲")
    assert_equal 8, Rubik::UI::Frame.display_width("🎲 Rubik") # emoji + space + 5 letters
  end

  def test_draw_keeps_uniform_width_with_emoji_content
    frame = Rubik::UI::Frame.draw(["🎲 Rubik v0.1.0", "plain"], theme: theme, width: 40, title: "rubik")
    widths = frame.lines.map { |l| Rubik::UI::Frame.display_width(l.chomp) }
    assert widths.uniq.one?, "emoji row must not drift the right rail, got #{widths.inspect}"
  end

  def test_top_and_bottom_border_widths_match
    top = Rubik::UI::Frame.top_border(theme, width: 32, title: "x")
    bottom = Rubik::UI::Frame.bottom_border(theme, width: 32)
    assert_equal bottom.length, top.length
  end

  def test_ascii_glyph_set_draws_ascii_frame
    ascii_theme = Rubik::UI::Theme.new(enabled: false, glyph_set: :ascii)
    frame = Rubik::UI::Frame.draw(["x"], theme: ascii_theme, width: 20)
    assert_includes frame, "+"
    refute_includes frame, "╭"
  end

  def test_empty_draw_returns_empty_string
    assert_equal "", Rubik::UI::Frame.draw([], theme: theme)
  end
end
