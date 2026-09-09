# frozen_string_literal: true

require "tty-spinner"

module Rubik
  module UI
    # Live status spinner shown while the orchestrator queries the LLM:
    # cycling Turkish verbs (Claude-Code-style) plus elapsed seconds, drawn
    # on a single terminal line. Owns a background thread whose lifecycle is
    # tied to #stop/#kill; the Runtime RenderService registers `kill` as a
    # context inverse so disposed shells never leak spinner threads.
    class Spinner
      TICK_SECONDS = 0.12
      ELAPSED_STEP = 1.0

      def initialize(io, theme, config: nil)
        @io = io
        @theme = theme
        @config = config
        @thread = nil
        @mutex = Mutex.new
        @spinner = nil
        @started_at = nil
        @last_elapsed_shown = -1
      end

      def enabled?
        @config ? @config.fetch("ui.spinner", true) != false : true
      end

      def spinning?
        @thread&.alive? == true
      end

      # Starts spinning with the next verb from the theme's rotation.
      # No-op when the surface is disabled (non-TTY, tests, quiet terminals).
      def start(step: nil, max_steps: nil)
        return unless enabled?
        return if spinning?

        verb = next_verb
        step_part = step && max_steps ? " [#{step}/#{max_steps}]" : ""
        @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @last_elapsed_shown = -1

        @mutex.synchronize do
          # The message template carries :spinner and :msg tokens so #update
          # actually substitutes the verb/step/elapsed text; `clear: true`
          # makes tty-spinner erase its own line on stop (no stray frame).
          @spinner = TTY::Spinner.new(":spinner :msg", output: @io, format: :spin,
                                                       hide_cursor: true, clear: true)
          @spinner.update(msg: "#{@theme.paint(verb, :accent)}#{step_part}")
          @spinner.spin
        end

        @thread = Thread.new do
          loop do
            sleep TICK_SECONDS
            break unless spinning?

            elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at)
            @mutex.synchronize do
              next unless @spinner && !@spinner.done?

              if elapsed - @last_elapsed_shown >= ELAPSED_STEP
                @last_elapsed_shown = elapsed
                @spinner.update(msg: current_message(verb, step_part, elapsed))
              end
              @spinner.spin
            rescue StandardError => e
              # A dead tick thread must not take the REPL down, but the
              # failure is never silent (AGENTS.md §5): report, then exit.
              warn "[rubik] spinner tick failed: #{e.class}: #{e.message}"
              Thread.exit
            end
          end
        end
      end

      # Stops the spinner and clears its line so the caller can print freely.
      # `final:` optionally leaves a completion note on the cleared line.
      def stop(final: nil)
        thread = @thread
        @thread = nil
        thread&.kill
        thread&.join(0.3)

        @mutex.synchronize do
          if @spinner
            begin
              @spinner.stop
              @io.print(final) unless final.nil?
              @io.flush if @io.respond_to?(:flush)
            rescue StandardError => e
              # Cleanup must never mask the caller's in-flight exception
              # (AGENTS.md §5): report the IO failure and still nil @spinner
              # so repeated stops stay idempotent.
              warn "[rubik] spinner cleanup failed: #{e.class}: #{e.message}"
            ensure
              @spinner = nil
            end
          end
        end
      end
      alias kill stop
      alias dispose stop

      def current_message(verb, step_part, elapsed)
        seconds = elapsed.to_i
        suffix = seconds.positive? ? " · #{seconds}s" : ""
        "#{@theme.paint(verb, :accent)}#{step_part}#{suffix} (ctrl+c: kes)"
      end

      def next_verb
        @verb_index = ((@verb_index || -1) + 1) % @theme.spinner_verbs.size
        @theme.spinner_verbs[@verb_index]
      end
    end
  end
end
