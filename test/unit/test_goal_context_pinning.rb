# frozen_string_literal: true

require_relative "../test_helper"

class TestGoalContextPinning < Minitest::Test
  GOAL_TEXT = "<user_task>\nFix the payment module so all its tests pass\n</user_task>"

  def fat_tool_turn(tag, filler = "x" * 4000)
    [
      { role: "assistant", content: nil, tool_calls: [{ "tool" => "read_file", "args" => { "path" => "lib/#{tag}.rb" } }] },
      { role: "tool", tool_name: "read_file", content: "#{tag}: #{filler}" }
    ]
  end

  def goal_history(extra_units = 6)
    [
      { role: "system", content: "system prompt" },
      { role: "user", content: "prior conversation turn" },
      { role: "assistant", content: "prior answer" }
    ] + (1..extra_units).flat_map { |i| fat_tool_turn("unit#{i}") } +
      [{ role: "user", content: GOAL_TEXT }] +
      [{ role: "assistant", content: "working on it", tool_calls: [{ "tool" => "list_files", "args" => {} }] },
       { role: "tool", tool_name: "list_files", content: "a.rb" }]
  end

  def assert_goal_survives(history)
    goal_msgs = history.select { |m| m.is_a?(Hash) && (m[:role] || m["role"]).to_s == "user" && m[:content].to_s.include?("<user_task>") }
    refute_empty goal_msgs, "the <user_task> goal message must survive compaction"
    assert_includes goal_msgs.first[:content], "Fix the payment module", "goal text must be intact, not truncated"
    goal_msgs
  end

  def test_sliding_window_never_drops_the_user_task_message
    compacted = Rubik::Prompt::ContextCompactor.compact_history(
      goal_history, context_limit: 8192, max_output_tokens: 1024,
                    config: { "compaction_strategy" => "sliding_window" }
    )
    assert_goal_survives(compacted)
  end

  def test_emergency_compaction_preserves_the_user_task_message
    history = goal_history
    Rubik::Prompt::EmergencyCompactor.compact!(history, context_limit: 8192, max_output_tokens: 1024, config: {})
    assert_goal_survives(history)
  end

  def test_hybrid_strategy_also_pins_the_goal
    compacted = Rubik::Prompt::ContextCompactor.compact_history(
      goal_history, context_limit: 8192, max_output_tokens: 1024,
                    config: { "compaction_strategy" => "hybrid" }
    )
    assert_goal_survives(compacted)
  end

  def test_multiple_user_task_messages_all_survive_in_original_order
    second_goal = "<user_task>\nSecond refined goal after continue\n</user_task>"
    history = goal_history + [{ role: "user", content: second_goal }] + fat_tool_turn("tail_unit")

    compacted = Rubik::Prompt::ContextCompactor.compact_history(
      history, context_limit: 8192, max_output_tokens: 1024,
               config: { "compaction_strategy" => "sliding_window" }
    )
    goals = assert_goal_survives(compacted)
    assert_equal 2, goals.size, "both <user_task> messages must survive"
    assert_includes goals.first[:content], "Fix the payment module"
    assert_includes goals.last[:content], "Second refined goal"
    assert_operator compacted.index(goals.first), :<, compacted.index(goals.last), "original order preserved"
  end

  def test_trim_oversized_messages_exempts_the_pinned_goal
    long_goal = "<user_task>\n#{'fix payments. ' * 800}\n</user_task>"
    history = goal_history(4)
    goal_idx = history.index { |m| m.is_a?(Hash) && m[:content].to_s.include?("<user_task>") }
    refute_nil goal_idx
    history[goal_idx] = { role: "user", content: long_goal }

    compacted = Rubik::Prompt::ContextCompactor.compact_history(
      history, context_limit: 4096, max_output_tokens: 512,
               config: { "compaction_strategy" => "sliding_window" }
    )
    goal = compacted.find { |m| m.is_a?(Hash) && m[:content].to_s.include?("<user_task>") }
    refute_nil goal, "oversized pinned goal must not be dropped"
    assert_includes goal[:content], "fix payments. " * 700, "pinned goal must not be halved by the trim layer"
  end

  def test_compacted_summary_count_counts_only_dropped_units
    compacted = Rubik::Prompt::ContextCompactor.compact_history(
      goal_history, context_limit: 8192, max_output_tokens: 1024,
                    config: { "compaction_strategy" => "sliding_window" }
    )
    summary = compacted.find { |m| m.is_a?(Hash) && m[:content].to_s.include?("<compacted_summary") }
    refute_nil summary, "some units must have been dropped for this fixture"
    count = summary[:content][/count="(\d+)"/, 1].to_i
    assert_operator count, :>, 0
    assert_operator count, :<, compacted.size + count, "count must reflect dropped messages, not survivors"
    # The pinned goal is not dropped, so survivors + dropped == original
    # message count (the summary marker itself is an added message).
    original_msgs = goal_history.size
    assert_equal original_msgs, compacted.size - 1 + count
  end

  def test_quoted_opening_tag_alone_does_not_pin
    # A user-pasted quoted prompt containing only the opening literal must
    # not become an undroppable, untrimmable resident of the window.
    pasted = "the docs say wrap tasks like <user_task> before submitting #{'padding ' * 700}"
    history = [
      { role: "system", content: "system prompt" },
      { role: "user", content: "question" },
      { role: "assistant", content: "answer" },
      { role: "user", content: pasted }
    ] + (1..6).flat_map { |i| fat_tool_turn("padded#{i}") } + [
      { role: "user", content: "latest question" },
      { role: "assistant", content: "latest answer" }
    ]

    compacted = Rubik::Prompt::ContextCompactor.compact_history(
      history, context_limit: 8192, max_output_tokens: 1024,
               config: { "compaction_strategy" => "sliding_window" }
    )
    refute Rubik::Prompt::ContextCompactor.goal_message?(pasted_message(history)),
           "opening-tag-only content must not classify as a goal message"
    assert compacted.none? { |m| m.is_a?(Hash) && m[:content].to_s.include?("the docs say wrap tasks") },
           "the pasted message must stay droppable"
  end

  def pasted_message(history)
    history.find { |m| m.is_a?(Hash) && m[:content].to_s.include?("the docs say wrap tasks") }
  end

  def test_unpinned_history_compacts_to_legacy_shape
    history = [
      { role: "system", content: "sys" },
      { role: "user", content: "u1" },
      { role: "assistant", content: "a1" }
    ] + (1..6).flat_map { |i| fat_tool_turn("plain#{i}", "y" * 4000) } + [
      { role: "user", content: "latest question" },
      { role: "assistant", content: "latest answer" }
    ]

    compacted = Rubik::Prompt::ContextCompactor.compact_history(
      history, context_limit: 8192, max_output_tokens: 1024,
               config: { "compaction_strategy" => "sliding_window" }
    )
    summary_idx = compacted.index { |m| m[:content].to_s.include?("<compacted_summary") }
    refute_nil summary_idx, "dropping must still occur without pinned units"
    # Legacy shape: summary sits right after the preserved head, before the tail.
    assert_equal "sys", compacted[0][:content]
    assert_equal "u1", compacted[1][:content]
    assert_equal "latest question", compacted[-2][:content]
    assert_equal "latest answer", compacted[-1][:content]
    assert_operator summary_idx, :<=, 2, "summary must sit immediately after the head units"
  end
end
