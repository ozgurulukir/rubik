# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestReplTerminalGuard < Minitest::Test
  class FakeReline
    attr_reader :redisplay_count, :history

    def initialize
      @redisplay_count = 0
      @history = []
    end

    def redisplay
      @redisplay_count += 1
    end

    def readline(_prompt, _history = nil)
      "mock input"
    end
  end

  def setup
    @output = StringIO.new
    @reline = FakeReline.new
    @guard = Rubik::REPL::TerminalGuard.new(output: @output, reline: @reline)
  end

  def test_initial_state
    refute @guard.reading?
    refute @guard.quiet?
    assert_empty @guard.inbox
  end

  def test_with_reading_lifecycle
    refute @guard.reading?
    entered = false
    @guard.with_reading do
      entered = true
      assert @guard.reading?
    end
    assert entered
    refute @guard.reading?
  end

  def test_with_reading_resets_on_error
    assert_raises(RuntimeError) do
      @guard.with_reading do
        assert @guard.reading?
        raise "kaboom"
      end
    end
    refute @guard.reading?
  end

  def test_idle_notice_prints_directly_without_redisplay
    res = @guard.print_safe_notice("Unit 1 completed")
    assert res
    assert_equal 0, @reline.redisplay_count
    assert_equal "Unit 1 completed\n", @output.string
    refute_includes @output.string, "\r\e[2K"
  end

  def test_reading_notice_clears_line_prints_and_triggers_redisplay
    @guard.with_reading do
      res = @guard.print_safe_notice("Background task finished")
      assert res
    end

    assert_equal 1, @reline.redisplay_count
    assert_equal "\r\e[2KBackground task finished\n", @output.string
  end

  def test_strips_leading_newlines_in_notice
    @guard.with_reading do
      @guard.print_safe_notice("\n\nClean notice")
    end
    assert_equal "\r\e[2KClean notice\n", @output.string
  end

  def test_ignores_nil_or_empty_notice
    refute @guard.print_safe_notice(nil)
    refute @guard.print_safe_notice("")
    assert_empty @output.string
  end

  def test_quiet_mode_buffers_to_inbox
    @guard.quiet = true
    assert @guard.quiet?

    res = @guard.print_safe_notice("Quiet event 1")
    refute res
    assert_empty @output.string
    assert_equal ["Quiet event 1"], @guard.inbox

    @guard.print_safe_notice("Quiet event 2")
    assert_equal ["Quiet event 1", "Quiet event 2"], @guard.inbox
    assert_empty @output.string

    # Flush notices while idle
    flushed = @guard.flush_notices!
    assert flushed
    assert_empty @guard.inbox
    assert_equal "Quiet event 1\nQuiet event 2\n", @output.string
  end

  def test_quiet_mode_flush_while_reading_triggers_redisplay
    @guard.quiet = true
    @guard.print_safe_notice("Buffered 1")
    @guard.print_safe_notice("Buffered 2")

    @guard.with_reading do
      @guard.flush_notices!
    end

    assert_equal 1, @reline.redisplay_count
    assert_equal "\r\e[2KBuffered 1\nBuffered 2\n", @output.string
    assert_empty @guard.inbox
  end

  def test_quiet_mode_force_bypasses_buffering
    @guard.quiet = true
    res = @guard.print_safe_notice("Urgent event!", force: true)
    assert res
    assert_equal "Urgent event!\n", @output.string
    assert_empty @guard.inbox
  end

  def test_thread_safe_concurrent_notices
    threads = 10.times.map do |i|
      Thread.new do
        5.times do |j|
          @guard.print_safe_notice("Notice #{i}-#{j}")
        end
      end
    end
    threads.each(&:join)

    lines = @output.string.lines.map(&:chomp)
    assert_equal 50, lines.size
  end
end
