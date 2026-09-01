# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestUIBanner < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_banner")
    @home_dir = Dir.mktmpdir("rubik_banner_home")
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

  def test_banner_returns_nil_when_disabled_via_config
    @config.set("ui.banner", false)
    assert_nil Rubik::UI::Banner.render(@shell, @theme)
  end

  def test_banner_returns_nil_for_non_interactive_output
    # RUBIK_TEST=1 + StringIO → Capability.interactive? is false →
    # the banner is skipped for pipes/scripts
    assert_nil Rubik::UI::Banner.render(@shell, @theme)
  end

  def test_banner_renders_version_line_when_enabled_and_interactive
    Rubik::UI::Capability.stub :interactive?, true do
      banner = Rubik::UI::Banner.render(@shell, @theme)

      assert_includes banner, "Rubik v#{Rubik::VERSION}"
      assert_includes banner, "rubik"
    end
  end
end
