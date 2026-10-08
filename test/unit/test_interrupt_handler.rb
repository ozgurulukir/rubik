# frozen_string_literal: true

require_relative "../test_helper"

class TestInterruptHandler < Minitest::Test
  def setup
    @original_line_editor = Reline.respond_to?(:line_editor) ? Reline.line_editor : nil
  end

  def with_stubbed_const(mod, const_name, value)
    had_const = mod.const_defined?(const_name, false)
    old_value = mod.const_get(const_name) if had_const
    mod.send(:remove_const, const_name) if had_const
    mod.const_set(const_name, value)
    yield
  ensure
    mod.send(:remove_const, const_name) if mod.const_defined?(const_name, false)
    mod.const_set(const_name, old_value) if had_const
  end

  # --- Handler Lifecycle Tests ---

  def test_install_and_restore_signal_trap
    original_handler = Signal.trap("INT", "DEFAULT")
    begin
      installed_handler = Rubik::REPL::InterruptHandler.install
      current_handler = Signal.trap("INT", "DEFAULT")

      Rubik::REPL::InterruptHandler.restore(installed_handler)

      assert_kind_of Proc, current_handler
      assert_raises(Interrupt) { current_handler.call }
    ensure
      Signal.trap("INT", original_handler)
    end
  end

  def test_with_handler_runs_block_and_restores
    restored_called = false
    original_handler = Signal.trap("INT", "DEFAULT")

    Rubik::REPL::InterruptHandler.stub(:restore_console_after_interrupt, -> { restored_called = true }) do
      Rubik::REPL::InterruptHandler.with_handler do
        # Inside block
      end
    end

    assert restored_called, "with_handler must invoke restore_console_after_interrupt in ensure"
  ensure
    Signal.trap("INT", original_handler)
  end

  # --- Line Editor Reset Arity Chain & Fallbacks ---

  def test_restore_console_line_editor_reset_with_encoding_kwarg
    calls = []
    fake_le = Object.new
    fake_le.define_singleton_method(:reset) do |prompt = "", encoding: Encoding.default_external|
      calls << { prompt: prompt, encoding: encoding }
    end

    Reline.stub(:line_editor, fake_le) do
      Rubik::REPL::InterruptHandler.restore_console_after_interrupt
    end

    assert_equal 1, calls.size
    assert_equal "", calls.first[:prompt]
    refute_nil calls.first[:encoding]
  end

  def test_restore_console_line_editor_fallback_to_positional_string
    calls = []
    fake_le = Object.new
    fake_le.define_singleton_method(:reset) do |*args, **kwargs|
      if kwargs.any?
        raise ArgumentError, "unknown keyword: :encoding"
      end

      calls << args
    end

    Reline.stub(:line_editor, fake_le) do
      Rubik::REPL::InterruptHandler.restore_console_after_interrupt
    end

    assert_equal 1, calls.size
    assert_equal [""], calls.first
  end

  def test_restore_console_line_editor_fallback_to_no_args
    calls = []
    fake_le = Object.new
    fake_le.define_singleton_method(:reset) do |*args, **kwargs|
      if kwargs.any? || args.any?
        raise ArgumentError, "wrong number of arguments"
      end

      calls << :reset_called
    end

    Reline.stub(:line_editor, fake_le) do
      Rubik::REPL::InterruptHandler.restore_console_after_interrupt
    end

    assert_equal [:reset_called], calls
  end

  def test_restore_console_line_editor_fallback_to_reset_line
    calls = []
    fake_le = Object.new
    fake_le.define_singleton_method(:reset_line) do
      calls << :reset_line_called
    end

    Reline.stub(:line_editor, fake_le) do
      Rubik::REPL::InterruptHandler.restore_console_after_interrupt
    end

    assert_equal [:reset_line_called], calls
  end

  def test_restore_console_handles_line_editor_exception_gracefully
    fake_le = Object.new
    fake_le.define_singleton_method(:reset) do |*_args, **_kwargs|
      raise StandardError, "line editor reset crash"
    end

    Reline.stub(:line_editor, fake_le) do
      Rubik::REPL::InterruptHandler.restore_console_after_interrupt
    end
  end

  # --- IOGate Buffer Purging ---

  def test_restore_console_clears_iogate_buffers_and_hsg
    return unless defined?(Reline::IOGate) && Reline::IOGate

    io = Reline::IOGate
    old_out = io.instance_variable_defined?(:@output_buf) ? io.instance_variable_get(:@output_buf) : nil
    old_in = io.instance_variable_defined?(:@input_buf) ? io.instance_variable_get(:@input_buf) : nil
    old_hsg = io.instance_variable_defined?(:@hsg) ? io.instance_variable_get(:@hsg) : nil

    begin
      io.instance_variable_set(:@output_buf, ["\e[2J", "a", "b"])
      io.instance_variable_set(:@input_buf, [3, 4, 13])
      io.instance_variable_set(:@hsg, 55_296)

      Rubik::REPL::InterruptHandler.restore_console_after_interrupt

      assert_empty io.instance_variable_get(:@output_buf), "output buffer must be cleared"
      assert_empty io.instance_variable_get(:@input_buf), "input buffer must be cleared"
      assert_nil io.instance_variable_get(:@hsg), "hsg state must be set to nil"
    ensure
      io.instance_variable_set(:@output_buf, old_out) if old_out
      io.instance_variable_set(:@input_buf, old_in) if old_in
      io.instance_variable_set(:@hsg, old_hsg) if old_hsg
    end
  end

  def test_restore_console_iogate_non_array_buffers
    return unless defined?(Reline::IOGate) && Reline::IOGate

    io = Reline::IOGate
    old_out = io.instance_variable_defined?(:@output_buf) ? io.instance_variable_get(:@output_buf) : nil
    old_in = io.instance_variable_defined?(:@input_buf) ? io.instance_variable_get(:@input_buf) : nil

    begin
      io.instance_variable_set(:@output_buf, "not an array")
      io.instance_variable_set(:@input_buf, nil)

      Rubik::REPL::InterruptHandler.restore_console_after_interrupt
    ensure
      io.instance_variable_set(:@output_buf, old_out) if old_out
      io.instance_variable_set(:@input_buf, old_in) if old_in
    end
  end

  # --- Windows Specific Console Handle Refresh & Buffer Flushing ---

  def test_restore_console_windows_handle_refresh_and_flushing
    fake_windows = Module.new
    fake_windows.const_set(:STD_INPUT_HANDLE, -10)
    fake_windows.const_set(:STD_OUTPUT_HANDLE, -11)
    fake_windows.const_set(:Win32API, Class.new)

    fake_io = Object.new
    fake_io.define_singleton_method(:is_a?) do |klass|
      klass == fake_windows || super(klass)
    end

    get_std_handle_calls = []
    fake_get_std_handle = proc do |std_handle_id|
      get_std_handle_calls << std_handle_id
      std_handle_id == -10 ? 201 : 202
    end
    fake_io.instance_variable_set(:@GetStdHandle, fake_get_std_handle)

    flush_calls = []
    fake_flush = proc do |handle|
      flush_calls << handle
    end
    fake_io.instance_variable_set(:@FlushConsoleInputBuffer, fake_flush)

    Reline.stub(:line_editor, nil) do
      if defined?(Reline::IOGate)
        with_stubbed_const(Reline, :Windows, fake_windows) do
          with_stubbed_const(Reline, :IOGate, fake_io) do
            Rubik::REPL::InterruptHandler.restore_console_after_interrupt
          end
        end
      end
    end

    if defined?(Reline::IOGate)
      assert_equal [-10, -11], get_std_handle_calls
      assert_equal 201, fake_io.instance_variable_get(:@hConsoleInputHandle)
      assert_equal 202, fake_io.instance_variable_get(:@hConsoleHandle)
      assert_equal [201], flush_calls
    end
  end

  def test_restore_console_windows_instantiates_win32_api_when_flush_func_missing
    fake_win32_api_class = Class.new do
      attr_reader :args

      def initialize(*args)
        @args = args
      end

      def call(handle)
        @called_with = handle
      end
    end

    fake_windows = Module.new
    fake_windows.const_set(:STD_INPUT_HANDLE, -10)
    fake_windows.const_set(:STD_OUTPUT_HANDLE, -11)
    fake_windows.const_set(:Win32API, fake_win32_api_class)

    fake_io = Object.new
    fake_io.define_singleton_method(:is_a?) do |klass|
      klass == fake_windows || super(klass)
    end

    fake_get_std_handle = proc do |std_handle_id|
      std_handle_id == -10 ? 301 : 302
    end
    fake_io.instance_variable_set(:@GetStdHandle, fake_get_std_handle)

    Reline.stub(:line_editor, nil) do
      if defined?(Reline::IOGate)
        with_stubbed_const(Reline, :Windows, fake_windows) do
          with_stubbed_const(Reline, :IOGate, fake_io) do
            Rubik::REPL::InterruptHandler.restore_console_after_interrupt
          end
        end
      end
    end

    if defined?(Reline::IOGate)
      flush_func = fake_io.instance_variable_get(:@FlushConsoleInputBuffer)
      refute_nil flush_func
      assert_kind_of fake_win32_api_class, flush_func
      assert_equal ["kernel32", "FlushConsoleInputBuffer", ["L"], "I"], flush_func.args
    end
  end

  def test_restore_console_windows_handle_refresh_handles_get_std_handle_error
    fake_windows = Module.new
    fake_windows.const_set(:STD_INPUT_HANDLE, -10)
    fake_windows.const_set(:STD_OUTPUT_HANDLE, -11)

    fake_io = Object.new
    fake_io.define_singleton_method(:is_a?) { |klass| klass == fake_windows }

    fake_get_std_handle = proc do |_std_handle_id|
      raise StandardError, "Win32 handle access error"
    end
    fake_io.instance_variable_set(:@GetStdHandle, fake_get_std_handle)

    if defined?(Reline::IOGate)
      with_stubbed_const(Reline, :Windows, fake_windows) do
        with_stubbed_const(Reline, :IOGate, fake_io) do
          Rubik::REPL::InterruptHandler.restore_console_after_interrupt
        end
      end
      assert_nil fake_io.instance_variable_get(:@hConsoleInputHandle)
    end
  end

  def test_restore_console_windows_flushing_handles_flush_error
    fake_windows = Module.new
    fake_windows.const_set(:STD_INPUT_HANDLE, -10)
    fake_windows.const_set(:STD_OUTPUT_HANDLE, -11)

    fake_io = Object.new
    fake_io.define_singleton_method(:is_a?) { |klass| klass == fake_windows }

    fake_io.instance_variable_set(:@GetStdHandle, proc { |id| id })
    fake_io.instance_variable_set(:@FlushConsoleInputBuffer, proc { |_handle| raise StandardError, "Flush failed" })

    if defined?(Reline::IOGate)
      with_stubbed_const(Reline, :Windows, fake_windows) do
        with_stubbed_const(Reline, :IOGate, fake_io) do
          Rubik::REPL::InterruptHandler.restore_console_after_interrupt
        end
      end
    end
  end

  # --- Top-Level Edge Cases ---

  def test_restore_console_when_line_editor_nil
    Reline.stub(:line_editor, nil) do
      Rubik::REPL::InterruptHandler.restore_console_after_interrupt
    end
  end

  def test_restore_console_swallows_top_level_standard_error
    Reline.stub(:respond_to?, ->(_method) { raise StandardError, "Catastrophic reline error" }) do
      Rubik::REPL::InterruptHandler.restore_console_after_interrupt
    end
  end
end
