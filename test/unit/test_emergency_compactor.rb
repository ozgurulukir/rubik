# frozen_string_literal: true

require_relative "../test_helper"

# Tests for PR-H: Rubik::Prompt::EmergencyCompactor (the mutating
# context compactor, split out of ContextCompactor so the
# in-place mutation policy lives in its own module).
class TestEmergencyCompactor < Minitest::Test
  def test_returns_history_unchanged_when_nil
    assert_nil EmergencyCompactorUnderTest.compact!(nil)
  end

  def test_returns_history_unchanged_when_empty
    assert_equal [], EmergencyCompactorUnderTest.compact!([])
  end

  def test_truncates_long_tool_content
    large = "X" * 1000
    history = [
      { role: "tool", tool_call_id: "c1", content: large }
    ]
    EmergencyCompactorUnderTest.compact!(history)
    assert history[0][:content].length <= 500
  end

  def test_truncates_long_assistant_content
    large = "Y" * 2000
    history = [
      { role: "assistant", content: large }
    ]
    EmergencyCompactorUnderTest.compact!(history)
    assert history[0][:content].length <= 1100
  end

  def test_leaves_short_content_unchanged
    history = [
      { role: "user", content: "short" },
      { role: "assistant", content: "also short" }
    ]
    before = history.map { |m| m[:content] }
    EmergencyCompactorUnderTest.compact!(history)
    after = history.map { |m| m[:content] }
    assert_equal before, after
  end

  def test_mutates_in_place
    history = [
      { role: "tool", tool_call_id: "c1", content: "X" * 1000 }
    ]
    same_object = history
    EmergencyCompactorUnderTest.compact!(history)
    assert_same same_object, history
  end

  def test_handles_string_keyed_messages
    large = "Z" * 1000
    history = [
      { "role" => "tool", "content" => large }
    ]
    EmergencyCompactorUnderTest.compact!(history)
    assert history[0]["content"].length <= 500
  end

  def test_handles_non_hash_messages
    history = [
      "string message",
      { role: "user", content: "real" }
    ]
    EmergencyCompactorUnderTest.compact!(history)
    assert_equal "string message", history[0]
    assert_equal "real", history[1][:content]
  end

  # Plan 63 Faz A: with a context_limit the structural ContextCompactor runs
  # first — intermediate tool-call units collapse into a summary marker and
  # surviving prose/tool content stays intact (no blind 300/1000 cut).
  def test_structural_layer_collapses_intermediate_units_without_hard_truncation
    history = [{ role: "user", content: "start" }]
    6.times do |i|
      history << { role: "assistant", tool_calls: [{ "id" => "c#{i}", "tool" => "read_file", "args" => {} }] }
      history << { role: "tool", tool_call_id: "c#{i}", content: "x" * 1500 }
    end
    history << { role: "assistant", content: "analysis #{'y' * 2500}" }
    history << { role: "user", content: "finish" }

    layer = EmergencyCompactorUnderTest.compact!(history, context_limit: 10_000, max_output_tokens: 4096)

    assert_equal :structural, layer
    contents = history.map { |m| m.is_a?(Hash) ? m[:content].to_s : m.to_s }.join
    assert_includes contents, "compacted_summary"
    long_assistant = history.find { |m| m.is_a?(Hash) && m[:role] == "assistant" && m[:content].to_s.start_with?("analysis") }
    assert long_assistant, "long assistant message should survive the structural pass"
    assert_operator long_assistant[:content].length, :>, 2000, "assistant prose must not be hard-truncated"
    tools = history.select { |m| m.is_a?(Hash) && m[:role] == "tool" }
    assert_operator tools.length, :>=, 3
    assert tools.all? { |m| m[:content].length > 1000 }, "kept tool results must stay intact (no 300-char cut)"
  end

  def test_strategy_off_falls_through_to_hard_truncation
    history = [
      { role: "tool", tool_call_id: "c1", content: "x" * 10_000 },
      { role: "assistant", content: "y" * 2000 }
    ]
    layer = EmergencyCompactorUnderTest.compact!(history, context_limit: 8000, config: { "compaction_strategy" => "off" })

    assert_equal :hard_truncate, layer
    assert history[0][:content].length <= 500
    assert history[1][:content].length <= 1100
  end

  def test_legacy_one_argument_path_reports_hard_truncate_layer
    history = [{ role: "tool", tool_call_id: "c1", content: "x" * 1000 }]
    layer = EmergencyCompactorUnderTest.compact!(history)

    assert_equal :hard_truncate, layer
    assert history[0][:content].length <= 500
  end

  def test_preserves_history_array_identity_under_structural_pass
    history = [
      { role: "user", content: "start" },
      { role: "assistant", tool_calls: [{ "id" => "c1", "tool" => "read_file", "args" => {} }] },
      { role: "tool", tool_call_id: "c1", content: "x" * 1500 },
      { role: "assistant", tool_calls: [{ "id" => "c2", "tool" => "grep", "args" => {} }] },
      { role: "tool", tool_call_id: "c2", content: "y" * 1500 },
      { role: "assistant", content: "done" }
    ]
    original_id = history.object_id

    EmergencyCompactorUnderTest.compact!(history, context_limit: 10_000)

    assert_same original_id, history.object_id
  end
end

# Alias the module under test to a short name for readability.
module EmergencyCompactorUnderTest
  def self.compact!(history, **)
    Rubik::Prompt::EmergencyCompactor.compact!(history, **)
  end
end
