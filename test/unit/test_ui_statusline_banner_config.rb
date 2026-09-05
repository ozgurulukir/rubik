# frozen_string_literal: true

require_relative "../test_helper"
require_relative "test_ui_capability"

class TestUIStatuslineBannerAndConfig < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_sl")
    @home_dir = Dir.mktmpdir("rubik_sl_home")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @home_dir)
    @shell = Rubik::REPL::Shell.new(config: @config, output: StringIO.new)
    @theme = Rubik::UI::Theme.new(enabled: false)
  end

  def teardown
    @shell.stop
    FileUtils.rm_rf(@temp_dir)
    FileUtils.rm_rf(@home_dir)
  end

  def test_config_defaults_cover_ui_surface
    assert_equal "auto", @config.fetch("ui.color")
    assert_equal "unicode", @config.fetch("ui.glyphs")
    assert_equal true, @config.fetch("ui.banner")
    assert_equal true, @config.fetch("ui.spinner")
    assert_equal "live", @config.fetch("ui.markdown")
    assert_equal true, @config.fetch("ui.statusline")
    assert_equal false, @config.fetch("ui.input_box")
    assert_includes @config.fetch("ui.statusline_template"), "{model}"
  end

  def test_statusline_renders_template_placeholders
    line = Rubik::UI::Statusline.render(@shell, @theme)
    assert_includes line, "ctx "
    assert_includes line, "temiz"
    assert_includes line, "sandbox kapalı"

    @config.set("sandbox.enabled", true)
    enabled_line = Rubik::UI::Statusline.render(@shell, @theme)
    assert_includes enabled_line, "izole"
  end

  def test_statusline_custom_template
    @config.set("ui.statusline_template", "P:{project} V:{verbosity}")
    line = Rubik::UI::Statusline.render(@shell, @theme)
    assert_includes line, "P:"
    assert_includes line, "V:normal"
  end

  def test_statusline_template_coerces_yaml_hash_back_to_default
    # "{a} {b}" values round-trip through YAML parsing as a flow-mapping
    # Hash; the renderer must fall back to the default template.
    @config.set("ui.statusline_template", "{project} [{branch}] {verbosity}")
    template_value = @config.fetch("ui.statusline_template")
    line = Rubik::UI::Statusline.render(@shell, @theme)
    refute_nil line
    assert_includes line, "ctx "
    assert_match(/Hash|String/, template_value.class.to_s)
  end

  def test_statusline_disabled_via_config
    @config.set("ui.statusline", false)
    assert_nil Rubik::UI::Statusline.render(@shell, @theme)
  end

  def test_statusline_shows_dirty_count_when_buffer_dirty
    @shell.buffer_manager.write("dirty_demo.rb", "puts 1\n")
    line = Rubik::UI::Statusline.render(@shell, @theme)
    assert_includes line, "1 ✎"
  end

  def test_banner_skipped_in_test_environment
    assert_nil Rubik::UI::Banner.render(@shell, @theme)
  end

  def test_banner_renders_on_interactive_console
    ENV.delete("RUBIK_TEST")
    tty_shell = Rubik::REPL::Shell.new(config: @config, output: FakeTTYIO.new, input: FakeTTYIO.new, root_dir: @temp_dir)
    banner = Rubik::UI::Banner.render(tty_shell, tty_shell.ui_theme)
    refute_nil banner
    assert_includes banner, "Rubik v"
    assert_includes banner, "╭"
  ensure
    ENV["RUBIK_TEST"] = "1"
    tty_shell&.stop
  end

  def test_banner_shows_bwrap_prompt_on_linux_when_sandbox_disabled
    skip "Linux and bwrap only" unless Rubik::Platform.linux? && Rubik::Platform.which("bwrap")
    ENV.delete("RUBIK_TEST")
    tty_shell = Rubik::REPL::Shell.new(config: @config, output: FakeTTYIO.new, input: FakeTTYIO.new, root_dir: @temp_dir)
    banner = Rubik::UI::Banner.render(tty_shell, tty_shell.ui_theme)
    assert_includes banner, "Linux & bwrap algılandı"
  ensure
    ENV["RUBIK_TEST"] = "1"
    tty_shell&.stop
  end

  def test_refresh_ui_rebuilds_renderer_without_losing_spinner_safety
    old_renderer = @shell.ui_renderer
    @shell.refresh_ui!
    refute_equal old_renderer, @shell.ui_renderer
    refute @shell.ui_renderer.spinner.spinning?
  end

  def test_render_step_event_prints_formatted_line
    @shell.render_step_event({ type: :tool_call, tool: "read_file", args: { "path" => "x.rb" }, step: 1, max_steps: 5 })
    assert_includes @shell.output.string, "⏺ read_file"
  end

  def test_box_prompt_is_always_a_single_string
    # Reline 0.6 applies String#gsub to the prompt — an Array prompt would
    # crash readline when ui.input_box is enabled.
    plain = "rubik (demo) > "
    assert_equal plain, @shell.box_prompt_lines(plain, boxed: false)

    boxed = @shell.box_prompt_lines(plain, boxed: true)
    assert_kind_of String, boxed
    assert boxed.start_with?("│")
    assert_includes boxed, plain
  end

  def test_execute_command_kills_leftover_spinner
    # A command (e.g. !plan) that dies mid-LLM-wait leaves a live spinner;
    # the command ensure must kill it so it never corrupts the next prompt.
    @shell.ui_renderer.spinner.start(step: 1, max_steps: 5)
    assert @shell.ui_renderer.spinner.spinning?

    @shell.execute_input("!status")

    refute @shell.ui_renderer.spinner.spinning?
  end
end
