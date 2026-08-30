# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestREPL < Minitest::Test
  def setup
    @output = StringIO.new
    @shell = Rubik::REPL::Shell.new(output: @output)
  end

  def test_help_command_lists_default_commands
    @shell.execute_input("!help")
    out = @output.string
    assert_includes out, "!help"
    assert_includes out, "!status"
    assert_includes out, "!quit"
  end

  def test_unknown_command_shows_error
    @shell.execute_input("!unknown_cmd")
    assert_includes @output.string, "Bilinmeyen komut: !unknown_cmd"
    assert_includes @output.string, "Kullanılabilir komutlar:"
  end

  def test_hooks_execution_order_and_resilience
    hook_calls = []

    @shell.hooks.register(:before_command) { |cmd, _| hook_calls << "before_#{cmd}" }
    @shell.hooks.register(:before_command) { raise "Hook error!" }
    @shell.hooks.register(:after_command) { |cmd, _| hook_calls << "after_#{cmd}" }

    @shell.execute_input("!status")

    assert_equal ["before_status", "after_status"], hook_calls
  end

  def test_stream_input_execution
    stream = StringIO.new("!status\n!quit\n")
    @shell.run(stream)
    assert_includes @output.string, "Model:"
  end

  def test_inline_shift_operator_does_not_trigger_heredoc
    executed_inputs = []
    @shell.define_singleton_method(:execute_input) do |text|
      executed_inputs << text
    end

    # Mock Reline with inline << operator lines
    lines = ["arr << item", "x = a << 1", "exit"]
    Reline.stub(:readline, ->(_prompt, _add_hist) { lines.shift }) do
      @shell.run_interactive
    end

    assert_includes executed_inputs, "arr << item"
    assert_includes executed_inputs, "x = a << 1"
  end

  def test_explicit_heredoc_multiline_block
    executed_inputs = []
    @shell.define_singleton_method(:execute_input) do |text|
      executed_inputs << text
    end

    lines = ["<<EOF", "line 1", "line 2", "EOF", "exit"]
    Reline.stub(:readline, ->(_prompt, _add_hist) { lines.shift }) do
      @shell.run_interactive
    end

    assert_equal 1, executed_inputs.size
    assert_equal "line 1\nline 2", executed_inputs.first
  end

  def test_eof_or_ctrl_d_stops_interactive_loop
    lines = ["\x04"] # Ctrl+D ascii
    Reline.stub(:readline, ->(_prompt, _add_hist) { lines.shift }) do
      @shell.run_interactive
    end
  end

  def test_sigint_trap_is_installed_during_interactive_run
    # Probe what run_interactive installs for SIGINT: it must raise Interrupt.
    lines = ["!status", "\x04"]
    recorder = {}
    original_trap = Signal.method(:trap)
    Signal.singleton_class.send(:define_method, :trap) do |sig, cmd = nil, &blk|
      # Capture only the handler run_interactive installs (passed as a block).
      # Ignore the restore call which passes the previous handler positionally.
      recorder[sig] ||= blk if sig == "INT" && blk
      # no-op default so we do not disturb other signals
      original_trap.call(sig, blk || cmd || proc {})
    end
    begin
      Reline.stub(:readline, ->(_p, _h) { lines.shift }) do
        @shell.run_interactive
      end
    ensure
      Signal.singleton_class.send(:define_method, :trap, original_trap)
    end
    refute_nil recorder["INT"], "run_interactive should install a SIGINT handler"
    assert_raises(Interrupt) { recorder["INT"].call }
    refute @shell.running?
  end

  def test_restore_console_after_interrupt_resets_line_editor_on_real_console
    # Regression guard: on a real (non-dumb) console the helper must actually
    # reset Reline's line editor instead of returning early. A no-op here is
    # exactly the bug that lets the prompt freeze after Ctrl+C on Windows.
    skip if Reline::IOGate.dumb?

    fake_le = Object.new
    def fake_le.reset(*_args)
      @called = true
    end

    def fake_le.called?
      @called
    end
    Reline.stub(:line_editor, fake_le) do
      Rubik::REPL::InterruptHandler.restore_console_after_interrupt
    end
    assert fake_le.called?, "restore_console_after_interrupt should reset the line editor on a real console"
  end

  def test_restore_console_after_interrupt_runs_real_reline_reset_without_raising
    # Regression guard for the swallowed ArgumentError: the helper swallows
    # StandardError by design, so a naive "completes without raising" test
    # passes even against the buggy arity call. This spy wraps reline's REAL
    # LineEditor#reset and records every probe the arity chain makes. An
    # early probe may legitimately raise on reline versions whose signature
    # differs (e.g. 0.6.x `reset(prompt='')` rejects the encoding kwarg) —
    # the chain is designed to rescue and retry — so the guard only fails
    # when EVERY probe raised: the chain never landed a clean reset and
    # console restoration silently no-oped.
    le = Reline.line_editor
    skip "Reline.line_editor is nil in this process" if le.nil?

    probes = []
    le.define_singleton_method(:reset) do |*args, **kwargs, &blk|
      super(*args, **kwargs, &blk)
      probes << { args: args, kwargs: kwargs, error: nil }
    rescue StandardError => e
      probes << { args: args, kwargs: kwargs, error: "#{e.class}: #{e.message}" }
      raise
    end
    begin
      Rubik::REPL::InterruptHandler.restore_console_after_interrupt
      assert probes.any?, "real LineEditor#reset should have been invoked"
      assert probes.any? { |p| p[:error].nil? },
             "every LineEditor#reset probe raised — the arity chain never recovered: " \
             "#{probes.filter_map { |p| p[:error] }.join(' | ')}"
    ensure
      begin
        le.singleton_class.remove_method(:reset)
      rescue
        nil
      end
    end
  end

  def test_restore_console_after_interrupt_clears_iogate_buffers
    return unless defined?(Reline::IOGate) && Reline::IOGate

    io = Reline::IOGate
    io.instance_variable_set(:@output_buf, [3, 13])
    io.instance_variable_set(:@input_buf, [65, 66])
    io.instance_variable_set(:@hsg, 55_296)

    Rubik::REPL::InterruptHandler.restore_console_after_interrupt

    assert_empty io.instance_variable_get(:@output_buf), "restore_console_after_interrupt must purge @output_buf"
    assert_empty io.instance_variable_get(:@input_buf), "restore_console_after_interrupt must purge @input_buf"
    assert_nil io.instance_variable_get(:@hsg), "restore_console_after_interrupt must reset high surrogate state"
  end

  def test_execute_command_interrupt_handled_gracefully
    @shell.register_command("hang_cmd", description: "test hang") do
      raise Interrupt
    end

    @shell.execute_input("!hang_cmd")
    assert_includes @output.string, "Komut kullanıcı tarafından iptal edildi (^C)"
  end
end
