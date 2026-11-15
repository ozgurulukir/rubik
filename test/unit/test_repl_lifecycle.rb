# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Pins REPL::Lifecycle's private debug diagnostics channel: gated by
# ENV["RUBIK_DEBUG"], never raises, and — the regression this file exists
# for — still audible when $VERBOSE is nil (bundler/rake -W0 silences
# Kernel#warn, which the channel originally used).
class TestREPLLifecycleDiagnostics < Minitest::Test
  def host
    Object.new.extend(Rubik::REPL::Lifecycle)
  end

  def restore_env(old_debug)
    old_debug ? (ENV["RUBIK_DEBUG"] = old_debug) : ENV.delete("RUBIK_DEBUG")
  end

  def test_debug_warn_emits_when_verbose_is_nil
    old_verbose = $VERBOSE
    old_debug = ENV.fetch("RUBIK_DEBUG", nil)
    old_stderr = $stderr
    captured = nil
    $VERBOSE = nil
    ENV["RUBIK_DEBUG"] = "1"
    $stderr = StringIO.new
    begin
      host.send(:debug_warn, "lifecycle warning")
      captured = $stderr.string
    ensure
      $stderr = old_stderr
      restore_env(old_debug)
      $VERBOSE = old_verbose
    end

    assert_includes captured, "[WARN] lifecycle warning"
  end

  def test_debug_warn_silent_without_rubik_debug
    old_debug = ENV.fetch("RUBIK_DEBUG", nil)
    ENV.delete("RUBIK_DEBUG")
    old_stderr = $stderr
    captured = nil
    begin
      $stderr = StringIO.new
      host.send(:debug_warn, "must not appear")
      captured = $stderr.string
    ensure
      $stderr = old_stderr
      restore_env(old_debug)
    end

    assert_empty captured
  end

  def test_debug_warn_never_raises
    old_debug = ENV.fetch("RUBIK_DEBUG", nil)
    ENV["RUBIK_DEBUG"] = "1"
    old_stderr = $stderr
    broken = Object.new
    def broken.write(*) = 1
    def broken.puts(*) = raise "broken emit target"
    begin
      $stderr = broken
      host.send(:debug_warn, "should be swallowed")
    rescue StandardError => e
      flunk("debug_warn raised: #{e.class}: #{e.message}")
    ensure
      $stderr = old_stderr
      restore_env(old_debug)
    end
  end
end

class TestREPLLifecycleFlushSubagentNotices < Minitest::Test
  class Target
    include Rubik::REPL::Lifecycle

    attr_accessor :output
  end

  def setup
    @host = Target.new
    @io = StringIO.new
    @mutex = Mutex.new
    # Issue #469: the standby buffer and its mutex are owned by the
    # NoticeRouter; the host delegates flush_subagent_notices! to it.
    @router = @host.notice_router
  end

  def test_flush_early_return_when_output_nil
    @host.output = nil
    @router.instance_variable_set(:@subagent_notices_mutex, @mutex)
    @router.instance_variable_set(:@subagent_notices, ["notice 1"])

    @host.flush_subagent_notices!

    assert_equal ["notice 1"], @router.subagent_notices
  end

  def test_flush_is_noop_on_unwired_router
    # Issue #469: the standby buffer lives on the NoticeRouter and is lazily
    # created, so a router that never wired (or buffered) anything flushes
    # as a no-op — the observable contract of the old nil-mutex early return.
    @host.output = @io

    @host.flush_subagent_notices!

    assert_empty @router.subagent_notices
    assert_empty @io.string
  end

  def test_flush_early_return_when_notices_empty
    @host.output = @io
    @router.instance_variable_set(:@subagent_notices_mutex, @mutex)
    @router.instance_variable_set(:@subagent_notices, [])

    @host.flush_subagent_notices!

    assert_empty @router.subagent_notices
    assert_empty @io.string
  end

  def test_flush_flushes_notices_and_clears_queue
    @host.output = @io
    @router.instance_variable_set(:@subagent_notices_mutex, @mutex)
    @router.instance_variable_set(:@subagent_notices, ["Subagent A finished", "Task #2 completed"])

    @host.flush_subagent_notices!

    assert_empty @router.subagent_notices
    assert_equal "
Subagent A finished
Task #2 completed
", @io.string
  end

  def test_flush_synchronizes_access_under_mutex
    @host.output = @io
    @router.instance_variable_set(:@subagent_notices, ["Sync test notice"])

    mutex_called = false
    mock_mutex = Minitest::Mock.new
    mock_mutex.expect(:synchronize, ["Sync test notice"]) do |&block|
      mutex_called = true
      block.call
    end
    @router.instance_variable_set(:@subagent_notices_mutex, mock_mutex)

    @host.flush_subagent_notices!

    assert mutex_called
    mock_mutex.verify
    assert_empty @router.subagent_notices
    assert_equal "
Sync test notice
", @io.string
  end
end
