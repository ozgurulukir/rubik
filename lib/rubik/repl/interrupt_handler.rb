# frozen_string_literal: true

module Rubik
  module REPL
    # Encapsulates Ctrl+C (SIGINT) handling for the interactive REPL loop.
    #
    # On Windows, Reline's default interrupt behavior can leave the line editor
    # in a wedged state after a Ctrl+C: the next prompt neither echoes input nor
    # honors EOF (Ctrl+D / Ctrl+Z), so the REPL appears frozen and cannot be
    # exited. This module installs a SIGINT handler that raises Interrupt (so a
    # running command -- orchestrator loop, HTTP call -- aborts promptly and
    # Reline's own teardown restores console mode) and provides a best-effort
    # line-editor reset to recover an unresponsive prompt.
    module InterruptHandler
      # Install a SIGINT handler that raises Interrupt, returning the previous
      # handler so the caller can restore it on exit. Reline captures this trap
      # as its @old_trap and calls it, so the Interrupt propagates out of
      # Reline.readline cleanly.
      def self.install
        Signal.trap("INT") { raise Interrupt }
      end

      # Restore a previously captured SIGINT handler (value from .install).
      def self.restore(prev_handler)
        Signal.trap("INT", prev_handler) if prev_handler
      end

      # Run a block with the Interrupt-raising SIGINT handler installed, always
      # restoring the previous handler and the console afterwards. Usage:
      #   Rubik::REPL::InterruptHandler.with_handler { ... loop body ... }
      def self.with_handler
        prev = install
        yield
      ensure
        restore(prev)
        restore_console_after_interrupt
      end

      # Best-effort reset of Reline's line editor after an interrupt. On Windows,
      # an interrupted/aborted readline can leave the line editor in a wedged
      # state so the next prompt neither echoes input nor honors EOF. Resetting
      # the editor drops any half-entered buffer so the next Reline.readline
      # re-renders a clean, responsive prompt.
      #
      # NOTE: We intentionally do NOT gate on Reline::IOGate.dumb?, because on
      # this Windows Reline build IOGate.dumb? reports true even for a real
      # console, which would skip the reset and defeat the purpose. We only skip
      # when Reline is unavailable, and we swallow any error so this never raises
      # into the loop.
      def self.restore_console_after_interrupt
        return unless defined?(Reline) && Reline.respond_to?(:line_editor)

        le = Reline.line_editor
        if le.respond_to?(:reset)
          le.reset("", encoding: Encoding::UTF_8)
        elsif le.respond_to?(:reset_line)
          le.reset_line
        end
      rescue StandardError
        nil
      end
    end
  end
end
