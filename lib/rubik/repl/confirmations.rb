# frozen_string_literal: true

module Rubik
  module REPL
    # Interactive confirmation helpers mixed into Shell so every y/n prompt
    # (max-steps continue, !plan approval) routes through Reline with one
    # consistent notion of "interactive". Mixing raw #gets with Reline wedges
    # the prompt on Windows, so all confirmations live here.
    module Confirmations
      # Asks a yes/no question. Non-interactive contexts (tests, piped IO,
      # test-capture tees) short-circuit to the default answer WITHOUT
      # reading input. Returns the downcased answer String ("y"/"n"/...) so
      # call sites keep their %w[y yes evet] handling. Ctrl+C, EOF, or a bare
      # Enter all select the default answer instead of unwinding the loop.
      def ask_yes_no(prompt, default: "n")
        default_answer = default.to_s.downcase
        return default_answer unless interactive_input?

        # Fast single-key approval on color-capable TTYs (UI::Approvals);
        # plain terminals keep the classic Reline line prompt.
        return Rubik::UI::Approvals.keypress_yes_no(self, prompt, default: default_answer, theme: @ui_theme) if @ui_theme&.color?

        hint = default_answer.start_with?("y") ? "[Y/n]" : "[y/N]"
        answer = @reline.readline("#{prompt} #{hint}: ", false)
        answer = default_answer if answer.nil? # EOF (Ctrl+D/Ctrl+Z) -> default
        answer = answer.to_s.strip.downcase
        answer.empty? ? default_answer : answer
      rescue Interrupt
        Rubik::REPL::InterruptHandler.restore_console_after_interrupt
        @output.puts "^C"
        default_answer
      end

      # True only when the Shell is attached to a live interactive console.
      # A TeeIO wrapping REAL output (production command capture: its StringIO
      # target makes test_capture? true) still counts as interactive; only
      # tees whose every target is a StringIO (test harness) do not.
      def interactive_input?
        return false if ENV["RUBIK_TEST"] == "1"

        out = @output
        if out.is_a?(TeeIO)
          real_targets = out.targets.compact.grep_v(StringIO)
          return false if real_targets.empty?

          out = real_targets.first
        end
        return false if out.is_a?(StringIO)
        return false if out.respond_to?(:test_capture?) && out.test_capture?

        input = @input || $stdin
        input.respond_to?(:tty?) && input.tty?
      end
    end
  end
end
