# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "stringio"
require "fileutils"

class TestSessionContinuity < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik_continuity_root")
    @temp_home = Dir.mktmpdir("rubik_continuity_home")
  end

  def teardown
    FileUtils.remove_entry(@temp_root) rescue nil
    FileUtils.remove_entry(@temp_home) rescue nil
  end

  def test_recorder_structured_events
    sessions_dir = File.join(@temp_root, ".rubik", "sessions")
    recorder = Rubik::Session::Recorder.new(sessions_dir: sessions_dir, session_name: "test_structured.jsonl")

    # 1. Record user turn
    ev1 = recorder.record_user_turn("Refactor the parser")
    assert_equal "user_turn", ev1["type"]
    assert_equal "user", ev1["payload"]["role"]
    assert_equal "Refactor the parser", ev1["payload"]["content"]

    # 2. Record assistant response
    ev2 = recorder.record_assistant_response("I have refactored the parser.", tokens: 120)
    assert_equal "assistant_response", ev2["type"]
    assert_equal "assistant", ev2["payload"]["role"]
    assert_equal "I have refactored the parser.", ev2["payload"]["content"]
    assert_equal 120, ev2["payload"]["tokens"]

    # 3. Record tool call
    ev3 = recorder.record_tool_call("read_file", { "path" => "lib/rubik.rb" }, call_id: "call_123")
    assert_equal "tool_call", ev3["type"]
    assert_equal "read_file", ev3["payload"]["tool"]
    assert_equal "call_123", ev3["payload"]["call_id"]

    # 4. Record tool result
    ev4 = recorder.record_tool_result("read_file", "module Rubik...", status: :ok, call_id: "call_123")
    assert_equal "tool_result", ev4["type"]
    assert_equal "module Rubik...", ev4["payload"]["output"]
    assert_equal "ok", ev4["payload"]["status"].to_s
    assert_equal "call_123", ev4["payload"]["call_id"]

    # 5. Record REPL command
    ev5 = recorder.record_repl_command("!test", "3 tests, 0 failures")
    assert_equal "repl_command", ev5["type"]
    assert_equal "!test", ev5["payload"]["command"]
    assert_equal "3 tests, 0 failures", ev5["payload"]["output"]

    # Verify history
    history = recorder.read_history(10)
    assert_equal 2, history.size
    assert_equal "user_turn", history[0]["type"]
    assert_equal "repl_command", history[1]["type"]
  end

  def test_recorder_secret_masking
    sessions_dir = File.join(@temp_root, ".rubik", "sessions")
    recorder = Rubik::Session::Recorder.new(sessions_dir: sessions_dir, session_name: "test_masking.jsonl")

    # OpenAI key
    t1 = recorder.mask_text("OpenAI key is sk-12345678901234567890123456")
    assert_equal "OpenAI key is ***MASKED***", t1

    # Anthropic key
    t2 = recorder.mask_text("Anthropic key is sk-ant-123456789012345678901234")
    assert_equal "Anthropic key is ***MASKED***", t2

    # AWS Key
    t3 = recorder.mask_text("AWS key is AKIAIOSFODNN7EXAMPLE")
    assert_equal "AWS key is ***MASKED***", t3

    # GitHub classic PAT
    t4 = recorder.mask_text("GitHub PAT: ghp_123456789012345678901234567890123456")
    assert_equal "GitHub PAT: ***MASKED***", t4

    # GitHub fine-grained PAT
    t5 = recorder.mask_text("GitHub token: github_pat_123456789012345678901234")
    assert_equal "GitHub token: ***MASKED***", t5

    # Google AI key
    t6 = recorder.mask_text("Gemini key: AIzaSy123456789012345678901234567890123")
    assert_equal "Gemini key: ***MASKED***", t6

    # Bearer token
    t7 = recorder.mask_text("Authorization: Bearer my_secret_token_123.xyz")
    assert_equal "Authorization: ***MASKED***", t7

    # Basic auth in URL
    t8 = recorder.mask_text("Git remote: https://user:super_secret_password@github.com/repo.git")
    assert_equal "Git remote: https://user:***MASKED***@github.com/repo.git", t8

    # Dictionary key based masking in mask_payload
    payload = {
      "api_key" => "raw_api_key_value",
      "user_token" => "secret_token_abc",
      "password" => "super_secret",
      "auth_header" => "secret_auth",
      "normal_text" => "hello world",
      "nested" => {
        "secret_val" => "nested_secret_123"
      }
    }
    masked = recorder.send(:mask_payload, payload)
    assert_equal "***MASKED***", masked["api_key"]
    assert_equal "***MASKED***", masked["user_token"]
    assert_equal "***MASKED***", masked["password"]
    assert_equal "***MASKED***", masked["auth_header"]
    assert_equal "hello world", masked["normal_text"]
    assert_equal "***MASKED***", masked["nested"]["secret_val"]
  end

  def test_switch_session_file_and_orphan_cleanup
    sessions_dir = File.join(@temp_root, ".rubik", "sessions")
    FileUtils.mkdir_p(sessions_dir)

    # 1. Target existing session file with events
    target_file = File.join(sessions_dir, "session_target.jsonl")
    File.open(target_file, "w") do |f|
      f.puts JSON.dump({ "ts" => Time.now.iso8601, "type" => "user_turn", "payload" => { "content" => "Old task" } })
    end

    # 2. Fresh session recorder (creates empty session file)
    rec = Rubik::Session::Recorder.new(sessions_dir: sessions_dir, session_name: "empty_orphan.jsonl")
    empty_file = rec.session_file
    File.write(empty_file, "") # make sure it's 0 bytes
    assert File.exist?(empty_file)

    # 3. Switch to target_file
    rec.switch_session_file(target_file, cleanup_empty_current: true)

    # Empty orphan file must have been deleted
    refute File.exist?(empty_file), "Empty orphan session file should be cleaned up"
    assert_equal target_file, rec.session_file
    assert_equal 2, rec.events.size # 1 old event + 1 session_resumed event
    assert_equal "session_resumed", rec.events.last["type"]
    assert_equal "session_target", rec.events.last["payload"]["parent_session_id"]
  end

  def test_switch_session_file_does_not_delete_non_empty_current
    sessions_dir = File.join(@temp_root, ".rubik", "sessions")
    FileUtils.mkdir_p(sessions_dir)

    target_file = File.join(sessions_dir, "session_target2.jsonl")
    File.write(target_file, JSON.dump({ "type" => "user_turn", "payload" => { "content" => "Target" } }) + "\n")

    rec = Rubik::Session::Recorder.new(sessions_dir: sessions_dir, session_name: "active_session.jsonl")
    rec.record_user_turn("Do not delete me")
    active_file = rec.session_file

    rec.switch_session_file(target_file, cleanup_empty_current: true)
    assert File.exist?(active_file), "Non-empty session file should NOT be deleted on switch"
  end

  def test_manager_restore_session_instant_hydration
    sessions_dir = File.join(@temp_root, ".rubik", "sessions")
    FileUtils.mkdir_p(sessions_dir)
    session_file = File.join(sessions_dir, "session_restore_test.jsonl")

    events = [
      { "ts" => Time.now.iso8601, "type" => "user_turn", "payload" => { "role" => "user", "content" => "Fix the tests" } },
      { "ts" => Time.now.iso8601, "type" => "tool_call", "payload" => { "tool" => "sh", "args" => "rake test" } },
      { "ts" => Time.now.iso8601, "type" => "tool_result", "payload" => { "tool" => "sh", "output" => "Failures: 1" } },
      { "ts" => Time.now.iso8601, "type" => "assistant_response", "payload" => { "role" => "assistant", "content" => "Tests fixed!" } },
      { "ts" => Time.now.iso8601, "type" => "repl_command", "payload" => { "command" => "!diff", "output" => "+ fixed line" } }
    ]

    File.open(session_file, "w") do |f|
      events.each { |e| f.puts JSON.dump(e) }
    end

    out = StringIO.new
    buf = Rubik::Buffer::Manager.new(root_dir: @temp_root)
    shell = Rubik::REPL::Shell.new(buffer_manager: buf, output: out)

    res = Rubik::Session::Manager.restore_session(shell, session_file)
    assert res[:ok]
    assert_equal 4, res[:turns_hydrated] # user_turn, assistant_response, repl_command user, repl_command assistant
    assert_equal 5, res[:event_count]
    assert_equal "!diff", res[:last_prompt]

    # Verify conversation_history
    history = shell.conversation_history
    assert_equal 4, history.size
    assert_equal "Fix the tests", history[0][:content]
    assert_equal "user", history[0][:role]
    assert_equal "Tests fixed!", history[1][:content]
    assert_equal "assistant", history[1][:role]
    assert_equal "!diff", history[2][:content]
    assert_equal "user", history[2][:role]
    assert_equal "+ fixed line", history[3][:content]
    assert_equal "assistant", history[3][:role]
  end

  def test_legacy_session_format_backward_compatibility
    sessions_dir = File.join(@temp_root, ".rubik", "sessions")
    FileUtils.mkdir_p(sessions_dir)
    legacy_file = File.join(sessions_dir, "legacy_session.jsonl")

    lines = [
      JSON.dump({ "ts" => Time.now.iso8601, "type" => "prompt", "payload" => "Legacy prompt string" }),
      JSON.dump({ "ts" => Time.now.iso8601, "type" => "assistant", "payload" => "Legacy assistant string" }),
      JSON.dump({ "ts" => Time.now.iso8601, "type" => "input", "payload" => { "raw" => "Legacy input raw" } }),
      JSON.dump({ "ts" => Time.now.iso8601, "type" => "output", "payload" => { "content" => "Legacy output content" } }),
      "THIS IS A CORRUPTED UNPARSEABLE JSON LINE @@#$#%",
      JSON.dump({ "ts" => Time.now.iso8601, "type" => "user_turn", "payload" => { "content" => "Modern turn" } })
    ]

    File.write(legacy_file, lines.join("\n") + "\n")

    out = StringIO.new
    buf = Rubik::Buffer::Manager.new(root_dir: @temp_root)
    shell = Rubik::REPL::Shell.new(buffer_manager: buf, output: out)

    res = Rubik::Session::Manager.restore_session(shell, legacy_file)
    assert res[:ok]
    assert_equal 5, res[:turns_hydrated]
    assert_equal 5, res[:event_count] # skipped the corrupted line

    history = shell.conversation_history
    assert_equal 5, history.size
    assert_equal "Legacy prompt string", history[0][:content]
    assert_equal "Legacy assistant string", history[1][:content]
    assert_equal "Legacy input raw", history[2][:content]
    assert_equal "Legacy output content", history[3][:content]
    assert_equal "Modern turn", history[4][:content]
  end

  def test_shell_resume_session_workflow
    # 1. Shell 1: run a tracked command
    out1 = StringIO.new
    buf1 = Rubik::Buffer::Manager.new(root_dir: @temp_root)
    shell1 = Rubik::REPL::Shell.new(
      buffer_manager: buf1,
      output: out1,
      root_dir: @temp_root
    )

    shell1.execute_input("!status")
    assert_equal 2, shell1.conversation_history.size # !status user + assistant

    # 2. Shell 2: resume latest session
    out2 = StringIO.new
    buf2 = Rubik::Buffer::Manager.new(root_dir: @temp_root)
    shell2 = Rubik::REPL::Shell.new(
      buffer_manager: buf2,
      output: out2,
      root_dir: @temp_root
    )

    res = shell2.resume_session(:latest)
    assert res[:ok]
    assert res[:turns_hydrated] >= 2
    assert_includes out2.string, "dialogue turns hydrated, 0 API tokens used"

    # Shell 2 should have inherited shell 1 conversation history
    assert_equal 2, shell2.conversation_history.size
    assert_equal "!status", shell2.conversation_history.first[:content]
  end
end
