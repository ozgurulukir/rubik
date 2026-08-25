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
end

# Alias the module under test to a short name for readability.
module EmergencyCompactorUnderTest
  def self.compact!(history)
    Rubik::Prompt::EmergencyCompactor.compact!(history)
  end
end
