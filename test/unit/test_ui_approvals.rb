# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestUIApprovals < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_approvals")
    @home_dir = Dir.mktmpdir("rubik_approvals_home")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @home_dir)
    @input = StringIO.new("")
    @output = StringIO.new
    @shell = Rubik::REPL::Shell.new(config: @config, input: @input, output: @output)
    @theme = Rubik::UI::Theme.new(enabled: false)
  end

  def teardown
    @shell.stop
    FileUtils.rm_rf(@temp_dir)
    FileUtils.rm_rf(@home_dir)
  end

  # ── normalize_answer ───────────────────────────────────────────────

  def test_normalize_answer_downcases_stripped_input
    assert_equal "y", Rubik::UI::Approvals.normalize_answer(" Y ", "n")
    assert_equal "n", Rubik::UI::Approvals.normalize_answer("N", "n")
  end

  def test_normalize_answer_uses_default_when_empty
    assert_equal "n", Rubik::UI::Approvals.normalize_answer("", "n")
    assert_equal "y", Rubik::UI::Approvals.normalize_answer("", "y")
  end

  def test_normalize_answer_handles_enter_and_escape
    assert_equal "y", Rubik::UI::Approvals.normalize_answer("\r", "y")
    assert_equal "y", Rubik::UI::Approvals.normalize_answer("\e", "y")
    assert_equal "n", Rubik::UI::Approvals.normalize_answer("\r", "n")
  end

  def test_normalize_answer_handles_non_string
    assert_equal "n", Rubik::UI::Approvals.normalize_answer(nil, "n")
    assert_equal "n", Rubik::UI::Approvals.normalize_answer(123, "n")
  end

  # ── map_action ─────────────────────────────────────────────────────

  def test_map_action_yes_answers
    assert_equal :yes, Rubik::UI::Approvals.map_action("y", false)
    assert_equal :yes, Rubik::UI::Approvals.map_action("Y", false)
    assert_equal :yes, Rubik::UI::Approvals.map_action("yes", true)
    assert_equal :yes, Rubik::UI::Approvals.map_action("evet", false)
  end

  def test_map_action_network_blocked_a_grants_network
    # network allowed = false → "a" grants network access for one action
    assert_equal :yes_network, Rubik::UI::Approvals.map_action("a", false)
    # network allowed = true → "a" is plain approval
    assert_equal :yes, Rubik::UI::Approvals.map_action("a", true)
  end

  def test_map_action_sandbox_adaptive
    # network allowed = true → "s" approves once inside sandbox
    assert_equal :yes_sandbox, Rubik::UI::Approvals.map_action("s", true)
    # network blocked = false → "s" is plain approval
    assert_equal :yes, Rubik::UI::Approvals.map_action("s", false)
  end

  def test_map_action_defaults_to_no
    assert_equal :no, Rubik::UI::Approvals.map_action("q", false)
    assert_equal :no, Rubik::UI::Approvals.map_action("", false)
    assert_equal :no, Rubik::UI::Approvals.map_action("x", true)
    assert_equal :no, Rubik::UI::Approvals.map_action(nil, false)
  end

  # ── keypress_yes_no default flow ───────────────────────────────────

  def test_keypress_yes_no_returns_default_on_standard_error
    # Non-TTY output means TTY::Prompt cannot be built → rescue → default "n"
    result = Rubik::UI::Approvals.keypress_yes_no(
      @shell, "Confirm?", theme: @theme, default: "n"
    )

    assert_equal "n", result
  end

  def test_keypress_yes_no_respects_y_default
    result = Rubik::UI::Approvals.keypress_yes_no(
      @shell, "Confirm?", theme: @theme, default: "y"
    )
    assert_equal "y", result
  end

  # ── confirm_action ─────────────────────────────────────────────────

  def test_confirm_action_returns_no_on_non_interactive
    # TTY::Prompt cannot attach to StringIO → rescues → :no
    result = Rubik::UI::Approvals.confirm_action(
      @shell, label: "Run network command?", theme: @theme
    )
    assert_equal :no, result
  end

  def test_confirm_action_prints_card_and_adaptive_hint
    @config.set("sandbox.allow_network", true)
    Rubik::UI::Approvals.confirm_action(
      @shell, label: "Run network command?", theme: @theme
    )

    assert_includes @output.string, "ONAY BEKLİYOR"
    assert_includes @output.string, "Run network command?"
    assert_includes @output.string, "s: onayla ve sandbox'ta çalıştır"
  end

  def test_confirm_action_network_blocked_shows_network_option
    @config.set("sandbox.allow_network", false)
    Rubik::UI::Approvals.confirm_action(
      @shell, label: "Fetch URL?", theme: @theme
    )

    assert_includes @output.string, "a: onayla ve ağ izniyle çalıştır"
    refute_includes @output.string, "s: onayla ve sandbox'ta çalıştır"
  end

  def test_confirm_action_prints_detail_when_present
    Rubik::UI::Approvals.confirm_action(
      @shell, label: "Delete file?", theme: @theme, detail: "This will remove lib/x.rb"
    )

    assert_includes @output.string, "This will remove lib/x.rb"
  end

  def test_confirm_action_omits_detail_when_absent
    Rubik::UI::Approvals.confirm_action(
      @shell, label: "Delete file?", theme: @theme
    )

    refute_includes @output.string, "This will remove"
  end
end
