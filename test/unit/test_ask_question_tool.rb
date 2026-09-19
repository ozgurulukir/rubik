# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/tools/builtins/interactive"
require_relative "../../lib/rubik/ui/dialog"

class TestAskQuestionTool < Minitest::Test
  def setup
    @tool = Rubik::Tools::AskQuestionTool.new
  end

  def test_tool_metadata_and_schema
    assert_equal "ask_question", @tool.name
    assert_equal :read, @tool.risk
    assert_includes @tool.aliases, "ask"
    assert_includes @tool.aliases, "question"

    schema = @tool.params_schema
    assert_equal "object", schema[:type]
    assert_equal ["questions"], schema[:required]
  end

  def test_validates_missing_or_empty_questions
    res1 = @tool.execute({})
    assert res1.error?
    assert_includes res1, "Missing required parameter: questions"

    res2 = @tool.execute("questions" => [])
    assert res2.error?
    assert_includes res2, "Missing required parameter: questions"
  end

  def test_validates_blank_question_text
    res = @tool.execute("questions" => [{ "question" => "   ", "options" => ["A", "B"] }])
    assert res.error?
    assert_includes res, "question text cannot be blank"
  end

  def test_validates_minimum_two_options
    res1 = @tool.execute("questions" => [{ "question" => "Q1", "options" => ["Only One"] }])
    assert res1.error?
    assert_includes res1, "must provide at least 2 non-empty selectable options"

    res2 = @tool.execute("questions" => [{ "question" => "Q1", "options" => [] }])
    assert res2.error?
    assert_includes res2, "must provide at least 2 non-empty selectable options"
  end

  def test_non_interactive_fallback_auto_selects_first_option
    res = @tool.execute(
      "questions" => [
        { "question" => "Which DB to use?", "options" => ["PostgreSQL", "SQLite"] }
      ]
    )
    refute res.error?
    assert_includes res, "automatically selected 'PostgreSQL'"
    assert_includes res, "Non-interactive session"
  end

  def test_non_interactive_fallback_prefers_recommended_option
    res = @tool.execute(
      "questions" => [
        {
          "question" => "Which format to export?",
          "options" => ["JSON", "(Recommended) YAML", "XML"]
        }
      ]
    )
    refute res.error?
    assert_includes res, "automatically selected '(Recommended) YAML'"
  end

  def test_non_interactive_fallback_multi_select
    res = @tool.execute(
      "questions" => [
        {
          "question" => "Select components to test",
          "options" => ["(Recommended) Unit", "Integration"],
          "is_multi_select" => true
        }
      ]
    )
    refute res.error?
    assert_includes res, 'automatically selected \'["(Recommended) Unit"]\''
  end

  def test_interactive_single_select_with_mock_dialog
    mock_dialog = Class.new do
      def interactive?
        true
      end

      def ask_single(_question, _options)
        "PostgreSQL"
      end
    end.new

    tool = Rubik::Tools::AskQuestionTool.new(dialog: mock_dialog)
    res = tool.execute(
      "questions" => [
        { "question" => "Which database?", "options" => ["PostgreSQL", "SQLite"] }
      ]
    )

    refute res.error?
    assert_equal "Question: \"Which database?\"\nUser response: PostgreSQL", res.to_s
  end

  def test_interactive_multi_select_with_mock_dialog
    mock_dialog = Class.new do
      def interactive?
        true
      end

      def ask_multi(_question, _options)
        ["PostgreSQL", "Redis"]
      end
    end.new

    tool = Rubik::Tools::AskQuestionTool.new(dialog: mock_dialog)
    res = tool.execute(
      "questions" => [
        { "question" => "Select storage backends", "options" => ["PostgreSQL", "Redis", "SQLite"], "is_multi_select" => true }
      ]
    )

    refute res.error?
    assert_equal "Question: \"Select storage backends\"\nUser response: [\"PostgreSQL\", \"Redis\"]", res.to_s
  end

  def test_interactive_custom_write_in_response
    mock_dialog = Class.new do
      def interactive?
        true
      end

      def ask_single(_question, _options)
        "Other (write-in): custom_postgres_cluster"
      end
    end.new

    tool = Rubik::Tools::AskQuestionTool.new(dialog: mock_dialog)
    res = tool.execute(
      "questions" => [
        { "question" => "Choose database", "options" => ["PostgreSQL", "SQLite"] }
      ]
    )

    refute res.error?
    assert_includes res, "User response (custom write-in): Other (write-in): custom_postgres_cluster"
  end

  def test_interactive_cancellation
    mock_dialog = Class.new do
      def interactive?
        true
      end

      def ask_single(_question, _options)
        :cancelled
      end
    end.new

    tool = Rubik::Tools::AskQuestionTool.new(dialog: mock_dialog)
    res = tool.execute(
      "questions" => [
        { "question" => "Choose database", "options" => ["PostgreSQL", "SQLite"] }
      ]
    )

    refute res.error?
    assert_includes res, "User cancelled question prompt without selection"
  end

  def test_ui_dialog_with_mock_tty_prompt
    mock_prompt = Class.new do
      def select(_msg, _choices, _opts = {})
        "Option 2"
      end

      def multi_select(_msg, _choices, _opts = {})
        ["Option 1", "Option 2"]
      end
    end.new

    dialog = Rubik::UI::Dialog.new(prompt: mock_prompt)
    assert dialog.interactive?

    single_ans = dialog.ask_single("Test Question", ["Option 1", "Option 2"])
    assert_equal "Option 2", single_ans

    multi_ans = dialog.ask_multi("Test Multi Question", ["Option 1", "Option 2"])
    assert_equal ["Option 1", "Option 2"], multi_ans
  end
end
