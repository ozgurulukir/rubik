# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/orchestrator/tool_history"

# Pins the canonical tool-result history row (agent-turn-executor plan,
# Phase 1): one writer, one six-key shape, no drift between channels.
class TestToolHistory < Minitest::Test
  def test_tool_row_carries_exactly_the_six_canonical_fields
    history = []
    Rubik::Orchestrator::ToolHistory.write(
      history, tool_call_id: "call_1_2", tool_name: "read_file",
               status: :ok, duration_ms: 12.5, content: "<result>ok</result>"
    )

    assert_equal 1, history.size
    row = history.first
    assert_equal ["role", "tool_call_id", "tool_name", "status", "duration_ms", "content"].sort, row.keys.map(&:to_s).sort
    assert_equal "tool", row[:role]
    assert_equal "call_1_2", row[:tool_call_id]
    assert_equal "read_file", row[:tool_name]
    assert_equal :ok, row[:status]
    assert_equal 12.5, row[:duration_ms]
    assert_equal "<result>ok</result>", row[:content]
  end

  def test_row_fields_pass_through_unmodified_to_history
    history = []
    row = Rubik::Orchestrator::ToolHistory.write(
      history, tool_call_id: "call_x", tool_name: "run_command",
               status: :error, duration_ms: 0.0, content: "boom"
    )

    assert_same history.first, row
    assert_equal({ role: "tool", tool_call_id: "call_x", tool_name: "run_command",
                   status: :error, duration_ms: 0.0, content: "boom" }, row)
    assert_equal Rubik::Orchestrator::ToolHistory::ROW_KEYS, [:role, :tool_call_id, :tool_name, :status, :duration_ms, :content]
  end
end
