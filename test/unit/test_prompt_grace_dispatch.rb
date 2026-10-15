# frozen_string_literal: true

require_relative "../test_helper"

class TestPromptGraceDispatch < Minitest::Test
  class Target
    include Rubik::REPL::InputLoop

    attr_reader :executed, :config, :reline

    def initialize
      @interactive_prompt_loop = true
      @config = { "ui.prompt_grace_window_ms" => 1000 }
      @executed = []
      @reline = Module.new
      @reline.const_set(:HISTORY, [])
    end

    def interactive_input? = true
    def execute_input(text) = @executed << text
    def stop = nil
    def history = @reline::HISTORY
  end

  def setup
    @target = Target.new
    @durations = []
    @outcomes = [:execute]
    @gate = Object.new
    test = self
    @gate.define_singleton_method(:wait) do |duration|
      test.instance_variable_get(:@durations) << duration
      test.instance_variable_get(:@outcomes).shift || :execute
    end
  end

  def with_gate(&)
    Rubik::REPL::PromptGrace.stub(:new, @gate, &)
  end

  def test_normal_paste_burst_explicit_paste_and_heredoc_use_one_gate
    with_gate do
      @target.process_normal_line("normal", [])
      @target.define_singleton_method(:read_paste_block) { "  α\nβ  \n" }
      @target.run_paste_mode
      @target.process_heredoc_line("EOF", ["  α", "β  ", ""], "EOF")
      @target.define_singleton_method(:paste_clock) { 0.0 }
      @target.define_singleton_method(:safe_readline) { |*_, **_| nil }
      @target.collect_paste_burst("burst")
    end
    assert_equal [1000] * 4, @durations
    assert_equal ["normal", "  α\nβ  \n", "  α\nβ  \n", "burst"], @target.executed
  end

  def test_cancellation_does_not_dispatch_or_add_history_and_resubmission_is_fresh
    @outcomes = [:edit, :execute]
    with_gate do
      @target.process_normal_line("original", [])
      assert_empty @target.executed
      assert_empty @target.history
      assert_equal "original", @target.instance_variable_get(:@prompt_restore)
      @target.process_normal_line("edited", [])
    end
    assert_equal [1000, 1000], @durations
    assert_equal ["edited"], @target.executed
    assert_equal ["edited"], @target.history
  end

  def test_bangs_exits_noninteractive_replay_and_stream_bypass_the_gate
    with_gate do
      @target.process_normal_line("!help", [])
      @target.process_normal_line("exit", [])
      @target.run_stream(StringIO.new("stream\n")) # @running is not set; use direct stream seam below
      @target.process_multiline_or_line("stream")
      @target.instance_variable_set(:@interactive_prompt_loop, false)
      @target.process_normal_line("programmatic", [])
      @target.instance_variable_set(:@interactive_prompt_loop, true)
      @target.instance_variable_set(:@replaying, true)
      @target.process_normal_line("replay", [])
    end
    assert_empty @durations
    assert_equal ["!help", "stream", "programmatic", "replay"], @target.executed
  end

  def test_config_is_read_for_each_submission_and_snapshot_passed_to_gate
    with_gate do
      @target.process_normal_line("one", [])
      @target.config["ui.prompt_grace_window_ms"] = 2000
      @target.process_normal_line("two", [])
      @target.config["ui.prompt_grace_window_ms"] = 0
      @target.process_normal_line("three", [])
    end
    assert_equal [1000, 2000, 0], @durations
    assert_equal ["one", "two", "three"], @target.executed
  end

  def test_multiline_text_containing_a_heredoc_example_is_a_single_prompt
    text = "Explain this:\n<<EOF\n  α\nEOF\n"
    with_gate { @target.process_normal_line(text, []) }
    assert_equal [text], @target.executed
    assert_equal [1000], @durations
  end

  def test_restoration_preserves_text_and_blocks_reactive_enter_injection
    text = "  α\n世界  \n"
    @target.instance_variable_set(:@prompt_restore, text)
    reline = @target.reline
    reline.singleton_class.attr_accessor :pre_input_hook, :inserted
    previous = -> {}
    reline.pre_input_hook = previous
    reline.define_singleton_method(:insert_text) { |value| self.inserted = value }
    reline.define_singleton_method(:line_buffer) { "" }
    reline.define_singleton_method(:ungetc) { |_| raise "must not inject Enter" }
    guard = Rubik::REPL::TerminalGuard.new(reline: reline, output: StringIO.new)
    @target.instance_variable_set(:@terminal_guard, guard)
    context = Rubik::Runtime::Context.new
    @target.instance_variable_set(:@runtime_manager, Struct.new(:context).new(context))
    reline.define_singleton_method(:readmultiline) do |*_, &confirm|
      raise "unsafe reactive wake" if guard.safe_wakeup!

      pre_input_hook.call
      raise "termination must require Enter" unless confirm.call(inserted)

      "#{inserted}edited"
    end

    assert_equal "#{text}edited", @target.safe_readline("> ")
    assert_equal text, reline.inserted
    assert_same previous, reline.pre_input_hook
    assert_equal 0, context.disposable_count
    refute guard.reading?
    assert_empty @target.executed
  end
end
