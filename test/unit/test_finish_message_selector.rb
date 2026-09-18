# frozen_string_literal: true

require_relative "../test_helper"

# Review Finding 5 closure pins: the finish-message selection heuristic is
# extracted into FinishMessageSelector; these tests pin both the preserved
# legacy behavior and the named-constant contract.
class TestFinishMessageSelector < Minitest::Test
  S = Rubik::Orchestrator::FinishMessageSelector

  def test_filler_message_yields_narration_when_present
    assert_equal "Detailed narration", S.select("Detailed narration", "done")
  end

  def test_filler_message_with_no_narration_yields_the_filler
    assert_equal "done", S.select("", "done")
  end

  def test_both_empty_yields_default_constant
    assert_equal "Completed", S.select("", "")
    assert_equal Rubik::Orchestrator::FinishMessageSelector::DEFAULT_MESSAGE, S.select(nil, nil)
  end

  def test_narration_and_message_subsume_each_other_keeps_richer
    assert_equal "Fix bug in parser and add tests", S.select("Fix bug in parser and add tests", "Fix bug")
  end

  def test_distinct_narration_and_message_are_joined
    assert_equal "Analysis text\n\nGoal reached", S.select("Analysis text", "Goal reached")
  end

  # The richer-narration branches fire when one text subsumes the other
  # (legacy contract): distinct texts are always joined (previous test).

  def test_longer_narration_wins_when_it_is_not_tool_narration
    msg = "All tests pass"
    narration = "All tests pass after fixing the retry gate and verifying the full suite"
    assert narration.include?(msg)
    assert_operator narration.length, :>, msg.length
    assert_equal narration, S.select(narration, msg)
  end

  def test_tool_narration_hint_lets_message_win_despite_length
    msg = "All tests pass"
    narration = "All tests pass; the tool run confirms everything now with extra detail"
    assert narration.include?(msg)
    assert_operator narration.length, :>, msg.length
    assert narration.include?(S::NARRATION_TOOL_HINT)
    assert_equal msg, S.select(narration, msg), "narration mentioning 'tool' must lose to the finish message"
  end

  def test_generic_fillers_constant_matches_legacy_list
    assert_equal %w[completed done finished ok task_completed], S::GENERIC_FILLERS
  end

  def test_step_executor_uses_selector_constant_and_hygiene
    base = File.expand_path("../../lib/rubik/orchestrator", __dir__)
    executor = File.read(File.join(base, "step_executor.rb"))
    selector = File.read(File.join(base, "finish_message_selector.rb"))
    assert_includes executor, "FinishMessageSelector.select",
                    "handle_finish_tool must delegate to FinishMessageSelector"
    refute_includes executor, 'include?("tool")',
                    "magic substring must not remain inline in step_executor.rb"
    assert_includes executor, "require_relative \"finish_message_selector\"",
                    "selector must be required by step_executor"
    # File hygiene: extraction must not bloat either file (project limit 350).
    assert_operator File.readlines(File.join(base, "step_executor.rb")).size, :<, 350
    assert_operator File.readlines(File.join(base, "finish_message_selector.rb")).size, :<, 350
  end
end
