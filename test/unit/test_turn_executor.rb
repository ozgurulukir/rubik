# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/orchestrator/turn_executor"
require "rubik/orchestrator/turn_executor/user_channel"

# User-channel scenarios for the shared TurnExecutor spine (the
# agent-turn-executor plan): one provider response → history mutations →
# (nudge | final text | tool dispatch) → turn decision, driven through the
# same seam the production step loop uses (Loop#turn_executor).
class TestTurnExecutor < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_turn_executor_test")
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @registry = Rubik::Tools::Registry.new
    @registry.register(Rubik::Tools::ReadFileTool.new(@buffer_manager))
    @registry.register(Rubik::Tools::WriteFileTool.new(@buffer_manager))
    @registry.register(Rubik::Tools::FinishTool.new)

    @events = []
    @loop = Rubik::Orchestrator::Loop.new(
      provider: Object.new,
      tool_registry: @registry,
      max_steps: 10,
      on_step: ->(event) { @events << event },
      context_limit: 16_000,
      max_output_tokens: 2_000
    )
    @executor = @loop.turn_executor
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
  end

  def response(text:, raw: nil, thought: nil, tool_calls: nil)
    Rubik::LLM::Response.new(text: text, raw: raw, thought: thought, tool_calls: tool_calls)
  end

  def history_roles
    @loop.history.map { |m| m[:role] }
  end

  def test_empty_response_nudges_once_then_fails_on_second_strike
    first = @executor.call(response(text: ""))
    assert_nil first, "one empty response must nudge and continue"

    nudge = @loop.history.last
    assert_equal "user", nudge[:role]
    assert_equal "Your last response was empty. Continue the task or call the finish tool.", nudge[:content]
    assert_equal 1, @loop.empty_response_count

    terminal = @executor.call(response(text: ""))
    refute terminal[:ok]
    assert_equal "Empty response from model", terminal[:error]
    assert_equal 2, @loop.empty_response_count
  end

  def test_thought_only_empty_response_uses_the_reasoning_aware_nudge_text
    result = @executor.call(response(text: "", thought: "I planned everything but called nothing."))

    assert_nil result
    nudge = @loop.history.last
    assert_equal "Your reasoning was completed, but no action or final response was provided. " \
                 "Please call a tool or provide your final output.", nudge[:content]
  end

  def test_text_only_response_completes_the_turn_with_stitched_output
    @loop.continuation_manager.instance_variable_set(:@continuation_buffer, +"The first half. ")
    result = @executor.call(response(text: "The second half."))

    assert result[:ok]
    assert_equal "The first half. The second half.", result[:output]
    assert_equal "assistant", history_roles.last
    assert_equal 0, @loop.continuation_manager.continuation_buffer.length

    message_event = @events.find { |e| e[:type] == :message }
    refute_nil message_event
    assert_equal "The first half. The second half.", message_event[:content]
  end

  def test_truncation_with_auto_continue_appends_thought_row_and_nudge_then_continues
    res = response(
      text: "",
      raw: { "finish_reason" => "length" },
      thought: "Deep reasoning was cut off..."
    )

    result = @executor.call(res)

    assert_nil result
    assert_equal ["assistant", "user"], history_roles
    assert_equal "Deep reasoning was cut off...", @loop.history.first[:thought]
    assert_includes @loop.history.last[:content], "thinking process reached the output token limit"

    continue_event = @events.find { |e| e[:type] == :auto_continue }
    refute_nil continue_event
    assert_equal :thinking_exhausted, continue_event[:reason]
  end

  def test_truncation_past_ceiling_returns_the_diagnostic_error
    @loop.continuation_manager.instance_variable_set(:@auto_continue_count, 3)

    result = @executor.call(response(text: "Still cutting off...", raw: { "finish_reason" => "length" }))

    refute result[:ok]
    assert_includes result[:error], "3 otomatik devam denemesi tükendiği için durduruldu"
    error_event = @events.find { |e| e[:type] == :error }
    refute_nil error_event
  end

  def test_finish_is_detected_through_the_registry_not_raw_name_comparison
    result = @executor.call(response(text: '{"tool": "finish", "args": { "message": "wrapped up" }}'))

    assert result[:ok]
    assert_equal "wrapped up", result[:output]
    refute @loop.history.any? { |m| m[:role] == "tool" }, "the finish call executes, no tool result row lands"
    assert_nil @events.find { |e| e[:type] == :llm_thought }, "finish calls announce no llm_thought"
  end

  def test_json_tool_call_in_text_executes_when_native_calls_are_absent
    File.write(File.join(@temp_dir, "note.txt"), "hello")
    @loop.instance_variable_set(:@step_count, 1)
    result = @executor.call(response(text: '```json\n{"tool": "read_file", "args": {"path": "note.txt"}}\n```'))

    assert_nil result, "a tool-call turn continues the loop"
    tool_row = @loop.history.find { |m| m[:role] == "tool" }
    refute_nil tool_row
    assert_includes tool_row[:content], "hello"
    assert_equal "read_file", tool_row[:tool_name]
    assert tool_row[:tool_call_id].start_with?("call_1_1_"), "the loop channel mints unique step-indexed ids"
    assert_equal :ok, tool_row[:status]
  end

  def test_malformed_string_args_echo_the_rejected_payload_without_dispatch
    # Model-controlled fallback text with non-JSON string args must not
    # raise into the step loop NOR dispatch degraded {} args (issue #55
    # 3.4): the canonical error row quotes the rejected payload so the
    # retry targets the real cause instead of a downstream
    # missing-parameter or guard error.
    result = @executor.call(response(text: '{"tool": "read_file", "args": "note.txt"}'))

    assert_nil result, "the turn continues — a malformed arg is a wasted step, not a crash"
    tool_row = @loop.history.find { |m| m[:role] == "tool" }
    refute_nil tool_row
    assert_equal :error, tool_row[:status]
    assert_equal "read_file", tool_row[:tool_name]
    assert_includes tool_row[:content], "Malformed tool call"
    assert_includes tool_row[:content], "note.txt", "the rejected payload is echoed back to the model"
  end

  def test_valid_json_non_object_args_take_the_same_malformed_row
    # A valid-JSON non-object (array at the args position) is equally
    # undecodable as tool arguments: same canonical row, no dispatch.
    result = @executor.call(response(text: '{"tool": "read_file", "args": [1, 2]}'))

    assert_nil result
    tool_row = @loop.history.find { |m| m[:role] == "tool" }
    assert_equal :error, tool_row[:status]
    assert_includes tool_row[:content], "[1, 2]"
  end

  def test_valid_json_object_string_args_still_dispatch_normally
    File.write(File.join(@temp_dir, "note.txt"), "hello")
    @loop.instance_variable_set(:@step_count, 1)
    result = @executor.call(
      response(text: "", tool_calls: [{ "tool" => "read_file", "args" => "{\"path\": \"note.txt\"}" }])
    )

    assert_nil result, "string-encoded but valid JSON args must reach the tool"
    tool_row = @loop.history.find { |m| m[:role] == "tool" }
    assert_equal :ok, tool_row[:status]
    assert_includes tool_row[:content], "hello"
  end

  def test_malformed_args_with_invalid_utf8_bytes_bounded_not_fatal
    # JSON.parse tolerates invalid bytes inside string values, so a
    # degraded provider echo can deliver args carrying them. The fragment
    # must scrub, not raise (the old degrade-to-{} contract: a malformed
    # arg is one wasted step, never a killed turn).
    result = @executor.call(response(text: "{\"tool\": \"read_file\", \"args\": \"note\xFF.txt\"}"))

    assert_nil result, "the turn continues"
    tool_row = @loop.history.find { |m| m[:role] == "tool" }
    assert_equal :error, tool_row[:status]
    assert_includes tool_row[:content], "Malformed tool call"
  end

  def test_provider_attached_malformed_marker_takes_the_error_row
    # Batch providers degrade unparsable args to {} at parse time and
    # attach the rejected payload as "malformed_args" — the executor must
    # honor that marker instead of dispatching the degraded {}.
    result = @executor.call(
      response(text: "", tool_calls: [{ "id" => "x1", "tool" => "read_file", "args" => {}, "malformed_args" => '{"trunc' }])
    )

    assert_nil result
    tool_row = @loop.history.find { |m| m[:role] == "tool" }
    assert_equal :error, tool_row[:status]
    assert_includes tool_row[:content], "Malformed tool call"
    assert_includes tool_row[:content], '{"trunc'
  end

  def test_degenerate_json_fences_degrade_to_no_tool_call
    # A bare "```json" opener, an empty fence, and a valid-JSON non-object
    # previously raised NoMethodError/TypeError out of the fallback parse;
    # each must now degrade to plain text output.
    ["```json", "```json```", "```json\n[1,2]\n```"].each do |degenerate|
      result = @executor.call(response(text: degenerate))

      assert result[:ok], "#{degenerate.inspect} must complete as plain text, not crash"
      assert_equal degenerate, result[:output]
      assert_empty(@loop.history.select { |m| m[:role] == "tool" })
    end
  end

  def test_native_tool_calls_are_normalized_with_minted_ids_before_dispatch
    File.write(File.join(@temp_dir, "note.txt"), "native")
    @loop.instance_variable_set(:@step_count, 3)
    result = @executor.call(response(text: "", tool_calls: [{ "tool" => "read_file", "args" => { "path" => "note.txt" } }]))

    assert_nil result
    assistant_row = @loop.history.find { |m| m[:role] == "assistant" }
    assert_equal 1, assistant_row[:tool_calls].size
    assert assistant_row[:tool_calls].first["id"].start_with?("call_3_1_"),
           "every native call carries a persistent call_ id before dispatch"
    assert_equal "read_file", assistant_row[:tool_calls].first["tool"]
  end

  def test_plan_mode_executes_no_tool_calls_and_nudges_toward_a_text_plan
    result = @executor.call(response(text: '```json\n{"tool": "write_file", "args": {"path": "evil.rb"}}\n```'), plan_only: true)

    assert result[:ok], "plan mode accepts the (non-executed) text as the plan"
    assert_includes result[:output], "write_file"
    assert_empty @loop.history.select { |m| m[:role] == "tool" }, "plan mode must never write tool rows"
    refute File.exist?(File.join(@temp_dir, "evil.rb"))
  end

  def test_emergency_compact_announces_on_the_channel_event_with_layer
    @loop.instance_variable_set(:@step_count, 2)
    @loop.history << { role: "system", content: "sys" }
    @loop.history << { role: "user", content: "very long " * 100 }

    layer = @executor.emergency_compact!("turn executor overflow")

    event = @events.find { |e| e[:type] == :emergency_compact }
    refute_nil event
    assert_equal "turn executor overflow", event[:reason]
    assert_equal layer, event[:layer]
    assert_equal 2, event[:step]
    assert_equal 10, event[:max_steps]
  end
end
