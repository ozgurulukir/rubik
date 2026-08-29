# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "rubik/prompt/context_compactor"

# Plan 61 D-12: the long-lived REPL conversation window is trimmed by a
# token budget (plus an absolute entry cap), not a blind last(20).
class TestTurnWindowBudget < Minitest::Test
  def test_nil_ceiling_applies_only_entry_cap
    hist = build_pairs(3)
    out = Rubik::Prompt::ContextCompactor.trim_history_to_budget(hist, ceiling: nil, max_entries: 4)
    assert_equal 4, out.size, "only the absolute cap may trim when no ceiling is known"
    assert_equal hist.last(4), out
  end

  def test_ceiling_drops_oldest_entries_first
    hist = [
      { role: "user", content: "x" * 2000 },
      { role: "assistant", content: "small" },
      { role: "user", content: "y" * 2000 },
      { role: "assistant", content: "small" },
      { role: "user", content: "fresh question" },
      { role: "assistant", content: "fresh answer" }
    ]
    out = Rubik::Prompt::ContextCompactor.trim_history_to_budget(hist, ceiling: 400, min_entries: 2)
    assert_equal "fresh answer", out.last[:content], "newest pair must always survive"
    refute_equal hist, out
    assert out.size >= 2, "at least one pair survives"
    assert_operator Rubik::Prompt::TokenEstimator.estimate_history(out), :<=, 400 + 600,
                    "trimming must approach the ceiling (min-entries floor may hold it above)"
  end

  def test_min_entries_floor_keeps_recent_context
    huge = Array.new(10) { |i| [{ role: "user", content: "z" * 3000 }, { role: "assistant", content: "r#{i}" }] }.flatten
    out = Rubik::Prompt::ContextCompactor.trim_history_to_budget(huge, ceiling: 10, min_entries: 4)
    assert_equal 4, out.size, "trimming stops at the min-entries floor"
  end

  def test_small_histories_pass_through
    hist = [{ role: "user", content: "q" }, { role: "assistant", content: "a" }]
    out = Rubik::Prompt::ContextCompactor.trim_history_to_budget(hist, ceiling: 10_000, max_entries: 40)
    assert_same hist, out
  end

  def test_window_opens_with_a_user_turn
    hist = [
      { role: "assistant", content: "orphan assistant" },
      { role: "user", content: "q" },
      { role: "assistant", content: "a" }
    ]
    out = Rubik::Prompt::ContextCompactor.trim_history_to_budget(hist, ceiling: 10_000)
    assert_equal "user", out.first[:role], "strict providers require the window to open with a user turn"
    assert_equal 2, out.size
  end

  def test_shell_window_trims_to_model_budget
    temp_dir = Dir.mktmpdir("rubik_window")
    temp_home = Dir.mktmpdir("rubik_window_home")
    begin
      config = Rubik::Config.new(root_dir: temp_dir, home_dir: temp_home)
      output = StringIO.new
      shell = Rubik::REPL::Shell.new(config: config, output: output, root_dir: temp_dir)

      provider = Object.new
      provider.define_singleton_method(:complete) do |_msgs, _opts = {}|
        Struct.new(:text, :usage).new("answer", { input_tokens: 2, output_tokens: 2 })
      end
      router = Object.new
      router.define_singleton_method(:route) do |*_a, **_kw|
        { role: "default", model: "mock-1", provider: provider,
          spec: { "provider" => "mock", "name" => "test" },
          context_limit: 32_768, max_output_tokens: 4_096 }
      end
      shell.instance_variable_set(:@router, router)
      # Force a tiny usable ceiling so the budget actually bites.
      fake_registry = Object.new
      fake_registry.define_singleton_method(:effective_input_limit_for) { |_p, _m| 300 }
      shell.instance_variable_set(:@llm_registry, fake_registry)

      shell.execute_input("görev bir #{'x' * 2000}")
      shell.execute_input("görev iki #{'y' * 2000}")
      shell.execute_input("görev üç #{'w' * 2000}")

      window = shell.conversation_history
      assert_equal 4, window.size, "window must clamp at the min-entries floor (2 pairs)"
      assert_equal "görev iki #{'y' * 2000}", window.first[:content], "oldest pair is dropped first"
      assert_equal "answer", window.last[:content], "newest assistant answer survives"
    ensure
      shell&.stop
      FileUtils.remove_entry(temp_dir) if temp_dir && File.exist?(temp_dir)
      FileUtils.remove_entry(temp_home) if temp_home && File.exist?(temp_home)
    end
  end

  private

  def build_pairs(count)
    Array.new(count) { |i| [{ role: "user", content: "q#{i}" }, { role: "assistant", content: "a#{i}" }] }.flatten
  end
end
