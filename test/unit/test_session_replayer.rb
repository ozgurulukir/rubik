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
end
