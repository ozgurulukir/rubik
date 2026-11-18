# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestSessionReplayer < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @output = StringIO.new
    @shell = Rubik::REPL::Shell.new(output: @output)
    @recorder = Rubik::Session::Recorder.new(sessions_dir: @temp_dir, session_name: "replay.jsonl")
    @replayer = Rubik::Session::Replayer.new(@shell)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_replay_skips_destructive_commands
    @recorder.record("command", raw: "!status")
    @recorder.record("command", raw: "!apply")
    @recorder.record("command", raw: "!sh rm -rf /")

    @replayer.replay_file(@recorder.session_file)

    assert_equal 1, @replayer.replayed_events.size
    assert_equal 2, @replayer.skipped_events.size
    assert_equal "[skipped: destructive]", @replayer.skipped_events.first[:reason]
  end

  def test_replay_handles_current_recorder_event_types
    executed = []
    shell = Object.new
    shell.define_singleton_method(:execute_input) { |text| executed << text }
    replayer = Rubik::Session::Replayer.new(shell)

    @recorder.record_user_turn("please summarize the repo")
    @recorder.record_tool_call("read_file", { "path" => "x" }, call_id: "c1")
    @recorder.record_tool_result("read_file", "ok", call_id: "c1")
    @recorder.record_assistant_response("done")
    @recorder.record_repl_command("!status", "Model: test")
    @recorder.record_repl_command("!sh rm -rf /", "boom")

    replayer.replay_file(@recorder.session_file)

    assert_equal ["please summarize the repo", "!status"], executed,
                 "modern input events must be re-executed; output events must not become prompts"
    assert_equal 5, replayer.replayed_events.size
    assert_equal 1, replayer.skipped_events.size, "destructive filtering still applies to modern commands"
  end
end
