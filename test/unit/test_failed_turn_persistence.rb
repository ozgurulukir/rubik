# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Plan 61 D-2: every turn — success, failure, cancel, budget exhaustion —
# must leave a user/assistant pair in the conversation window AND a
# recorder entry, so the model keeps the thread and !resume restores it.
# Previously only successful turns were recorded (root cause of "the LLM
# does not remember what happened").
class TestFailedTurnPersistence < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_fail_turn")
    @temp_home = Dir.mktmpdir("rubik_fail_home")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    @output = StringIO.new
    @shell = Rubik::REPL::Shell.new(config: @config, output: @output, root_dir: @temp_dir)
  end

  def teardown
    @shell&.stop
    FileUtils.remove_entry(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
    FileUtils.remove_entry(@temp_home) if @temp_home && File.exist?(@temp_home)
  end

  def stub_router!(provider)
    router = Object.new
    router.define_singleton_method(:route) do |*_a, **_kw|
      { role: "default", model: "mock-1", provider: provider,
        spec: { "provider" => "mock", "name" => "test" },
        context_limit: 32_768, max_output_tokens: 4_096 }
    end
    @shell.instance_variable_set(:@router, router)
  end

  def test_llm_error_turn_is_recorded_with_tagged_trace
    err_provider = Object.new
    err_provider.define_singleton_method(:complete) { |_msgs, _opts = {}| raise Rubik::LLM::ClientError, "HTTP Request failed with code 500" }
    stub_router!(err_provider)

    @shell.execute_free_text("why did the build fail?")

    hist = @shell.conversation_history
    assert_equal 2, hist.size, "failed turn must still leave a user/assistant pair"
    assert_equal "user", hist[0][:role]
    assert_equal "why did the build fail?", hist[0][:content]
    assert_equal "assistant", hist[1][:role]
    assert_includes hist[1][:content], "[Turn failed:"
    assert_includes hist[1][:content], "HTTP Request failed with code 500"
    assert @shell.recorder.events.any? { |e| e["type"] == "assistant_response" }, "recorder must persist the failure trace"
  end

  def test_interrupted_turn_is_recorded
    int_provider = Object.new
    int_provider.define_singleton_method(:complete) { |_msgs, _opts = {}| raise Interrupt }
    stub_router!(int_provider)

    @shell.execute_free_text("long running analysis please")

    hist = @shell.conversation_history
    assert_equal 2, hist.size
    assert_includes hist[1][:content], "[Turn cancelled by user (^C)]"
  end

  def test_budget_exhausted_turn_records_attempted_work_summary
    tool_response = Struct.new(:text, :tool_calls, :usage) do
      def tool_calls?
        !tool_calls.empty?
      end
    end
    bad_tool_provider = Object.new
    bad_tool_provider.define_singleton_method(:complete) do |_msgs, _opts = {}|
      tool_response.new("", [{ "id" => "c1", "tool" => "no_such_tool_xyz", "args" => {} }],
                        { input_tokens: 5, output_tokens: 5 })
    end
    stub_router!(bad_tool_provider)

    @shell.execute_free_text("fix everything")

    hist = @shell.conversation_history
    assert_equal 2, hist.size, "invalid-tool loop must end with exactly one recorded pair"
    assert_includes hist[1][:content], "[Turn incomplete:"
    assert_includes hist[1][:content], "Repeated invalid tool call"
    assert_includes hist[1][:content], "no_such_tool_xyz", "turn summary must list the attempted tool"
  end

  def test_successful_turn_still_records_via_unified_gatekeeper
    ok_provider = Object.new
    ok_provider.define_singleton_method(:complete) { |_msgs, _opts = {}| Struct.new(:text, :usage).new("all done", { input_tokens: 3, output_tokens: 3 }) }
    ok_provider.define_singleton_method(:tool_calls?) { false }
    stub_router!(ok_provider)

    @shell.execute_free_text("simple question")

    hist = @shell.conversation_history
    assert_equal 2, hist.size
    assert_equal "all done", hist[1][:content]
    event = @shell.recorder.events.reverse.find { |e| e["type"] == "assistant_response" }
    assert event, "recorder must persist the response"
    # Plan 61: session files must be diagnosable — batch turns record
    # streamed=false so "did the answer stream?" is answerable later.
    assert_equal false, event["payload"]["streamed"]
  end

  def test_failed_turn_recording_can_be_disabled
    @config.set("context.log_failed_turns", false)
    err_provider = Object.new
    err_provider.define_singleton_method(:complete) { |_msgs, _opts = {}| raise Rubik::LLM::ClientError, "boom" }
    stub_router!(err_provider)

    @shell.execute_free_text("will this be recorded?")

    assert_empty @shell.conversation_history, "log_failed_turns=false must keep failed turns out of the window"
  end
end
