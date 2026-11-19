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
    assert_includes res1, "must provide at least 2 distinct non-empty selectable options"

    res2 = @tool.execute("questions" => [{ "question" => "Q1", "options" => [] }])
    assert res2.error?
    assert_includes res2, "must provide at least 2 distinct non-empty selectable options"
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
    assert_includes res, "User response (custom write-in): custom_postgres_cluster"
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

  def test_cancellation_aborts_subsequent_questions
    call_count = 0
    mock_dialog = Class.new do
      define_method(:interactive?) { true }
      define_method(:ask_single) do |_question, _options|
        call_count += 1
        :cancelled
      end
    end.new

    tool = Rubik::Tools::AskQuestionTool.new(dialog: mock_dialog)
    res = tool.execute(
      "questions" => [
        { "question" => "Question 1?", "options" => ["A", "B"] },
        { "question" => "Question 2?", "options" => ["C", "D"] }
      ]
    )

    refute res.error?
    assert_equal 1, call_count, "Second question must not be prompted when first is cancelled"
    assert_includes res, "User cancelled question prompt without selection: \"Question 1?\""
    refute_includes res, "Question 2?"
  end

  def test_top_level_single_question_shorthand
    res = @tool.execute(
      "question" => "Direct question?",
      "options" => ["Direct A", "Direct B"]
    )
    refute res.error?
    assert_includes res, "automatically selected 'Direct A'"
  end

  def test_validates_distinct_options_count
    res = @tool.execute(
      "questions" => [
        { "question" => "Duplicate choices?", "options" => ["Same", "Same", "  Same  "] }
      ]
    )
    assert res.error?
    assert_includes res.to_s, "must provide at least 2 distinct non-empty selectable options"
  end

  def test_validates_question_item_must_be_hash
    res = @tool.execute(
      "questions" => ["What is your choice?"]
    )
    assert res.error?
    assert_includes res.to_s, "item must be an object with 'question' and 'options' properties"
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

  def test_ui_dialog_custom_write_in_formats_prefix
    mock_prompt = Class.new do
      def select(_msg, _choices, _opts = {})
        "Other (write-in response)"
      end

      def ask(_msg)
        "my_custom_value"
      end
    end.new

    dialog = Rubik::UI::Dialog.new(prompt: mock_prompt)
    single_ans = dialog.ask_single("Test Question", ["Option 1", "Option 2"])
    assert_equal "Other (write-in): my_custom_value", single_ans
  end

  def test_ui_dialog_empty_multi_select_returns_no_selection
    mock_prompt = Class.new do
      def select(_msg, _choices, _opts = {})
        "Option 1"
      end

      def multi_select(_msg, _choices, _opts = {})
        []
      end
    end.new

    dialog = Rubik::UI::Dialog.new(prompt: mock_prompt)
    assert_equal [], dialog.ask_multi("Pick", ["Option 1", "Option 2"])
  end

  def test_ui_dialog_empty_write_in_returns_no_selection
    mock_prompt = Class.new do
      def select(_msg, _choices, _opts = {})
        "Other (write-in response)"
      end

      def ask(_msg)
        "   "
      end
    end.new

    dialog = Rubik::UI::Dialog.new(prompt: mock_prompt)
    assert_nil dialog.ask_single("Pick", ["Option 1", "Option 2"])
  end

  # Issue #592: question text and options are model-controlled; escapes must
  # be stripped before they reach the dialog card or the echoed response.
  def test_question_text_and_options_strip_ansi_escapes
    res = @tool.execute(
      "questions" => [
        {
          "question" => "\e]0;title hijack\aWhich DB?\e[2J",
          "options" => ["PostgreSQL", "\e[31mSQLite\e[0m"]
        }
      ]
    )
    refute res.error?
    text = res.to_s
    refute_includes text, "\e]0;"
    refute_includes text, "\e[2J"
    refute_includes text, "\e[31m"
    assert_includes text, "Which DB?"

    # Options are stripped at validation, before any rendering path.
    parsed = @tool.send(:validate_question,
                        { "question" => "Q", "options" => ["\e[31mSQLite\e[0m", "Postgres"] }, index: 1)
    assert_equal ["SQLite", "Postgres"], parsed[:options]
  end

  def test_dialog_render_card_strips_ansi_escapes
    out = StringIO.new
    shell = Struct.new(:output, :input).new(out, StringIO.new)
    dialog = Rubik::UI::Dialog.new(shell: shell, theme: Rubik::UI::Theme.new(enabled: false))

    dialog.send(:render_card, "\e]0;title hijack\aPick one\e[2J")

    card = out.string
    refute_includes card, "\e]0;"
    refute_includes card, "\e[2J"
    assert_includes card, "Pick one"
    assert_includes card, "Single-Select", "the subtitle renders next to the sanitized question"
  end

  # Multi-select path (#592): the subtitle-bearing card must sanitize the
  # model-authored question exactly like the single-select path.
  def test_dialog_render_card_multi_path_strips_ansi_escapes
    out = StringIO.new
    shell = Struct.new(:output, :input).new(out, StringIO.new)
    dialog = Rubik::UI::Dialog.new(shell: shell, theme: Rubik::UI::Theme.new(enabled: false))

    dialog.send(:render_card, "\e]0;title hijack\aPick many\e[2J", multi: true)

    card = out.string
    refute_includes card, "\e]0;"
    refute_includes card, "\e[2J"
    assert_includes card, "Pick many"
    assert_includes card, "Multi-Select", "the subtitle renders next to the sanitized question"
  end
end
