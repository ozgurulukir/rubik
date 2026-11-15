# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/platform/process"

# Unit tests for Rubik::Platform::Process (Plan 86 D-4): the single-homed
# popen3 + reader-thread drain core and the kill_tree/descendant-pids
# teardown helpers. Children are `sleep`/`ruby -e` only — no real network,
# no shell strings from untrusted input.
class TestPlatformProcess < Minitest::Test
  def setup
    @tmp_dir = Dir.mktmpdir("rubik_process_test")
  end

  def teardown
    FileUtils.remove_entry(@tmp_dir)
  end

  # ── popen_capture: capture behavior ──

  def test_capture_collects_stdout_stderr_and_exit_code
    res = Rubik::Platform.popen_capture(
      RbConfig.ruby, "-e", "print 'out-payload'; $stderr.print 'err-payload'", timeout: 10
    )

    assert res[:ok]
    assert_equal 0, res[:exit_code]
    assert_equal "out-payload", res[:stdout]
    assert_equal "err-payload", res[:stderr]
    assert_equal "out-payload\nerr-payload", res[:output]
    assert res[:pid].positive?
    assert res[:duration].is_a?(Numeric)
  end

  def test_capture_maps_nonzero_exit
    res = Rubik::Platform.popen_capture(RbConfig.ruby, "-e", "exit 3", timeout: 10)

    refute res[:ok]
    assert_equal 3, res[:exit_code]
  end

  def test_capture_maps_signal_death_to_128_plus_termsig
    # Windows has no POSIX signal-death semantics: a TERM'd child reports a
    # plain exit status, not 128 + termsig.
    skip "POSIX signal-death semantics unavailable on Windows" if Gem.win_platform?

    res = Rubik::Platform.popen_capture(RbConfig.ruby, "-e", "Process.kill('TERM', $$)", timeout: 10)

    refute res[:ok]
    assert_equal 143, res[:exit_code], "TERM (15) must map to 128 + 15"
  end

  def test_capture_reports_missing_binary_as_one_twenty_seven
    res = Rubik::Platform.popen_capture("definitely-not-a-binary-xyz-123", timeout: 5)

    refute res[:ok]
    assert_equal 127, res[:exit_code]
    assert_includes res[:stderr], "Binary not found"
  end

  def test_capture_drains_large_output_without_deadlocking
    # The reader-thread drain must survive output well beyond the OS pipe
    # buffer (~64KB): a single-threaded capture would deadlock here.
    res = Rubik::Platform.popen_capture(
      RbConfig.ruby, "-e", "print 'x' * 200_000", timeout: 30
    )

    assert res[:ok]
    assert_equal 200_000, res[:stdout].bytesize
  end

  def test_capture_respects_chdir
    marker = File.join(@tmp_dir, "cwd.txt")
    res = Rubik::Platform.popen_capture(
      RbConfig.ruby, "-e", "File.write(ARGV[0], Dir.pwd)", marker, chdir: @tmp_dir, timeout: 10
    )

    assert res[:ok]
    assert_equal File.realpath(@tmp_dir), File.read(marker)
  end

  def test_default_io_error_observer_is_error_isolated
    # The default observer must swallow both read-failure events without
    # raising (Log is error-isolated), keeping the drain alive.
    observer = Rubik::Platform::Process::DEFAULT_ON_IO_ERROR
    observer.call(:stdout_read, IOError.new("closed stream"))
    observer.call(:stderr_read, IOError.new("closed stream"))
  end

  def test_custom_on_io_error_is_used_for_swallowed_io_errors
    seen = []
    status = Struct.new(:exitstatus, :signaled?).new(0, false)
    # A stdin whose close raises forces the :stdin_close swallow path.
    stub_popen = lambda do |*_cmd, **_kw, &popen_block|
      stdin = Object.new
      stdin.define_singleton_method(:close) { raise IOError, "cannot close" }
      stdout = StringIO.new("out")
      stderr = StringIO.new("")
      wait_thr = Object.new
      wait_thr.define_singleton_method(:pid) { 42_424 }
      wait_thr.define_singleton_method(:value) { status }
      popen_block.call(stdin, stdout, stderr, wait_thr)
    end

    Open3.stub(:popen3, stub_popen) do
      res = Rubik::Platform.popen_capture("any", on_io_error: ->(event, _e) { seen << event })

      assert res[:ok]
      assert_equal "out", res[:stdout]
    end
    assert_includes seen, :stdin_close
  end

  # ── popen_capture: timeout kill ──
  #
  # The deadline watchdog (issue #479) kills the child tree from a separate
  # thread when the deadline fires, so the wall clock is bounded by the
  # configured timeout (plus the kill grace window) instead of the child's
  # natural lifetime. The 124 / stderr-message contract below predates the
  # fix and must keep holding.

  def test_timeout_bounds_the_wall_clock
    started = Time.now
    res = Rubik::Platform.popen_capture("sleep", "30", timeout: 1, timeout_message: "bounded")
    elapsed = Time.now - started

    refute res[:ok]
    assert_equal 124, res[:exit_code]
    assert_equal "bounded", res[:stderr]
    assert_operator(
      elapsed, :<, 5,
      "a timed-out child must not block for its natural lifetime (took #{elapsed.round(2)}s)"
    )
  end

  def test_timeout_reports_124_and_the_timeout_message
    res = Rubik::Platform.popen_capture("sleep", "2", timeout: 1, timeout_message: "test deadline hit")

    refute res[:ok]
    assert_equal 124, res[:exit_code]
    assert_equal "test deadline hit", res[:stderr]
  end

  def test_timeout_uses_the_generic_message_when_unset
    res = Rubik::Platform.popen_capture("sleep", "2", timeout: 1)

    assert_equal "Execution timed out after 1 seconds", res[:stderr]
  end

  # ── kill_tree ──

  def test_kill_tree_no_ops_on_nil_and_nonpositive_pids
    assert_nil Rubik::Platform.kill_tree(nil)
    assert_nil Rubik::Platform.kill_tree(0)
    assert_nil Rubik::Platform.kill_tree(-1)
  end

  def test_kill_tree_kills_the_direct_child
    # Windows kill_tree delegates to taskkill /F, which reports a plain
    # (non-signaled) exit status.
    skip "POSIX signaled-exit semantics unavailable on Windows" if Gem.win_platform?

    # Handshake: wait until the child is past interpreter boot and parked in
    # `sleep`, so the TERM lands in the sleep loop and the child dies BY the
    # signal. A TERM during early boot is converted by Ruby into an uncaught
    # SignalException -> exit code 1 (pinned by the boot-TERM test below).
    ready = File.join(@tmp_dir, "ready.txt")
    pid = ::Process.spawn(
      RbConfig.ruby, "-e",
      "File.write(#{ready.inspect}, '1'); sleep 30"
    )
    begin
      wait_until(5) { File.exist?(ready) }
      Rubik::Platform.kill_tree(pid)
      status = wait_until(5) do
        _, st = ::Process.waitpid2(pid, ::Process::WNOHANG)
        st
      end
      refute_nil status, "the direct child must be reaped"
      assert status.signaled?, "the child must die by signal, not exit"
    ensure
      kill_and_reap(pid)
    end
  end

  # A TERM arriving during Ruby's interpreter boot (before the -e script is
  # parked in sleep) is converted into an uncaught SignalException and the
  # child EXITS 1 instead of dying by the signal. kill_tree's contract is
  # termination, and either outcome satisfies it when the target converts
  # TERM this way.
  def test_kill_tree_terminates_child_even_when_boot_term_is_converted
    pid = ::Process.spawn(RbConfig.ruby, "-e", "sleep 30")
    begin
      wait_until(5) do
        ::Process.kill(0, pid)
        true
      rescue StandardError
        false
      end
      Rubik::Platform.kill_tree(pid) # TERM lands mid-boot (kill(0) succeeds ~30ms in)
      status = wait_until(5) do
        _, st = ::Process.waitpid2(pid, ::Process::WNOHANG)
        st
      end
      refute_nil status, "the direct child must be reaped"
      assert(
        status.signaled? || (status.exited? && !status.success?),
        "child must die by signal or exit abnormally, got signaled=#{status.signaled?} exit=#{status.exited? ? status.exitstatus : '-'}"
      )
    ensure
      kill_and_reap(pid)
    end
  end

  def test_kill_tree_kills_descendants_leaves_first
    # Parent spawns a child that heartbeats a file every 100ms; killing the
    # parent tree must silence the heartbeat (zombies never write files, so
    # staleness proves the descendant was killed, not merely orphaned).
    parent_script = File.join(@tmp_dir, "parent.rb")
    child_script = File.join(@tmp_dir, "child.rb")
    heartbeat = File.join(@tmp_dir, "heartbeat.txt")

    File.write(child_script, <<~RUBY)
      File.write(#{heartbeat.inspect}, Process.pid.to_s)
      loop do
        sleep 0.1
        File.write(#{heartbeat.inspect}, Process.pid.to_s)
      end
    RUBY
    File.write(parent_script, <<~RUBY)
      child = Process.spawn(#{RbConfig.ruby.inspect}, #{child_script.inspect})
      File.write(#{File.join(@tmp_dir, 'child_pid.txt').inspect}, child.to_s)
      sleep 30
    RUBY

    parent_pid = ::Process.spawn(RbConfig.ruby, parent_script)
    begin
      child_pid = nil
      wait_until(5) do
        child_pid = File.read(File.join(@tmp_dir, "child_pid.txt")) if File.exist?(File.join(@tmp_dir, "child_pid.txt"))
        child_pid && descendant_alive?(child_pid.to_i) && File.exist?(heartbeat)
      end
      assert child_pid, "the grandchild must be running before the kill"

      Rubik::Platform.kill_tree(parent_pid)
      wait_until(5) do
        _, st = ::Process.waitpid2(parent_pid, ::Process::WNOHANG)
        st
      end

      wait_until(5) { (Time.now - File.mtime(heartbeat)) > 0.5 }
      sleep 0.3 # grace: one more heartbeat interval must NOT happen
      stale = (Time.now - File.mtime(heartbeat)) > 0.5
      assert stale, "the descendant heartbeat must stop: kill_tree must not orphan children"
    ensure
      kill_and_reap(parent_pid)
      child_pid = File.read(File.join(@tmp_dir, "child_pid.txt")).to_i if File.exist?(File.join(@tmp_dir, "child_pid.txt"))
      kill_and_reap(child_pid)
    end
  end

  def test_descendant_pids_finds_the_grandchild_while_alive
    # descendant_pids walks /proc/<pid>/task/*/children — POSIX-only.
    skip "/proc descendant discovery unavailable on Windows" if Gem.win_platform?

    parent_pid = ::Process.spawn(RbConfig.ruby, "-e", "Process.spawn('sleep', '30'); sleep 30")
    begin
      grandchild = nil
      wait_until(5) do
        grandchild = Rubik::Platform.descendant_pids(parent_pid).first
        grandchild
      end
      assert grandchild, "the sleeping grandchild must be discovered"
      assert_includes Rubik::Platform.descendant_pids(parent_pid), grandchild
    ensure
      Rubik::Platform.kill_tree(parent_pid)
      kill_and_reap(parent_pid)
    end
  end

  def test_descendant_pids_no_ops_and_fails_closed
    assert_empty Rubik::Platform.descendant_pids(nil)
    assert_empty Rubik::Platform.descendant_pids(-5)
    # A pid that cannot exist (and never can be reused by the test process
    # itself): the rescue path returns [] instead of raising.
    assert_empty Rubik::Platform.descendant_pids(4_194_303)
  end

  private

  def descendant_alive?(pid)
    ::Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def kill_and_reap(pid)
    return unless pid&.positive?

    begin
      ::Process.kill("KILL", pid)
    rescue StandardError
      nil
    end
    begin
      ::Process.waitpid(pid)
    rescue StandardError
      nil
    end
  end
end
