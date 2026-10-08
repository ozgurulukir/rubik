# frozen_string_literal: true

require_relative "../test_helper"

# THE subagent conversation-id vocabulary (arch-deepening 2026-10-08 #8):
# the B5 parse-side dialect grammar single-homed out of
# ManageSubagentsTool, plus the ROOT_ID / root recipient aliases that were
# an 8-site "agent-0" literal hunt.
class TestSubagentConversationId < Minitest::Test
  ConversationId = Rubik::Orchestrator::Subagent::ConversationId

  def test_root_id_and_aliases
    assert_equal "agent-0", ConversationId::ROOT_ID
    assert_equal ["agent-0", "init-0", "root", "parent"], ConversationId::ROOT_ALIASES
    assert ConversationId::ROOT_ALIASES.frozen?
  end

  def test_root_alias_check_is_case_insensitive_and_quote_tolerant
    assert ConversationId.root_alias?("agent-0")
    assert ConversationId.root_alias?("INIT-0")
    assert ConversationId.root_alias?("'Root'")
    assert ConversationId.root_alias?(" Parent ")
    refute ConversationId.root_alias?("subagent-5")
    refute ConversationId.root_alias?(nil)
  end

  def test_scrub_strips_whitespace_and_wrapping_quotes
    assert_equal "subagent-5", ConversationId.scrub("  subagent-5  ")
    assert_equal "subagent-5", ConversationId.scrub("'subagent-5'")
    assert_equal "subagent-5", ConversationId.scrub('"subagent-5"')
    assert_equal "5", ConversationId.scrub(5)
  end

  def test_normalize_list_accepts_a_real_array
    assert_equal ["subagent-5", "subagent-6"], ConversationId.normalize_list(["subagent-5", "subagent-6"])
  end

  def test_normalize_list_accepts_a_json_array_string
    assert_equal ["subagent-5", "subagent-6"], ConversationId.normalize_list('["subagent-5", "subagent-6"]')
  end

  def test_normalize_list_accepts_a_comma_list
    assert_equal ["subagent-5", "subagent-6"], ConversationId.normalize_list("subagent-5, subagent-6")
  end

  def test_normalize_list_accepts_single_and_quoted_ids
    assert_equal ["subagent-5"], ConversationId.normalize_list("subagent-5")
    assert_equal ["subagent-5"], ConversationId.normalize_list("'subagent-5'")
  end

  def test_normalize_list_drops_empties_and_handles_non_id_raw
    assert_equal [], ConversationId.normalize_list(nil)
    assert_equal [], ConversationId.normalize_list("  ,  ")
    assert_equal ["5"], ConversationId.normalize_list(5)
    assert_equal ["subagent-5", "subagent-6"], ConversationId.normalize_list(["subagent-5", nil, ["subagent-6"]])
  end

  def test_parse_internals_stay_private
    refute ConversationId.respond_to?(:parse_id_string)
    refute ConversationId.respond_to?(:safe_json_array)
  end
end
