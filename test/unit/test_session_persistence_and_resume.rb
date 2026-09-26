# frozen_string_literal: true

require_relative "../test_helper"

class TestSessionPersistenceAndResume < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik_project")
    @temp_home = Dir.mktmpdir("rubik_home")
  end

  def teardown
    FileUtils.remove_entry(@temp_root)
    FileUtils.remove_entry(@temp_home)
  end

  def test_recorder_saves_to_project_sessions_directory
    recorder = Rubik::Session::Recorder.new(root_dir: @temp_root, home_dir: @temp_home)
    recorder.record("command", "!status")
    recorder.record("prompt", "Please write a test")

    assert File.exist?(recorder.session_file)
    assert_includes recorder.session_file, File.join(@temp_root, ".rubik", "sessions")

    lines = File.readlines(recorder.session_file)
    assert_equal 2, lines.size
  end

  def test_session_manager_lists_and_finds_latest_session
    # Create two session files with different timestamps
    rec1 = Rubik::Session::Recorder.new(session_name: "session_20260823_100000.jsonl", root_dir: @temp_root, home_dir: @temp_home)
    rec1.record("command", "!help")

    # Sleep slightly or adjust mtime to guarantee ordering
    rec2 = Rubik::Session::Recorder.new(session_name: "session_20260823_120000.jsonl", root_dir: @temp_root, home_dir: @temp_home)
    rec2.record("prompt", "Implement feature X")

    File.utime(Time.now - 100, Time.now - 100, rec1.session_file)
    File.utime(Time.now, Time.now, rec2.session_file)

    sessions = Rubik::Session::Manager.list_sessions(@temp_root, @temp_home)
    assert_equal 2, sessions.size
    assert_equal "session_20260823_120000", sessions.first[:id]

    latest = Rubik::Session::Manager.find_latest_session(@temp_root, @temp_home)
    assert_equal rec2.session_file, latest

    found = Rubik::Session::Manager.find_session("100000", @temp_root, @temp_home)
    assert_equal rec1.session_file, found
  end

  def test_shell_resume_session_replays_events
    # 1. First session: run some commands
    out1 = StringIO.new
    buf1 = Rubik::Buffer::Manager.new(root_dir: @temp_root)
    shell1 = Rubik::REPL::Shell.new(
      buffer_manager: buf1,
      output: out1,
      root_dir: @temp_root
    )
    shell1.execute_input("!status")
    shell1.execute_input("!help")

    # 2. Second session: resume with -c / resume_session
    out2 = StringIO.new
    buf2 = Rubik::Buffer::Manager.new(root_dir: @temp_root)
    shell2 = Rubik::REPL::Shell.new(
      buffer_manager: buf2,
      output: out2,
      root_dir: @temp_root
    )

    res = shell2.resume_session(:latest)
    assert res[:ok]
    assert res[:turns_hydrated] >= 1
    assert_includes out2.string, "Resumed session"
  end

  def test_session_repl_command
    out = StringIO.new
    buf = Rubik::Buffer::Manager.new(root_dir: @temp_root)
    shell = Rubik::REPL::Shell.new(buffer_manager: buf, output: out)

    shell.execute_input("!session info")
    assert_includes out.string, "Active Session File:"
    assert_includes out.string, "Total Events in Session:"

    shell.execute_input("!session list")
    assert_includes out.string, "Recorded Sessions"
  end

  def test_prune_sessions_dry_run_defaults_to_project_scope_and_protects_active
    old = Rubik::Session::Recorder.new(session_name: "session_old.jsonl", root_dir: @temp_root, home_dir: @temp_home)
    old.record("prompt", "ancient")
    fresh = Rubik::Session::Recorder.new(session_name: "session_fresh.jsonl", root_dir: @temp_root, home_dir: @temp_home)
    fresh.record("prompt", "recent")

    File.utime(Time.now - (10 * 86_400), Time.now - (10 * 86_400), old.session_file)
    File.utime(Time.now, Time.now, fresh.session_file)

    report = Rubik::Session::Manager.prune_sessions(
      days: 7, root_dir: @temp_root, home_dir: @temp_home, exclude_file: fresh.session_file, apply: false
    )

    assert_equal 1, report[:candidates]
    assert_equal 0, report[:deleted]
    refute report[:applied]
    assert_equal 1, report[:protected_skipped]
    assert File.exist?(old.session_file), "dry-run must not delete anything"
  end

  def test_prune_sessions_apply_deletes_old_and_keeps_active
    old = Rubik::Session::Recorder.new(session_name: "session_old.jsonl", root_dir: @temp_root, home_dir: @temp_home)
    old.record("prompt", "ancient")
    fresh = Rubik::Session::Recorder.new(session_name: "session_fresh.jsonl", root_dir: @temp_root, home_dir: @temp_home)
    fresh.record("prompt", "recent")

    File.utime(Time.now - (10 * 86_400), Time.now - (10 * 86_400), old.session_file)
    File.utime(Time.now, Time.now, fresh.session_file)

    report = Rubik::Session::Manager.prune_sessions(
      days: 7, root_dir: @temp_root, home_dir: @temp_home, exclude_file: fresh.session_file, apply: true
    )

    assert_equal 1, report[:deleted]
    refute File.exist?(old.session_file), "old session should be removed on --apply"
    assert File.exist?(fresh.session_file), "active session must survive prune"
  end

  def test_session_prune_command_is_dry_run_until_apply
    old = Rubik::Session::Recorder.new(session_name: "session_old.jsonl", root_dir: @temp_root, home_dir: @temp_home)
    old.record("prompt", "ancient")
    File.utime(Time.now - (10 * 86_400), Time.now - (10 * 86_400), old.session_file)

    out = StringIO.new
    buf = Rubik::Buffer::Manager.new(root_dir: @temp_root)
    shell = Rubik::REPL::Shell.new(buffer_manager: buf, output: out, root_dir: @temp_root)

    shell.execute_input("!session prune 7")
    assert_includes out.string, "Would delete"
    assert File.exist?(old.session_file), "dry run must leave files in place"

    shell.execute_input("!session prune 7 --apply")
    refute File.exist?(old.session_file), "--apply must unlink the old session"
  end
end
