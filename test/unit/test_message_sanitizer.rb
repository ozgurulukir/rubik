# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/llm/message_sanitizer"

# Plan 61 D-6: strict endpoints (Anthropic Messages API) reject histories
# with consecutive same-role turns. Failed/legacy/compacted histories can
# produce them — the sanitizer folds them before they reach the wire.
class TestMessageSanitizer < Minitest::Test
  def test_consecutive_users_are_merged
    msgs = [
      { role: "user", content: "first question" },
      { role: "user", content: "follow-up detail" }
    ]
    out = Rubik::LLM::MessageSanitizer.normalize(msgs)
    assert_equal 1, out.size
    assert_equal "user", out[0][:role]
    assert_includes out[0][:content], "first question"
    assert_includes out[0][:content], "follow-up detail"
  end

  def test_alternating_roles_pass_through_unchanged
    msgs = [
      { role: "user", content: "q1" },
      { role: "assistant", content: "a1" },
      { role: "user", content: "q2" },
      { role: "assistant", content: "a2" }
    ]
    out = Rubik::LLM::MessageSanitizer.normalize(msgs)
    assert_equal 4, out.size
    assert_equal(["user", "assistant", "user", "assistant"], out.map { |m| m[:role] })
  end

  def test_tool_results_are_never_merged
    msgs = [
      { role: "assistant", content: nil, tool_calls: [{ "id" => "c1", "tool" => "read_file", "args" => {} }] },
      { role: "tool", tool_call_id: "c1", content: "result-1" },
      { role: "tool", tool_call_id: "c2", content: "result-2" }
    ]
    out = Rubik::LLM::MessageSanitizer.normalize(msgs)
    assert_equal 3, out.size
    assert_equal "c1", out[1][:tool_call_id]
    assert_equal "c2", out[2][:tool_call_id]
  end

  def test_assistant_with_tool_calls_starts_fresh_unit
    msgs = [
      { role: "assistant", content: "working" },
      { role: "assistant", content: nil, tool_calls: [{ "id" => "c1", "tool" => "grep_search", "args" => {} }] }
    ]
    out = Rubik::LLM::MessageSanitizer.normalize(msgs)
    assert_equal 2, out.size, "a tool_call assistant must not be folded into the previous assistant"
    assert_equal "grep_search", out[1][:tool_calls].first["tool"]
  end

  def test_dangling_trailing_user_is_left_untouched
    msgs = [{ role: "user", content: "unanswered question" }]
    out = Rubik::LLM::MessageSanitizer.normalize(msgs)
    assert_equal 1, out.size, "dangling user turns are request-time normal; never auto-completed here"
  end

  def test_string_keyed_messages_are_supported
    msgs = [
      { "role" => "user", "content" => "one" },
      { "role" => "user", "content" => "two" }
    ]
    out = Rubik::LLM::MessageSanitizer.normalize(msgs)
    assert_equal 1, out.size
    assert_equal "one\n\ntwo", out[0]["content"]
  end

  def test_nil_and_empty_input
    assert_empty Rubik::LLM::MessageSanitizer.normalize(nil)
    assert_empty Rubik::LLM::MessageSanitizer.normalize([])
  end
end
