# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/repl/prompt_grace"

class TestPromptGrace < Minitest::Test
  class Console
    attr_accessor :console_mode, :queued

    def initialize
      @console_mode = :cooked
    end

    def raw!
      @console_mode = :raw
    end

    def nread = @queued.to_s.bytesize
    def iflush = (@queued = "")
  end

  def setup
    @input = Console.new
    @output = StringIO.new
    @ctx = Rubik::Runtime::Context.new
    @now = 0.0
    @reads = []
  end

  def gate(events = [])
    reader = lambda do |timeout|
      @reads << timeout
      delay, byte = events.shift || [timeout, nil]
      @now += delay
      byte
    end
    Rubik::REPL::PromptGrace.new(input: @input, output: @output, context: @ctx,
                                 clock: -> { @now }, reader: reader)
  end

  def test_deadlines_use_monotonic_clock_and_custom_duration
    [1000, 2000].each do |duration|
      @now = 0.0
      assert_equal :execute, gate.wait(duration)
      assert_equal duration / 1000.0, @now
      assert_clean
    end
  end

  def test_zero_has_no_terminal_effects_or_reads
    assert_equal :execute, gate.wait(0)
    assert_empty @reads
    assert_empty @output.string
    assert_clean
  end

  def test_escape_cancels_and_cleans_up
    assert_equal :edit, gate([[0.1, "\e"]]).wait(1000)
    assert_operator @now, :<, 1.0
    assert_clean
  end

  def test_arrows_and_enter_are_rejected_with_feedback_and_do_not_cancel
    events = [[0.1, "\e"], [0, "["], [0, "A"], [0.1, "\r"], [0.1, "x"]]
    assert_equal :execute, gate(events).wait(1000)
    assert_equal 1.0, @now
    assert_equal 3, @output.string.count("\a")
    assert_includes @output.string, "Tuş yok sayıldı"
    assert_clean
  end

  def test_ctrl_c_and_eof_cancel_without_execution
    ["\x03", :eof].each do |byte|
      assert_equal :cancel, gate([[0.1, byte]]).wait(1000)
      assert_clean
    end
  end

  def test_ctrl_c_inside_an_escape_sequence_still_cancels
    assert_equal :cancel, gate([[0.1, "\e"], [0, "["], [0, "\x03"]]).wait(1000)
    assert_clean
  end

  def test_a_spurious_reader_wakeup_cannot_execute_early
    assert_equal :execute, gate([[0.1, nil]]).wait(1000)
    assert_equal 1.0, @now
  end

  def test_queued_deadline_input_cannot_submit_the_next_prompt
    @input.queued = "accidental\r"
    assert_equal :execute, gate.wait(1000)
    assert_empty @input.queued
    assert_includes @output.string, "tuşlar yok sayıldı"
    assert_clean
  end

  def test_escape_received_at_deadline_has_only_one_outcome
    assert_equal :edit, gate([[1.0, "\e"]]).wait(1000)
    assert_clean
    @now = 0
    assert_equal :execute, gate.wait(1000)
    assert_clean
  end

  def test_reader_errors_restore_terminal_and_context
    broken = Rubik::REPL::PromptGrace.new(input: @input, output: @output, context: @ctx,
                                          reader: ->(_) { raise IOError, "broken" })
    assert_raises(IOError) { broken.wait(1000) }
    assert_clean
  end

  def test_interrupt_restores_terminal
    interrupted = Rubik::REPL::PromptGrace.new(input: @input, output: @output, context: @ctx,
                                               reader: ->(_) { raise Interrupt })
    assert_equal :cancel, interrupted.wait(1000)
    assert_clean
  end

  def test_repeated_cancellation_does_not_accumulate_resources
    20.times do
      assert_equal :edit, gate([[0, "\e"]]).wait(1000)
      assert_clean
    end
  end

  def assert_clean
    assert_equal :cooked, @input.console_mode
    assert_equal 0, @ctx.disposable_count
  end
end
