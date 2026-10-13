# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/orchestrator/tool_history"

# Pins the canonical tool-result history row (agent-turn-executor plan,
# Phase 1; issue #127 added the structured command-outcome fields):
# one writer, one canonical shape, no drift between channels.
class TestToolHistory < Minitest::Test
  def test_tool_row_carries_exactly_the_canonical_fields
    history = []
    Rubik::Orchestrator::ToolHistory.write(
      history, tool_call_id: "call_1_2", tool_name: "read_file",
               status: :ok, duration_ms: 12.5, content: "<result>ok</result>"
    )

    assert_equal 1, history.size
    row = history.first
    assert_equal ["role", "tool_call_id", "tool_name", "status", "duration_ms", "content", "exit_code", "metadata"].sort,
                 row.keys.map(&:to_s).sort
    assert_equal "tool", row[:role]
    assert_equal "call_1_2", row[:tool_call_id]
    assert_equal "read_file", row[:tool_name]
    assert_equal :ok, row[:status]
    assert_equal 12.5, row[:duration_ms]
    assert_equal "<result>ok</result>", row[:content]
    assert_nil row[:exit_code], "tools without a process outcome leave the exit code nil"
    assert_equal({}, row[:metadata])
  end

  def test_structured_command_outcome_rides_the_canonical_row
    history = []
    row = Rubik::Orchestrator::ToolHistory.write(
      history, tool_call_id: "call_x", tool_name: "run_command",
               status: :error, duration_ms: 0.0, content: "[EXIT 3] boom",
               exit_code: 3, metadata: { "executed" => true, "timed_out" => false }
    )

    assert_same history.first, row
    assert_equal 3, row[:exit_code]
    assert_equal({ "executed" => true, "timed_out" => false }, row[:metadata])
    assert_equal Rubik::Orchestrator::ToolHistory::ROW_KEYS,
                 [:role, :tool_call_id, :tool_name, :status, :duration_ms, :content, :exit_code, :metadata]
  end
end
