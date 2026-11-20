# frozen_string_literal: true

require_relative "../test_helper"

# Issue #610: a subagent whose report turn is cut off by the output budget
# (finish_reason=length) must be continued, not struck out as "empty".
class TestSubagentChannelTruncation < Minitest::Test
  Resp = Struct.new(:text, :tool_calls, :raw, :thought, keyword_init: true)

  class FakeInstance
    attr_reader :history, :config, :result, :failure, :journal
    attr_accessor :max_output_tokens

    def initialize(config)
      @history = [{ role: "user", content: "write the report" }]
      @config = config
      @max_output_tokens = 100
    end

    def complete_turn!(result) = @result = result
    def fail_turn!(reason) = @failure = reason
  end

  def build(config = {})
    @inst = FakeInstance.new(config)
    channel = Rubik::Orchestrator::TurnExecutor::SubagentChannel.new(@inst)
    Rubik::Orchestrator::TurnExecutor.new(channel: channel)
  end

  def length_resp(text = "", thought: nil)
    Resp.new(text: text, tool_calls: [], raw: { "finish_reason" => "length" }, thought: thought)
  end

  def stop_resp(text)
    Resp.new(text: text, tool_calls: [], raw: { "finish_reason" => "stop" })
  end

  def test_thinking_exhausted_response_is_continued_instead_of_struck_out
    executor = build
    assert_nil executor.call(length_resp("", thought: "pondering"))
    assert_nil executor.call(length_resp("", thought: "pondering more"))
    assert_nil @inst.failure, "two length-truncated empties must not hit the two-strike terminal"
    assert_match(/thinking process reached the output token limit/, @inst.history.last[:content])

    result = executor.call(stop_resp("final report"))
    assert_equal({ ok: true, completed: true }, result)
    assert_equal "final report", @inst.result
  end

  def test_truncated_report_text_is_stitched_into_the_result
    executor = build
    assert_nil executor.call(length_resp("part one, "))
    result = executor.call(stop_resp("part two"))
    assert result[:completed]
    assert_equal "part one, part two", @inst.result
    refute(@inst.history.any? { |m| m[:role] == "assistant" && m[:content] == "part one, " }, "partial row is absorbed")
  end

  def test_exhausted_ceiling_salvages_partial_text
    executor = build("llm" => { "auto_continue_on_length" => false })
    result = executor.call(length_resp("a long report that got cut"))
    assert_equal({ ok: true, completed: true }, result)
    assert_equal "a long report that got cut", @inst.result
    assert_nil @inst.failure
  end

  def test_exhausted_ceiling_without_text_fails_with_diagnostic
    executor = build("llm" => { "auto_continue_on_length" => false })
    result = executor.call(length_resp(""))
    assert_equal({ ok: false, completed: false }, result)
    assert_match(/maximum token limit/, @inst.failure)
  end

  def test_plain_empty_response_still_strikes_twice
    executor = build
    assert_nil executor.call(stop_resp(""))
    assert_equal({ ok: false, completed: false }, executor.call(stop_resp("")))
    assert_match(/Empty response/, @inst.failure)
  end
end
