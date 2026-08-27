# frozen_string_literal: true

require "tty-prompt"
require_relative "frame"

module Rubik
  module UI
    # Fast-path approval surfaces (Antigravity-style): a warning card drawn
    # above the prompt plus single-keypress answers, and sandbox-adaptive
    # option sets whose third key changes with the active sandbox posture.
    module Approvals
      module_function

      # Single-key yes/no. Returns the downcased answer String ("y"/"n"/...)
      # exactly like Confirmations#ask_yes_no so call sites keep their word
      # matching. Enter/Esc/EOF/Ctrl+C resolve to the default answer.
      def keypress_yes_no(shell, question, theme:, default: "n")
        default_answer = default.to_s.downcase
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

      # Renders a framed approval card and asks a single-key decision with a
      # sandbox-adaptive extra option:
      #   network blocked  ->  "a" approves once WITH network access
      #   network allowed  ->  "s" approves once inside the sandbox
      # Returns one of :yes, :no, :yes_network, :yes_sandbox.
      def confirm_action(shell, label:, theme:, detail: nil)
        card = Frame.draw(
          [theme.paint(label, :bold)] + Array(detail ? [theme.paint(detail, :dim)] : []),
          theme: theme,
          title: theme.paint("#{theme.glyph(:warn)} ONAY BEKLİYOR", :warn)
        )
        shell.output.print(card)

        network = shell.config.fetch("sandbox.allow_network", false)
        adaptive = network ? "s: onayla ve sandbox'ta çalıştır" : "a: onayla ve ağ izniyle çalıştır"
        shell.output.puts theme.paint("  y: onayla · n: reddet · #{adaptive} · esc: vazgeç", :dim)

        prompt = build_prompt(shell)
        answer = prompt.keypress("> ")
        map_action(answer, network)
      rescue Interrupt
        Rubik::REPL::InterruptHandler.restore_console_after_interrupt
        :no
      rescue StandardError
        :no
      end

      def normalize_answer(answer, default_answer)
        answer = answer.to_s.strip.downcase
        answer.empty? || answer == "\r" || answer == "\e" ? default_answer : answer
      end

      def map_action(answer, network)
        case answer.to_s.strip.downcase
        when "y", "yes", "evet" then :yes
        when "a" then network ? :yes : :yes_network
        when "s" then network ? :yes_sandbox : :yes
        else :no # enter / esc / unknown -> conservative default
        end
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
