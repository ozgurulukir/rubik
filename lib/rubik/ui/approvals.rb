# frozen_string_literal: true

require "tty-prompt"

module Rubik
  module UI
    # Fast-path approval surfaces (Antigravity-style): a warning card drawn
    # above the prompt plus single-keypress answers.
    #
    # History note: an adaptive sandbox-network approval card
    # (confirm_action/map_action, returning :yes_network/:yes_sandbox) lived
    # here but never had a production caller — a phantom security control
    # (Plan 111, F5). Sandbox network policy is config-only
    # (`sandbox.allow_network`); if an approval gate is ever wired in, its
    # design intent is preserved in _plan/80-sandbox-mimari-refaktoru…md and
    # git history.
    module Approvals
      module_function

      # Single-key yes/no. Returns the downcased answer String ("y"/"n"/...)
      # exactly like Confirmations#ask_yes_no so call sites keep their word
      # matching. Enter/Esc/EOF/Ctrl+C resolve to the default answer.
      def keypress_yes_no(shell, question, theme:, default: "n")
        default_answer = default.to_s.downcase
        return default_answer unless Capability.interactive?(input: shell.input, output: shell.output)

        hint = default_answer.start_with?("y") ? "Y/n" : "y/N"
        prompt = build_prompt(shell)

        answer = prompt.keypress("#{question} #{theme.paint("[#{hint}]", :dim)} ")
        normalize_answer(answer, default_answer)
      rescue Interrupt
        Rubik::REPL::InterruptHandler.restore_console_after_interrupt
        default_answer
      rescue StandardError
        default_answer
      end

      def normalize_answer(answer, default_answer)
        answer = answer.is_a?(String) ? answer.strip.downcase : ""
        answer.empty? || answer == "\r" || answer == "\e" ? default_answer : answer
      end

      # TTY::Prompt must talk to the real terminal: unwrap TeeIO capture the
      # same way Confirmations#interactive_input? does.
      def build_prompt(shell)
        out = Capability.unwrap_tee(shell.output) || $stdout
        TTY::Prompt.new(input: shell.input || $stdin, output: out)
      end
    end
  end
end
