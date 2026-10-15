# frozen_string_literal: true

require "io/console"
require "io/wait"
require_relative "../runtime/context"

module Rubik
  module REPL
    # Synchronous admission gate: no task, recorder entry or delayed callback
    # exists until this returns :execute. A temporary context owns all terminal
    # effects and is pruned from its parent on every exit.
    class PromptGrace
      ESCAPE_TIMEOUT = 0.03
      STATUS = "Gönderiliyor… Esc: düzenlemeye dön"

      def initialize(input:, output:, context: nil, clock: nil, reader: nil)
        @input = input
        @output = output
        @context = context
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @reader = reader || method(:read_byte)
      end

      def wait(milliseconds)
        return :execute if milliseconds.zero?

        scope = @context ? @context.extend : Rubik::Runtime::Context.new
        mode = @input.console_mode
        scope.on_dispose { @input.console_mode = mode }
        @input.raw!
        scope.on_dispose do
          @output.print "\r\e[2K"
          @output.flush
        end
        @output.print STATUS
        @output.flush
        deadline = @clock.call + (milliseconds / 1000.0)
        loop do
          remaining = deadline - @clock.call
          if remaining <= 0
            # A burst arriving at the deadline can leave bytes queued after
            # the last processed key. Do not let its Enter submit a later turn.
            if @input.respond_to?(:nread) && @input.nread.positive?
              @input.iflush
              @output.print "\a\r\e[2K[Rubik] Bekleme sırasında gelen tuşlar yok sayıldı.\r\n"
            end
            return :execute
          end

          byte = @reader.call(remaining)
          next if byte.nil?
          return :cancel if [:eof, "\x03"].include?(byte)

          if byte == "\e"
            escape = classify_escape
            return escape unless escape == :sequence
          end

          # Other keys are intentionally rejected, with immediate feedback.
          # Enter never leaks into the next readline as an accidental submit.
          @output.print "\a\r\e[2K#{STATUS} · Tuş yok sayıldı"
          @output.flush
        end
      rescue Interrupt
        :cancel
      ensure
        scope&.dispose
      end

      private

      def read_byte(timeout)
        return nil unless @input.wait_readable(timeout)

        @input.read_nonblock(1)
      rescue IO::WaitReadable
        nil
      rescue EOFError
        :eof
      end

      # CSI/SS3 arrows and function keys start with Esc too. Resolve this
      # ambiguity even when Esc arrives just before the submission deadline.
      def classify_escape
        following = @reader.call(ESCAPE_TIMEOUT)
        return :edit if following.nil? || following == :eof
        return :cancel if following == "\x03"
        return :sequence unless ["[", "O"].include?(following)

        deadline = @clock.call + ESCAPE_TIMEOUT
        loop do
          remaining = deadline - @clock.call
          break if remaining <= 0

          byte = @reader.call(remaining)
          return :cancel if byte == "\x03"
          break if byte.nil? || byte == :eof || byte.match?(/[\x40-\x7e]/)
        end
        :sequence
      end
    end
  end
end
