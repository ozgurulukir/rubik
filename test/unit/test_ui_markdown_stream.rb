# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestUIMarkdownStream < Minitest::Test
  def plain_theme
    Rubik::UI::Theme.new(enabled: false)
  end

  def color_theme
    Rubik::UI::Theme.new(enabled: true)
  end

  def collect_segments(stream, deltas)
    segments = []
    deltas.each { |d| stream.push(d) { |seg| segments << seg } }
    stream.finish { |seg| segments << seg }
    segments
  end

  def test_disabled_mode_passes_bytes_verbatim
    stream = Rubik::UI::MarkdownStream.new(plain_theme, enabled: true)
    segments = collect_segments(stream, ["**bold** ", "line\n", "tail"])
    refute_includes segments.join, "\e["
    assert_equal "**bold** line\ntail\n", segments.join
  end

  def test_enabled_mode_styles_bold_and_inline_code
    stream = Rubik::UI::MarkdownStream.new(color_theme, enabled: true)
    segments = collect_segments(stream, ["**bold** and `code`\n"])
    joined = segments.join
    assert_includes joined, "\e[" # ANSI styling applied
    assert_includes joined, "bold"
    assert_includes joined, "`code`"
  end

  def test_heading_rendered_bold
    stream = Rubik::UI::MarkdownStream.new(color_theme, enabled: true)
    segments = collect_segments(stream, ["## Title\n"])
    assert_includes segments.join, "## Title"
    assert_includes segments.join, "\e[" # bold style
  end

  def test_fence_toggle_prefixes_rail_inside_code_blocks
    stream = Rubik::UI::MarkdownStream.new(color_theme, enabled: true)
    segments = collect_segments(stream, ["```ruby\n", "puts 1\n", "```\n"])
    plain = Rubik::UI::Capability.strip_ansi(segments.join)
    assert_includes plain, "│ puts 1"
    assert_includes plain, "```ruby"
  end

  def test_finish_flushes_pending_tail_with_newline
    stream = Rubik::UI::MarkdownStream.new(plain_theme, enabled: true)
    segments = collect_segments(stream, ["abc"])
    assert_equal ["abc\n"], segments
  end

  def test_finish_without_pending_emits_nothing
    stream = Rubik::UI::MarkdownStream.new(plain_theme, enabled: true)
    segments = collect_segments(stream, ["line\n"])
    assert_equal ["line\n"], segments
  end

  def test_leading_blank_lines_suppressed_until_first_content
    # Spinner-erase + the model's habitual leading "\n\n" otherwise stack
    # 2-3 visible blank rows at every step boundary.
    stream = Rubik::UI::MarkdownStream.new(color_theme, enabled: true)
    segments = collect_segments(stream, ["\n\n", "Cevap metni.\n"])
    assert_equal ["Cevap metni.\n"], segments
  end

  def test_finish_rearms_leading_blank_suppression_for_next_step
    # Shell calls finish on :chunk_end — one streamed step ends there and
    # the next step's leading blanks must be suppressed again.
    stream = Rubik::UI::MarkdownStream.new(color_theme, enabled: true)
    segments = []
    stream.push("Birinci adım.\n") { |seg| segments << seg }
    stream.finish { |seg| segments << seg }
    stream.push("\n\nİkinci adım.\n") { |seg| segments << seg }
    stream.finish { |seg| segments << seg }
    assert_equal ["Birinci adım.\n", "İkinci adım.\n"], segments
  end

  def test_paragraph_blank_lines_after_content_are_kept
    stream = Rubik::UI::MarkdownStream.new(color_theme, enabled: true)
    segments = collect_segments(stream, ["Paragraf bir.\n", "\n\n", "Paragraf iki.\n"])
    assert_equal ["Paragraf bir.\n", "\n", "\n", "Paragraf iki.\n"], segments
  end

  def test_whitespace_only_lines_suppressed_until_content
    stream = Rubik::UI::MarkdownStream.new(color_theme, enabled: true)
    segments = collect_segments(stream, ["   \n", "\n", "içerik\n"])
    assert_equal ["içerik\n"], segments
  end

  def test_suppression_off_when_styling_disabled
    # Piped output keeps its byte-identical contract — no visual polish.
    stream = Rubik::UI::MarkdownStream.new(plain_theme, enabled: true)
    segments = collect_segments(stream, ["\n\n", "text\n"])
    assert_equal ["\n", "\n", "text\n"], segments
  end

  def test_render_document_plain_when_disabled
    assert_equal "**x**", Rubik::UI::MarkdownStream.render_document("**x**", plain_theme, enabled: true)
  end

  def test_render_document_markdown_when_enabled
    out = Rubik::UI::MarkdownStream.render_document("**x**", color_theme, enabled: true)
    assert_includes out, "\e["
  end
end
