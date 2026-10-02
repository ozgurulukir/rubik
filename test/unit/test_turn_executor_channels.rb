# frozen_string_literal: true

require_relative "../test_helper"

# Shared two-channel scenarios (the agent-turn-executor plan): the same
# scripted provider sequence runs through the user channel (full Loop#run)
# and the subagent channel (synchronous step loop), and both must observe
# the shared TurnExecutor invariants — one tool-row dictionary, canonical
# finish detection, per-channel emergency-compaction announce.
class TestTurnExecutorChannels < Minitest::Test
  include Rubik::TestSupport::TurnScenarioHarness

  def setup
    @ws_root = mint_test_root
  end

  def teardown
    remove_temp_dir(@ws_root) if @ws_root
  end

  def tool_call_then_finish
    [
      Rubik::LLM::Response.new(text: "reading the note", tool_calls: [{ "tool" => "read_file", "args" => { "path" => "note.txt" } }]),
      Rubik::LLM::Response.new(text: '{"tool": "finish", "args": { "message": "scenario done" }}')
    ]
  end

  def test_both_channels_write_the_same_six_field_tool_row_for_a_scripted_call
    File.write(File.join(@ws_root, "note.txt"), "shared scenario")
    obs = run_scripted_through_both_channels(root_dir: @ws_root, responses: tool_call_then_finish)

    [obs.user_loop, obs.subagent].each do |channel|
      rows = channel.history.select { |m| m[:role] == "tool" }
      assert_equal 1, rows.size, "exactly one scripted tool row on each channel"
      row = rows.first
      assert_equal Rubik::Orchestrator::ToolHistory::ROW_KEYS, row.keys, "the canonical six-field row on both channels"
      assert_equal "read_file", row[:tool_name]
      assert_equal :ok, row[:status]
      assert_kind_of Float, row[:duration_ms]
      assert row[:tool_call_id].to_s.start_with?("call_"), "channel-minted persistent id"
      assert_includes row[:content], "shared scenario"
    end
  end

  def test_both_channels_canonicalize_finish_through_the_registry
    obs = run_scripted_through_both_channels(root_dir: @ws_root, responses: tool_call_then_finish)

    assert obs.user_result[:ok], "the user channel completes via the finish tool"
    assert_equal :completed, obs.subagent.state, "the subagent completes via the finish tool"
    assert_equal "scenario done", obs.subagent.result
    [obs.user_loop, obs.subagent].each do |channel|
      refute channel.history.any? { |m| m[:role] == "tool" && m[:tool_name] == "finish" },
             "the finish call executes; it never produces a tool result row"
    end
  end

  def test_both_channels_recover_from_context_overflow_via_their_own_announce_channel
    overflow_then_finish = [
      StandardError.new("maximum context length exceeded"),
      Rubik::LLM::Response.new(text: '{"tool": "finish", "args": { "message": "recovered" }}')
    ]
    user_events = []
    user_loop = build_user_loop(root_dir: @ws_root, responses: overflow_then_finish, max_steps: 6, on_step: ->(e) { user_events << e })
    user_loop.run("overflow recovery scenario")

    compact_event = user_events.find { |e| e[:type] == :emergency_compact }
    refute_nil compact_event, "the user channel announces on the on_step :emergency_compact event"
    assert_includes compact_event[:reason], "maximum context length"
    refute_nil compact_event[:layer]

    bus = Rubik::EventBus.new
    compacted_payloads = []
    bus.subscribe(Rubik::Orchestrator::Subagent::Notices::COMPACTED_EVENT) { |p| compacted_payloads << p }
    subagent = build_subagent(root_dir: @ws_root, responses: overflow_then_finish, max_steps: 6)
    subagent.instance_variable_set(:@event_bus, bus)
    subagent.execute_steps_with_provider

    assert_equal 1, compacted_payloads.size, "the subagent channel announces on the bus COMPACTED_EVENT"
    assert_includes compacted_payloads.first[:reason], "maximum context length"
    refute_nil compacted_payloads.first[:layer]
  end

  def test_both_channels_nudge_then_fail_on_repeated_empty_responses
    empty_twice = [Rubik::LLM::Response.new(text: ""), Rubik::LLM::Response.new(text: "")]
    obs = run_scripted_through_both_channels(root_dir: @ws_root, responses: empty_twice)

    user_nudges = obs.user_loop.history.select { |m| m[:role] == "user" && m[:content].include?("Your last response was empty") }
    assert_equal 1, user_nudges.size, "the user channel nudges once, then fails on the second strike"
    refute obs.user_result[:ok]
    assert_equal "Empty response from model", obs.user_result[:error]

    subagent_nudges = obs.subagent.history.select { |m| m[:role] == "user" && m[:content].include?("Your last response was empty") }
    assert_equal 1, subagent_nudges.size, "the subagent channel nudges once, then fails on the second strike"
    assert_equal :failed, obs.subagent.state, "a subagent can no longer complete with an empty result"
    assert_equal "Empty response from model (2 consecutive)", obs.subagent.last_error
  end

  def test_subagent_empty_strike_failure_lands_the_outcome_through_the_real_worker
    # End-to-end: the soft failure (a channel terminal, not an exception)
    # must still run run_execution_cycle's normal-path choreography —
    # state sync and transcript save — not just flip the state flag.
    empty_twice = [Rubik::LLM::Response.new(text: ""), Rubik::LLM::Response.new(text: "")]
    subagent = build_subagent(root_dir: @ws_root, responses: empty_twice, max_steps: 6)
    subagent.start_async

    deadline = Time.now + 5
    sleep 0.02 while !subagent.terminal_and_settled? && Time.now < deadline

    assert_predicate subagent, :failed?
    assert_equal "Empty response from model (2 consecutive)", subagent.last_error
    assert File.exist?(subagent.transcript_uri), "the transcript must be saved on the soft-failure path"
  end

  # =========================================================================
  # Subagent behavior deltas (agent-turn-executor Phase 4)
  # =========================================================================

  def test_subagent_executes_a_json_text_tool_call_without_native_function_calling
    File.write(File.join(@ws_root, "note.txt"), "fallback reached")
    json_text_turn = Rubik::LLM::Response.new(text: '```json\n{"tool": "read_file", "args": {"path": "note.txt"}}\n```')
    obs = run_scripted_through_both_channels(root_dir: @ws_root, responses: [json_text_turn])

    assert_equal :completed, obs.subagent.state
    tool_row = obs.subagent.history.find { |m| m[:role] == "tool" }
    refute_nil tool_row, "the shared normalizer must parse a non-native model's JSON tool reply"
    assert_equal "read_file", tool_row[:tool_name]
    assert_includes tool_row[:content], "fallback reached"
  end

  def test_subagent_finish_via_unregistered_case_variant_is_canonicalized
    # The registry has no "Finish" entry — registry-canonical detection must
    # downcase the unresolved name to finish, not dispatch an unknown tool.
    variant_finish = Rubik::LLM::Response.new(text: '{"tool": "Finish", "args": { "message": "cased finish" }}')
    obs = run_scripted_through_both_channels(root_dir: @ws_root, responses: [variant_finish])

    assert_equal :completed, obs.subagent.state
    assert_equal "cased finish", obs.subagent.result
    assert_empty obs.subagent.history.select { |m| m[:role] == "tool" },
                 "the case variant must not produce an unknown-tool refusal row"
  end

  def test_subagent_json_text_fallback_handles_struct_mock_providers
    # Struct providers expose #content (not #text) and a raw tool_calls
    # array without the Response predicate — the channel adapter must serve
    # both. The first turn's content is a JSON tool call (no native calls).
    json_struct = Struct.new(:content, :tool_calls).new(
      '{"tool": "read_file", "args": {"path": "note.txt"}}', []
    )
    Rubik::Buffer::Manager.new(root_dir: @ws_root)
    File.write(File.join(@ws_root, "note.txt"), "struct fallback")
    inst = Rubik::TestSupport::TurnScenarioHarness.build_subagent(
      root_dir: @ws_root,
      responses: [json_struct, Rubik::LLM::Response.new(text: "done reading")],
      max_steps: 6
    )
    inst.execute_steps_with_provider

    tool_row = inst.history.find { |m| m[:role] == "tool" }
    refute_nil tool_row
    assert_equal "read_file", tool_row[:tool_name]
    assert_equal :ok, tool_row[:status]
    assert_equal :completed, inst.state
  end

  def test_subagent_tool_rows_record_status_and_duration
    File.write(File.join(@ws_root, "note.txt"), "timed row")
    tool_then_finish = [
      Rubik::LLM::Response.new(text: "reading", tool_calls: [{ "tool" => "read_file", "args" => { "path" => "note.txt" } }]),
      Rubik::LLM::Response.new(text: "all read")
    ]
    obs = run_scripted_through_both_channels(root_dir: @ws_root, responses: tool_then_finish)

    row = obs.subagent.history.find { |m| m[:role] == "tool" }
    refute_nil row
    assert_equal :ok, row[:status]
    assert_operator row[:duration_ms], :>=, 0.0
    assert_equal Rubik::Orchestrator::ToolHistory::ROW_KEYS, row.keys

    # An unknown tool records the refusal row as :error (empathetic string
    # preserved; the status field is the new observability signal).
    unknown_then_done = [
      Rubik::LLM::Response.new(text: "", tool_calls: [{ "tool" => "no_such_tool", "args" => {} }]),
      Rubik::LLM::Response.new(text: "giving up")
    ]
    obs2 = run_scripted_through_both_channels(root_dir: @ws_root, responses: unknown_then_done)
    refusal = obs2.subagent.history.find { |m| m[:role] == "tool" }
    assert_equal :error, refusal[:status]
    assert_includes refusal[:content], "is not available in subagent toolset"
  end
end
