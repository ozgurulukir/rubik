# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"

class TestSessionManagerParse < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik_session_parse")
  end

  def teardown
    FileUtils.remove_entry(@temp_root) if File.directory?(@temp_root)
  end

  def write_session(content)
    path = File.join(@temp_root, "truncated.jsonl")
    File.write(path, content)
    path
  end

  def test_event_count_includes_truncated_final_line_without_newline
    path = write_session(<<~JSONL.chomp)
      {"type":"prompt","ts":"t1","payload":{"content":"first"}}
      {"type":"assistant_response","ts":"t2","payload":{"content":"reply"}}
      {"type":"input","ts":"t3","payload":{"command":"final"}}
    JSONL

    session = Rubik::Session::Manager.parse_session_file(path, :project)

    assert_equal 3, session[:event_count]
    assert_equal "final", session[:last_prompt]
  end

  def test_event_count_with_trailing_newline_unchanged
    path = write_session(<<~JSONL)
      {"type":"prompt","ts":"t1","payload":{"content":"first"}}
      {"type":"input","ts":"t2","payload":{"command":"final"}}
    JSONL

    session = Rubik::Session::Manager.parse_session_file(path, :project)

    assert_equal 2, session[:event_count]
    assert_equal "final", session[:last_prompt]
  end
end
