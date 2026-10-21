# frozen_string_literal: true

require_relative "../test_helper"

class TestReplInterruptHandler < Minitest::Test
  def test_install_registers_sigint_trap_and_block_raises_interrupt
    trapped_sig = nil
    trapped_block = nil
    previous_handler = "DEFAULT"

    Signal.stub(:trap, lambda { |sig, &block|
      trapped_sig = sig
      trapped_block = block
      previous_handler
    }) do
      result = Rubik::REPL::InterruptHandler.install
      assert_equal "INT", trapped_sig
      assert_equal previous_handler, result
      refute_nil trapped_block, "install should pass a block to Signal.trap"
      assert_raises(Interrupt) { trapped_block.call }
    end
  end

  def test_restore_reinstalls_previous_handler_when_present
    trapped_args = nil

    Signal.stub(:trap, ->(sig, handler) { trapped_args = [sig, handler] }) do
      Rubik::REPL::InterruptHandler.restore("DEFAULT")
      assert_equal ["INT", "DEFAULT"], trapped_args
    end
  end

  def test_restore_does_nothing_when_prev_handler_is_nil
    called = false

    Signal.stub(:trap, ->(*_args) { called = true }) do
      Rubik::REPL::InterruptHandler.restore(nil)
      refute called, "restore(nil) must not invoke Signal.trap"
    end
  end

  def test_with_handler_installs_yields_restores_and_resets_console
    installed = false
    restored_handler = nil
    console_restored = false
    old_handler = "OLD_TRAP_HANDLER"

    Signal.stub(:trap, lambda { |_sig, handler = nil, &blk|
      if blk
        installed = true
        old_handler
      else
        restored_handler = handler
      end
    }) do
      Rubik::REPL::InterruptHandler.stub(:restore_console_after_interrupt, -> { console_restored = true }) do
        yielded = false
        Rubik::REPL::InterruptHandler.with_handler do
          yielded = true
          assert installed, "Signal handler should be installed before yielding"
        end

        assert yielded, "with_handler must yield to block"
        assert_equal old_handler, restored_handler, "with_handler must restore previous handler"
        assert console_restored, "with_handler must restore console state after block execution"
      end
    end
  end

  def test_with_handler_ensures_restore_and_console_reset_on_exception
    restored_handler = nil
    console_restored = false
    old_handler = "PREV_TRAP_HANDLER"

    Signal.stub(:trap, lambda { |_sig, handler = nil, &blk|
      blk ? old_handler : (restored_handler = handler)
    }) do
      Rubik::REPL::InterruptHandler.stub(:restore_console_after_interrupt, -> { console_restored = true }) do
        assert_raises(Interrupt) do
          Rubik::REPL::InterruptHandler.with_handler do
            raise Interrupt
          end
        end

        assert_equal old_handler, restored_handler, "ensure block must restore signal handler on exception"
        assert console_restored, "ensure block must reset console on exception"
      end
    end
  end

  def test_restore_console_after_interrupt_resets_line_editor
    skip if defined?(Reline::IOGate) && Reline::IOGate.respond_to?(:dumb?) && Reline::IOGate.dumb?

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
    assert fake_le.called?, "restore_console_after_interrupt should reset the line editor"
  end

  def test_restore_console_after_interrupt_clears_iogate_buffers
    return unless defined?(Reline::IOGate) && Reline::IOGate

    io = Reline::IOGate
    io.instance_variable_set(:@output_buf, [1, 2, 3])
    io.instance_variable_set(:@input_buf, [4, 5, 6])
    io.instance_variable_set(:@hsg, 1234)

    Rubik::REPL::InterruptHandler.restore_console_after_interrupt

    assert_empty io.instance_variable_get(:@output_buf)
    assert_empty io.instance_variable_get(:@input_buf)
    assert_nil io.instance_variable_get(:@hsg)
  end
end
