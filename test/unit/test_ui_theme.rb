# frozen_string_literal: true

require_relative "../test_helper"
require_relative "test_ui_capability"

class TestUITheme < Minitest::Test
  def plain_theme
    Rubik::UI::Theme.new(enabled: false)
  end

  def color_theme
    Rubik::UI::Theme.new(enabled: true)
  end

  def test_disabled_theme_returns_plain_text
    assert_equal "hello", plain_theme.paint("hello", :accent)
    assert_equal "hello", plain_theme.paint("hello", :error)
  end

  def test_enabled_theme_adds_ansi
    painted = color_theme.paint("hello", :error)
    assert_includes painted, "\e["
    assert_includes painted, "hello"
  end

  def test_unknown_style_returns_plain
    assert_equal "hello", color_theme.paint("hello", :does_not_exist)
  end

  def test_unicode_and_ascii_glyph_sets
    unicode = Rubik::UI::Theme.new(enabled: false, glyph_set: :unicode)
    assert_equal "⏺", unicode.glyph(:action)
    assert_equal "⎿", unicode.glyph(:branch)

    ascii = Rubik::UI::Theme.new(enabled: false, glyph_set: :ascii)
    assert_equal "*", ascii.glyph(:action)
    assert_equal "`", ascii.glyph(:branch)
  end

  def test_unknown_glyph_set_falls_back_to_unicode
    theme = Rubik::UI::Theme.new(enabled: false, glyph_set: :martian)
    assert_equal "⏺", theme.glyph(:action)
  end

  def test_default_spinner_verbs_present_and_custom_override
    assert Rubik::UI::Theme::DEFAULT_SPINNER_VERBS.include?("Düşünüyor")

    custom = Rubik::UI::Theme.new(enabled: false, spinner_verbs: ["Küpüyor"])
    assert_equal ["Küpüyor"], custom.spinner_verbs

    empty = Rubik::UI::Theme.new(enabled: false, spinner_verbs: nil)
    assert_equal Rubik::UI::Theme::DEFAULT_SPINNER_VERBS.size, empty.spinner_verbs.size
  end
end
