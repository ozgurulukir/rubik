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
end
