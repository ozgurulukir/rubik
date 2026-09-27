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

  # ── map_action / confirm_action: REMOVED (Plan 111 F5) ─────────────
  # The adaptive sandbox-network approval card never had a production
  # caller (phantom security control); removed together with its
  # implementation. keypress_yes_no / build_prompt keep live callers.

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
end
