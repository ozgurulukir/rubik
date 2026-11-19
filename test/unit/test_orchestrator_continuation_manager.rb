# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/orchestrator/continuation_manager"

class TestOrchestratorContinuationManager < Minitest::Test
  def setup
    @manager = Rubik::Orchestrator::ContinuationManager.new(max_auto_continues: 3)
  end

  def test_enabled_by_default
    assert @manager.enabled?
  end

  def test_disabled_by_config
    disabled_mgr = Rubik::Orchestrator::ContinuationManager.new(config: { "llm" => { "auto_continue_on_length" => false } })
    refute disabled_mgr.enabled?
  end

  def test_truncation_detection
    assert @manager.truncation?("length")
    assert @manager.truncation?("LENGTH")
    assert @manager.truncation?("max_tokens")
    assert @manager.truncation?("MAX_TOKENS")
    refute @manager.truncation?("stop")
    refute @manager.truncation?("end_turn")
    refute @manager.truncation?(nil)
  end

  def test_classify_truncation_scenarios
    # 1. Thinking exhausted: no tools, empty text
    assert_equal :thinking_exhausted, @manager.classify_truncation("", [])
    assert_equal :thinking_exhausted, @manager.classify_truncation("   ", [])

    # 2. Text truncated: no tools, non-empty text
    assert_equal :text_truncated, @manager.classify_truncation("def foo\n  bar = 1", [])

    # 3. Tool truncated: tool calls present (partial or broken)
    assert_equal :tool_truncated, @manager.classify_truncation("", [{ "tool" => "read_file" }])
  end

  def test_handle_truncation_thinking_exhausted
    action = @manager.handle_truncation(
      finish_reason: "length",
      text_resp: "",
      tool_calls: [],
      max_tokens: 4096
    )

    assert action[:continue]
    assert_equal :thinking_exhausted, action[:scenario]
    assert_includes action[:nudge], "thinking process reached the output token limit"
    assert_equal 1, @manager.auto_continue_count
    assert_equal 1, action[:step_event][:count]
    assert_equal 3, action[:step_event][:max]
  end

  def test_handle_truncation_text_truncated_buffers_and_nudges
    action = @manager.handle_truncation(
      finish_reason: "length",
      text_resp: "Part 1 of the answer...",
      tool_calls: [],
      max_tokens: 4096
    )

    assert action[:continue]
    assert_equal :text_truncated, action[:scenario]
    assert_equal "Part 1 of the answer...", @manager.continuation_buffer
    assert_includes action[:nudge], "Continue directly and seamlessly"
  end

  # Issue #595-1 follow-up: absorb matches only rows anchored to their own
  # continuation nudge — an unrelated earlier assistant row that coincidentally
  # repeats a partial verbatim must survive.
  def test_absorb_partial_rows_spares_unrelated_identical_assistant_row
    @manager.handle_truncation(
      finish_reason: "length",
      text_resp: "dup content",
      tool_calls: [],
      max_tokens: 4096
    )

    history = [
      { role: "assistant", content: "dup content" },
      { role: "user", content: "an unrelated later user row" },
      { role: "assistant", content: "dup content" },
      { role: "user", content: "Your previous response was cut off because it reached the output token limit. Continue." }
    ]
    @manager.absorb_partial_rows!(history)

    assert_equal 1, history.count { |r| r.is_a?(Hash) && r[:content] == "dup content" },
                 "only the nudge-anchored partial row is absorbed"
    assert_equal "an unrelated later user row", history[1][:content], "history keeps its shape"
  end

  def test_stitch_and_reset
    @manager.handle_truncation(
      finish_reason: "length",
      text_resp: "First half of text ",
      tool_calls: [],
      max_tokens: 4096
    )

    stitched = @manager.stitch_and_reset("and second half.")
    assert_equal "First half of text and second half.", stitched
    assert_equal 0, @manager.auto_continue_count
    assert_empty @manager.continuation_buffer
  end

  def test_reset_strikes_preserves_the_continuation_buffer
    @manager.handle_truncation(
      finish_reason: "length", text_resp: "thinking cut off", tool_calls: [], max_tokens: 4096
    )
    @manager.handle_truncation(
      finish_reason: "length", text_resp: "partial text ", tool_calls: [], max_tokens: 4096
    )
    assert_equal 2, @manager.auto_continue_count

    @manager.reset_strikes!

    assert_equal 0, @manager.auto_continue_count, "successful turns close the consecutive truncation chain (#549)"
    assert_equal "thinking cut offpartial text ", @manager.continuation_buffer, "the partial answer must survive a strike reset"
  end

  def test_ceiling_enforcement_aborts_with_diagnostic
    3.times do |i|
      action = @manager.handle_truncation(
        finish_reason: "length",
        text_resp: "chunk #{i}",
        tool_calls: [],
        max_tokens: 4096
      )
      assert action[:continue]
    end

    # 4th truncation exceeds max_auto_continues (3)
    exceeded = @manager.handle_truncation(
      finish_reason: "length",
      text_resp: "chunk 4",
      tool_calls: [],
      max_tokens: 4096
    )

    refute exceeded[:continue]
    assert_includes exceeded[:error], "3 automatic continue attempts were exhausted, so it was stopped"
    assert_includes exceeded[:error], "!config set llm.default_max_output_tokens 8192"
  end

  def test_disabled_auto_continue_returns_diagnostic_immediately
    disabled_mgr = Rubik::Orchestrator::ContinuationManager.new(
      config: { "llm" => { "auto_continue_on_length" => false } }
    )

    res = disabled_mgr.handle_truncation(
      finish_reason: "length",
      text_resp: "",
      tool_calls: [],
      max_tokens: 2048
    )

    refute res[:continue]
    assert_includes res[:error], "reached the maximum token limit (max_output_tokens: 2048) and was cut off before completion"
    assert_includes res[:error], "!config set llm.default_max_output_tokens 4096"
  end
end
