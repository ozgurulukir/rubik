# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# A StringIO that claims to be a real terminal (tty? -> true) and can also
# report a window size, used to exercise the color/spinner capable paths.
class FakeTTYIO < StringIO
  def tty?
    true
  end

  def winsize
    [30, 100]
  end
end

class TestUICapability < Minitest::Test
  def teardown
    ENV.delete("NO_COLOR")
    ENV.delete("CLICOLOR_FORCE")
    Rubik::UI::Capability.reset_memoization!
  end

  # RUBIK_TEST=1 (set globally by test_helper) is the hard determinism gate
  # and outranks every other signal; tests that verify the capable paths
  # lift it temporarily.
  def without_rubik_test
    old_term = ENV.fetch("TERM", nil)
    ENV["TERM"] = "xterm-256color" if ENV["TERM"] == "dumb" || ENV["TERM"].nil?
    ENV.delete("RUBIK_TEST")
    Rubik::UI::Capability.reset_memoization!
    yield
  ensure
    ENV["TERM"] = old_term
    ENV["RUBIK_TEST"] = "1"
    Rubik::UI::Capability.reset_memoization!
  end

  def test_strip_ansi_removes_escape_sequences
    colored = "\e[31mred\e[0m plain \e[1;33mbold\e[0m"
    assert_equal "red plain bold", Rubik::UI::Capability.strip_ansi(colored)
  end

  def test_strip_ansi_leaves_plain_text_alone
    assert_equal "hello", Rubik::UI::Capability.strip_ansi("hello")
  end

  def test_color_disabled_for_non_tty
    refute Rubik::UI::Capability.color?(StringIO.new)
  end

  def test_color_enabled_for_tty
    without_rubik_test do
      assert Rubik::UI::Capability.color?(FakeTTYIO.new)
    end
  end

  def test_color_disabled_with_no_color_env
    without_rubik_test do
      ENV["NO_COLOR"] = "1"
      refute Rubik::UI::Capability.color?(FakeTTYIO.new)
    end
  end

  def test_color_forced_with_clicolor_force
    without_rubik_test do
      ENV["CLICOLOR_FORCE"] = "1"
      assert Rubik::UI::Capability.color?(StringIO.new)
    end
  end

  def test_color_never_via_config
    config = Rubik::Config.new(root_dir: Dir.mktmpdir("rubik_cap"), home_dir: Dir.mktmpdir("rubik_cap_home"))
    config.set("ui.color", "never")
    without_rubik_test do
      refute Rubik::UI::Capability.color?(FakeTTYIO.new, config)
    end
  end

  def test_color_always_via_config
    config = Rubik::Config.new(root_dir: Dir.mktmpdir("rubik_cap2"), home_dir: Dir.mktmpdir("rubik_cap2_home"))
    config.set("ui.color", "always")
    without_rubik_test do
      assert Rubik::UI::Capability.color?(StringIO.new, config)
    end
  end

  def test_rubik_test_env_is_the_hard_off_switch
    assert Rubik::UI::Capability.interactive_env? == false
    refute Rubik::UI::Capability.color?(FakeTTYIO.new)
  end

  def test_spinner_requires_tty_and_interactive_env
    refute Rubik::UI::Capability.spinner?(StringIO.new)
    # RUBIK_TEST=1 is set by test_helper, so even a TTY refuses the spinner.
    refute Rubik::UI::Capability.spinner?(FakeTTYIO.new)
  end

  def test_interactive_predicate_requires_tty_input_and_real_output
    without_rubik_test do
      assert Rubik::UI::Capability.interactive?(input: FakeTTYIO.new, output: FakeTTYIO.new)
      refute Rubik::UI::Capability.interactive?(input: StringIO.new, output: FakeTTYIO.new)
      refute Rubik::UI::Capability.interactive?(input: FakeTTYIO.new, output: StringIO.new)
    end
  end

  def test_interactive_predicate_accepts_tee_wrapping_real_terminal
    # REPL command capture wraps @output in TeeIO($stdout, StringIO); the
    # panel/diff/picker surfaces must stay reachable through it.
    without_rubik_test do
      tee = Rubik::REPL::TeeIO.new(FakeTTYIO.new, StringIO.new)
      assert Rubik::UI::Capability.interactive?(input: FakeTTYIO.new, output: tee)

      capture_only = Rubik::REPL::TeeIO.new(StringIO.new, StringIO.new)
      refute Rubik::UI::Capability.interactive?(input: FakeTTYIO.new, output: capture_only)
    end
  end

  def test_unwrap_tee_resolves_real_terminal
    real = FakeTTYIO.new
    tee = Rubik::REPL::TeeIO.new(real, StringIO.new)
    assert_equal real, Rubik::UI::Capability.unwrap_tee(tee)
    assert_equal real, Rubik::UI::Capability.unwrap_tee(real)
    assert_nil Rubik::UI::Capability.unwrap_tee(Rubik::REPL::TeeIO.new(StringIO.new))
  end
end
