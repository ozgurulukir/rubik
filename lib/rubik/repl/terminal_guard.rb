# frozen_string_literal: true

require "monitor"

module Rubik
  module REPL
    # Guard protecting Reline input buffer and screen from asynchronous background notices (Plan 105).
    # When Reline is actively reading, notices clear the current line (\r\e[2K), print cleanly,
    # and call Reline.redisplay to restore the prompt and in-progress user input buffer.
    # When idle, notices are output directly. Supports quiet inbox buffering.
    class TerminalGuard
      include MonitorMixin

      attr_accessor :quiet, :output, :reline

      def initialize(output: $stdout, reline: Reline, quiet: false)
        super()
        @output = output
        @reline = reline
        @quiet = quiet
        @reading = false
        @inbox = []
      end

      def reading?
        synchronize { @reading }
      end

      def with_reading
        synchronize { @reading = true }
        yield
      ensure
        synchronize { @reading = false }
      end

      def print_safe_notice(text, force: false)
        return false if text.nil? || text.to_s.empty?

        clean_text = text.to_s.sub(/\A\n+/, "")

        synchronize do
          if @quiet && !force
            @inbox << clean_text
            return false
          end

          if @reading
            @output.print "\r\e[2K"
            @output.puts clean_text
            begin
              @reline.redisplay if @reline.respond_to?(:redisplay)
            rescue StandardError
              nil
            end
          else
            @output.puts clean_text
          end
          @output.flush if @output.respond_to?(:flush)
          true
        end
      end

      def quiet?
        synchronize { @quiet }
      end

      def inbox
        synchronize { @inbox.dup }
      end

      def flush_inbox!
        synchronize do
          items = @inbox.dup
          @inbox.clear
          items
        end
      end

      def flush_notices!
        items = flush_inbox!
        return false if items.empty?

        synchronize do
          if @reading
            @output.print "\r\e[2K"
            items.each { |item| @output.puts item }
            begin
              @reline.redisplay if @reline.respond_to?(:redisplay)
            rescue StandardError
              nil
            end
          else
            items.each { |item| @output.puts item }
          end
          @output.flush if @output.respond_to?(:flush)
        end
        true
      end
    end
  end
end
