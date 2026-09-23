# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/orchestrator/tool_call_id"

class TestToolCallId < Minitest::Test
  def test_mint_joins_parts_with_the_call_prefix
    assert_equal "call_3_2", Rubik::Orchestrator::ToolCallId.mint(3, 2)
    assert_equal "call_subagent-2_5_3", Rubik::Orchestrator::ToolCallId.mint("subagent-2", 5, 3)
  end

  def test_mint_unique_appends_a_four_digit_suffix
    # Format only — never assert cross-sample uniqueness: rand(1000..9999)
    # over few samples hits the birthday problem and flakes.
    assert_match(/\Acall_3_2_\d{4}\z/, Rubik::Orchestrator::ToolCallId.mint(3, 2, unique: true))
    assert_match(/\Acall_4_\d{4}\z/, Rubik::Orchestrator::ToolCallId.mint(4, unique: true))
  end

  def test_mint_is_byte_compatible_with_the_legacy_step_runner_spelling
    assert_equal "call_subagent-7_3_1", Rubik::Orchestrator::ToolCallId.mint("subagent-7", 3, 1)
  end

  def test_mint_unique_matches_the_legacy_loop_and_executor_shapes
    # call_{step}_{index}_{rand} (Loop) and call_{step}_{rand} (StepExecutor)
    assert_match(/\Acall_12_1_\d{4}\z/, Rubik::Orchestrator::ToolCallId.mint(12, 1, unique: true))
    assert_match(/\Acall_12_\d{4}\z/, Rubik::Orchestrator::ToolCallId.mint(12, unique: true))
  end
end
