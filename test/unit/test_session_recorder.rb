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
end
