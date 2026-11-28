# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Shell lifecycle teardown regressions (#684/#685): stream-mode teardown,
# idempotent and failure-isolated stop, boot rollback, bounded indexer join,
# and quiet-notice flush at stream end.
class TestReplTeardownFixes < Minitest::Test
  class BootFailShell < Rubik::REPL::Shell
    class << self
      attr_accessor :rolled_back
    end

    def sync_ui
      @runtime_manager.context.on_dispose { self.class.rolled_back = true }
      raise "boot boom"
    end
  end

  def setup
    @temp_dir = Dir.mktmpdir("rubik_teardown_test")
    @temp_home = Dir.mktmpdir("rubik_teardown_home")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    @output = StringIO.new
    @shell = Rubik::REPL::Shell.new(config: @config, output: @output, root_dir: @temp_dir)
  end

  def teardown
    @shell&.stop
    FileUtils.remove_entry(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
    FileUtils.remove_entry(@temp_home) if @temp_home && File.exist?(@temp_home)
  end

  def test_stream_run_stops_the_shell
    # #685: library embeddings of run(stream) must not leak the runtime
    # context, subscribers or ambient shell handles.
    @shell.define_singleton_method(:execute_input) { |_text| nil }
    @shell.run(StringIO.new("!status\n"))

    refute @shell.running?
    assert_equal [], @shell.instance_variable_get(:@config_cleanups)
    refute_same @shell, Rubik.current_shell
  end

  def test_stop_is_idempotent_and_warns_once
    # #684: exit paths call stop explicitly and again from run_interactive's
    # ensure; the dirty-buffer warning must not be printed twice.
    dirty_calls = 0
    buffer = Object.new
    buffer.define_singleton_method(:dirty?) do
      dirty_calls += 1
      true
    end
    buffer.define_singleton_method(:dirty_files) { ["a.rb"] }
    @shell.instance_variable_set(:@buffer_manager, buffer)
    @shell.instance_variable_set(:@output, StringIO.new)

    @shell.stop
    @shell.stop

    assert_equal 1, dirty_calls
    assert_equal 1, @shell.output.string.scan("unapplied dirty buffer change").size
  end

  def test_stop_isolates_failing_cleanup_and_finishes_teardown
    # #685: a raising config cleanup used to skip runtime disposal, subagent
    # shutdown and the ambient-handle reset — and masked the in-flight error.
    calls = []
    first_cleanup = lambda do
      calls << :first
      raise "cleanup boom"
    end
    @shell.instance_variable_set(:@config_cleanups, [first_cleanup, -> { calls << :second }])
    supervisor = Object.new
    supervisor.define_singleton_method(:shutdown_all) { calls << :subagents }
    @shell.instance_variable_set(:@subagent_supervisor, supervisor)

    @shell.stop

    assert_equal [:second, :first, :subagents], calls, "cleanups unwind LIFO and teardown continues"
    refute @shell.running?
    refute_same @shell, Rubik.current_shell
  end

  def test_boot_failure_unwinds_partial_effects
    # #685: phases 2-8 register inverses one by one; a mid-boot raise must
    # drain the partial accumulator before propagating (AGENTS.md 1A/5).
    BootFailShell.rolled_back = false
    assert_raises(RuntimeError) do
      BootFailShell.new(config: @config, output: @output, root_dir: @temp_dir)
    end
    assert BootFailShell.rolled_back, "a failed boot must dispose its runtime context"
  ensure
    BootFailShell.rolled_back = false
  end

  def test_indexer_join_uses_a_bounded_timeout
    # #685: an indexer ignoring the cooperative stop flag must not block the
    # main thread indefinitely during teardown.
    captured = []
    @shell.define_singleton_method(:join_indexer_safely) { |timeout = nil| captured << timeout }
    thread = Thread.new { sleep 30 }
    @shell.instance_variable_set(:@indexer_thread, thread)

    @shell.stop_background_indexer

    assert_equal [Rubik::REPL::AstWarmup::INDEXER_JOIN_TIMEOUT], captured
  ensure
    thread&.kill
  end

  def test_stream_run_flushes_quiet_notices
    # #686: stream mode has no interactive prompt to call flush_notices!.
    guard = Rubik::REPL::TerminalGuard.new(output: @output, reline: Reline, quiet: true)
    @shell.terminal_guard = guard
    guard.print_safe_notice("stream notice")
    @shell.define_singleton_method(:execute_input) { |_text| nil }

    @shell.run(StringIO.new("\n"))

    assert_includes @output.string, "stream notice"
  end
end
