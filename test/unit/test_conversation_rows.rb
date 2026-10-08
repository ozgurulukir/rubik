# frozen_string_literal: true

require_relative "../test_helper"

# The conversation-row wire dialect SSOT (arch-deepening 2026-10-08 #7):
# symbol/string key probes and the notice-merge policy that was previously
# duplicated byte-level in Loop and the REPL lifecycle injector.
class TestConversationRows < Minitest::Test
  Rows = Rubik::Prompt::ConversationRows

  def test_appends_to_a_trailing_symbol_key_user_row
    history = [{ role: "user", content: "original" }]

    result = Rows.append_notice!(history, "NOTICE")

    assert_equal [{ role: "user", content: "original\n\nNOTICE" }], history
    assert_same history, result
  end

  def test_appends_to_a_trailing_string_key_user_row_on_the_string_key
    history = [{ "role" => "user", "content" => "original" }]

    Rows.append_notice!(history, "NOTICE")

    assert_equal [{ "role" => "user", "content" => "original\n\nNOTICE" }], history
  end

  def test_pushes_a_symbol_keyed_user_row_when_trailing_row_is_not_user
    history = [{ role: "assistant", content: "hi" }]

    Rows.append_notice!(history, "NOTICE")

    assert_equal 2, history.size
    assert_equal({ role: "user", content: "NOTICE" }, history.last)
  end

  def test_pushes_when_history_is_empty
    history = []

    Rows.append_notice!(history, "NOTICE")

    assert_equal [{ role: "user", content: "NOTICE" }], history
  end

  def test_symbol_user_role_is_not_a_user_row
    history = [{ role: :user, content: "original" }]

    Rows.append_notice!(history, "NOTICE")

    assert_equal 2, history.size, "exact string equality: :user does not merge"
  end

  def test_empty_or_absent_content_gets_the_payload_directly
    empty = [{ role: "user", content: "" }]
    Rows.append_notice!(empty, "NOTICE")
    assert_equal "NOTICE", empty.last[:content]

    nil_content = [{ role: "user", content: nil }]
    Rows.append_notice!(nil_content, "NOTICE")
    assert_equal "NOTICE", nil_content.last[:content]

    absent = [{ "role" => "user" }]
    Rows.append_notice!(absent, "NOTICE")
    assert_equal "NOTICE", absent.last["content"], "absent key resolves to the STRING content key"
  end

  def test_probes
    assert Rows.row?({})
    refute Rows.row?(nil)
    refute Rows.row?([1])

    assert_equal "user", Rows.role_of({ role: "user" })
    assert_equal "user", Rows.role_of({ "role" => "user" })
    assert_equal "", Rows.role_of({})
    assert_equal "sym", Rows.role_of({ role: :sym })

    assert_equal "body", Rows.content_of({ content: "body" })
    assert_equal "body", Rows.content_of({ "content" => "body" })
    assert_nil Rows.content_of({})

    assert_equal :content, Rows.resolve_key({ content: "x" }, :content)
    assert_equal "content", Rows.resolve_key({ "content" => "x" }, :content)
    assert_equal "content", Rows.resolve_key({}, :content)
    assert_equal :tool_calls, Rows.resolve_key({ tool_calls: [] }, :tool_calls)
  end

  def test_append_notice_requires_an_array
    assert_raises(ArgumentError) { Rows.append_notice!(nil, "x") }
  end
end
