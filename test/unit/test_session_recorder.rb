# frozen_string_literal: true

require_relative "../test_helper"

class TestSessionRecorder < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @recorder = Rubik::Session::Recorder.new(sessions_dir: @temp_dir, session_name: "test_session.jsonl")
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_records_jsonl_events
    @recorder.record("input", "hello world")
    @recorder.record("command", raw: "!status")

    lines = File.readlines(@recorder.session_file)
    assert_equal 2, lines.size

    e1 = JSON.parse(lines[0])
    assert_equal "input", e1["type"]
    assert_equal "hello world", e1["payload"]
  end

  def test_masks_api_key_patterns
    fake_key = "sk-proj-123456789012345678901234"
    fake_aws = "AKIAIOSFODNN7EXAMPLE"

    @recorder.record("input", "api key is #{fake_key} and aws key is #{fake_aws}")

    lines = File.readlines(@recorder.session_file)
    content = lines.first
    refute_includes content, fake_key
    refute_includes content, fake_aws
    assert_includes content, "***MASKED***"
  end

  def test_read_history
    15.times do |i|
      @recorder.record("input", "cmd #{i}")
    end

    history = @recorder.read_history(5)
    assert_equal 5, history.size
    assert_equal "cmd 14", history.last["payload"]
  end

  def test_events_capped_at_max_recent_events
    600.times do |i|
      @recorder.record("input", "event #{i}")
    end

    assert_equal Rubik::Session::Recorder::MAX_RECENT_EVENTS, @recorder.events.size
    assert_equal "event 599", @recorder.events.last["payload"]
    assert_equal "event 100", @recorder.events.first["payload"]

    # File on disk still holds all 600 events
    assert_equal 600, File.readlines(@recorder.session_file).size
  end

  def test_switch_session_file_capped_at_max_recent_events
    large_file = File.join(@temp_dir, "large_session.jsonl")
    File.open(large_file, "w") do |f|
      600.times do |i|
        f.puts(JSON.dump({ "ts" => Time.now.iso8601, "type" => "input", "payload" => "history #{i}" }))
      end
    end

    @recorder.switch_session_file(large_file, cleanup_empty_current: false)
    # 500 loaded from file, plus 1 session_resumed event, capped at 500
    assert_equal Rubik::Session::Recorder::MAX_RECENT_EVENTS, @recorder.events.size
    assert_equal "session_resumed", @recorder.events.last["type"]
  end
end
