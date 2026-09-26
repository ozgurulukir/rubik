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
        @collecting = false
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
            redisplay_cleanly
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
            redisplay_cleanly
          else
            items.each { |item| @output.puts item }
          end
          @output.flush if @output.respond_to?(:flush)
        end
        true
      end

      # Plan 109: true when Reline is blocked reading AND the in-progress
      # line is empty — the only state where an injected Enter submits an
      # EMPTY line and cannot truncate user typing. respond_to? guards
      # follow the redisplay_cleanly pattern: a double without
      # line_buffer cannot prove emptiness, so it reads as "not idle"
      # (never wake).
      def idle_and_empty?
        synchronize do
          return false unless @reading
          return false unless @reline.respond_to?(:line_buffer)

          @reline.line_buffer.to_s.strip.empty?
        end
      end

      # Plan 109: wake a blocked empty readline by injecting an Enter.
      # Reline 0.7.0's IO gates (ANSI/Windows/Dumb) all poll and re-check
      # their ungetc buffer (10ms/100ms/100ms), so the injection reaches
      # the blocked reader on every gate. idle_and_empty? is re-evaluated
      # inside this critical section (Monitor reentrancy makes the nested
      # synchronize free); the residual window between check and gate
      # consumption is inherent to Reline's thread model and accepted. A
      # failing ungetc degrades to false — never raises into the kworker.
      # with_reading never holds this monitor during readline, so this
      # cannot deadlock with the reader.
      def safe_wakeup!
        synchronize do
          return false if @collecting
          return false unless idle_and_empty?
          return false unless @reline.respond_to?(:ungetc)

          begin
            @reline.ungetc("\n".ord)
          rescue StandardError
            return false
          end
          true
        end
      end

      # Plan 109: paste collectors (explicit !paste block, paste-burst
      # join) set this so a reactive wake can never inject a blank Enter
      # into the user's pasted text — the wake defers to the next regular
      # prompt instead.
      def with_collecting
        synchronize { @collecting = true }
        yield
      ensure
        synchronize { @collecting = false }
      end

      private

      def redisplay_cleanly
        if @reline.respond_to?(:line_editor) && @reline.line_editor
          le = @reline.line_editor
          le.send(:clear_rendered_screen_cache) if le.respond_to?(:clear_rendered_screen_cache, true)
        end
        @reline.redisplay if @reline.respond_to?(:redisplay)
      rescue StandardError
        nil
      end
    end
  end
end
