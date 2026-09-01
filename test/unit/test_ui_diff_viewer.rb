# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestUIDiffViewer < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_diffviewer")
    @home_dir = Dir.mktmpdir("rubik_diffviewer_home")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @home_dir)
    @output = StringIO.new
    @shell = Rubik::REPL::Shell.new(config: @config, output: @output)
    @theme = Rubik::UI::Theme.new(enabled: false)
  end

  def teardown
    @shell.stop
    FileUtils.rm_rf(@temp_dir)
    FileUtils.rm_rf(@home_dir)
  end

  SAMPLE_DIFF = <<~DIFF
    --- a/lib/app.rb
    +++ b/lib/app.rb
    @@ -1,4 +1,5 @@
     require "x"
    -old line
    +new line
    +another line
  DIFF

  # ── render ─────────────────────────────────────────────────────────

  def test_render_noop_for_empty_diff
    result = Rubik::UI::DiffViewer.render(@shell, @theme, "")

    assert_nil result
    assert_empty @output.string
  end

  def test_render_plain_when_theme_color_disabled
    Rubik::UI::DiffViewer.render(@shell, @theme, SAMPLE_DIFF)

    # Plain output, byte-for-byte (no ANSI codes, no offer_actions on non-TTY)
    assert_equal SAMPLE_DIFF, @output.string
    refute_includes @output.string, "\e["
  end

  def test_render_returns_nil_for_nil_diff
    assert_nil Rubik::UI::DiffViewer.render(@shell, @theme, nil)
  end

  # ── colorize ───────────────────────────────────────────────────────

  def test_colorize_styles_added_removed_and_hunk_lines
    color_theme = Rubik::UI::Theme.new(enabled: true)
    colored = Rubik::UI::DiffViewer.colorize(SAMPLE_DIFF, color_theme)

    assert_includes colored, "\e["
    assert_includes colored, "-old line"
    assert_includes colored, "+new line"
    assert_includes colored, "@@ -1,4 +1,5 @@"
  end

  def test_colorize_plain_theme_passthrough
    plain = Rubik::UI::DiffViewer.colorize(SAMPLE_DIFF, @theme)

    refute_includes plain, "\e["
    assert_equal SAMPLE_DIFF, plain
  end

  def test_colorize_handles_three_plus_lines_as_bold
    color_theme = Rubik::UI::Theme.new(enabled: true)
    colored = Rubik::UI::DiffViewer.colorize("+++ b/x\n--- a/x\n=== merged\n", color_theme)

    # all three go through the bold path without error
    assert_includes colored, "+++ b/x"
    assert_includes colored, "--- a/x"
    assert_includes colored, "=== merged"
  end

  # ── interactive? ───────────────────────────────────────────────────

  def test_interactive_returns_false_for_stringio
    refute Rubik::UI::DiffViewer.interactive?(@shell)
  end

  # ── apply_all ──────────────────────────────────────────────────────

  def test_apply_all_with_no_dirty_files
    Rubik::UI::DiffViewer.apply_all(@shell)

    assert_includes @output.string, "Uygulanacak değişiklik kalmadı."
  end

  def test_apply_all_applies_dirty_files
    buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    buffer_manager.write("new_file.rb", "def x; end")
    @shell.instance_variable_set(:@buffer_manager, buffer_manager)
    @shell.define_singleton_method(:sync_context_and_ast) { |_paths| nil }

    Rubik::UI::DiffViewer.apply_all(@shell)

    assert_includes @output.string, "Uygulandı"
    assert_includes @output.string, "new_file.rb"
  end
end
