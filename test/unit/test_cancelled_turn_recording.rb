# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestCancelledTurnRecording < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_cancel_test")
    @temp_home = Dir.mktmpdir("rubik_cancel_home")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    @output = StringIO.new
    @shell = Rubik::REPL::Shell.new(config: @config, output: @output, root_dir: @temp_dir)
  end

  def teardown
    @shell&.stop
    FileUtils.remove_entry(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
    FileUtils.remove_entry(@temp_home) if @temp_home && File.exist?(@temp_home)
  end

  def test_interrupt_during_llm_turn_records_cancellation_event
    interrupting_provider = Object.new
    interrupting_provider.define_singleton_method(:complete) { |_msgs, _opts = {}| raise Interrupt }

    mock_router = Object.new
    mock_router.define_singleton_method(:route) do |*_a, **_kw|
      { role: "default", model: "m", provider: interrupting_provider,
        context_limit: 4096, max_output_tokens: 1024 }
    end
    @shell.instance_variable_set(:@router, mock_router)

    long_text = "Analyze the whole codebase and refactor everything " * 10
    @shell.execute_free_text(long_text)

    assert_includes @output.string, "iptal edildi"
    events = @shell.recorder.events
    cancel_event = events.reverse.find { |e| e["type"] == "cancelled_turn" }
    refute_nil cancel_event, "cancellation must be recorded"
    assert_equal "Interrupted by user (^C)", cancel_event["payload"]["reason"]
    assert_equal long_text.strip[0, 80], cancel_event["payload"]["question"]
    # The user turn itself must also be present (recorded at method entry)
    assert events.any? { |e| e["type"] == "user_turn" }
  end

  def test_cancelled_turn_event_is_not_hydrated_as_dialogue_on_restore
    # restore_session must ignore the dedicated cancelled_turn type: the
    # question is already carried by the user_turn event, and hydrating the
    # cancellation as a repl_command-style pair would duplicate it.
    @shell.recorder.record_user_turn("what went wrong?")
    @shell.recorder.record("cancelled_turn",
                           "question" => "what went wrong?",
                           "reason" => "Interrupted by user (^C)")

    target = Rubik::REPL::Shell.new(config: @config, output: StringIO.new, root_dir: @temp_dir)
    begin
      res = Rubik::Session::Manager.restore_session(target, @shell.recorder.session_file)
      assert res[:ok]
      assert_equal 1, target.conversation_history.size,
                   "cancelled_turn must not hydrate extra dialogue turns"
      assert_equal "user", target.conversation_history.first[:role]
      assert_equal "what went wrong?", target.conversation_history.first[:content]
    ensure
      target&.stop
    end
  end
end
