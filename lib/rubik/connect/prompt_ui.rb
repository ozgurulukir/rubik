# frozen_string_literal: true

require "tty-prompt"
require_relative "../ui/capability"
require_relative "../ui/theme"
require_relative "../repl/interrupt_handler"

module Rubik
  module Connect
    # Prompt port for the connect wizard: the exact TTY::Prompt operations
    # the flow needs (select / ask / secret / yes?), with UI::Dialog's
    # sentinel contract (:cancelled / :non_interactive) and the same
    # injectable-prompt test seam. Lives outside UI::Dialog because the
    # wizard runs shell-less (rubik connect boots no Shell) and needs
    # typed prompts (masked key entry, yes/no) Dialog does not offer.
    class PromptUI
      CANCELLED = :cancelled
      NON_INTERACTIVE = :non_interactive

      attr_reader :theme

      def initialize(input:, output:, theme: nil, prompt: nil)
        @input = input
        @output = output
        @theme = theme || Rubik::UI::Theme.for(output, nil)
        # Injected prompt => forced-interactive (tests); same seam as Dialog.
        @prompt = prompt
      end

      def interactive?
        return true if @prompt

        Rubik::UI::Capability.interactive?(input: @input, output: @output)
      end

      # Single-choice menu; `filter: true` lets users type to narrow long
      # lists (the 300+ catalog tail depends on it). Returns the chosen
      # String or a sentinel.
      def select(question, choices, default: nil)
        raw do |p|
          # tty-prompt select defaults are 1-based; 0 raises out of range.
          default_index = choices.index(default).to_i + 1
          p.select(question, choices, filter: true, per_page: 10, cycle: true,
                                      default: default_index)
        end
      end

      # Free-text question; empty input accepts `default` when given.
      def ask(question, default: nil)
        raw do |p|
          if default.nil?
            p.ask(question)
          else
            # default rides both channels: the option (consumed by injected
            # test doubles) and the TTY modifier block (real prompts) —
            # TTY treats them as equivalent settings, idempotent to double-apply.
            p.ask(question, default: default.to_s) { |q| q.default(default.to_s) }
          end
        end
      end

      # Masked credential entry (no echo). Real TTY::Prompt exposes #mask;
      # injected test doubles implement the wizard-level #secret.
      def secret(question)
        raw do |p|
          if p.respond_to?(:mask)
            p.mask(question)
          else
            p.secret(question)
          end
        end
      end

      def yes?(question, default: true)
        raw { |p| p.yes?(question, default: default) { |q| q.default(default) } }
      end

      # Plain line output for notices/reports; never a sentinel source.
      def puts(line)
        @output.puts line
      end

      # Theme-aware text styling for wizard output (frames, success/error
      # lines); degrades to the raw text off color-capable terminals.
      def paint(text, style)
        @theme.paint(text, style)
      end

      # Wraps a blocking fetch in a live spinner on capable terminals and
      # stays silent elsewhere; always yields.
      def spinner(message)
        if Rubik::UI::Capability.spinner?(@output)
          spin = TTY::Spinner.new("[:spinner] #{message}", format: :spin, hide_cursor: true, clear: true)
          spin.auto_spin
          begin
            yield
          ensure
            spin.stop
          end
        else
          yield
        end
      end

      private

      # The one sentinel funnel: every prompt operation degrades to
      # :non_interactive off a live TTY and to :cancelled on interrupt or
      # prompt failure, restoring the console either way (Dialog
      # discipline). A swallowed non-interrupt error is never silent —
      # debug_warn names it so a prompt-layer bug cannot pose as a user
      # cancellation.
      def raw
        return NON_INTERACTIVE unless interactive?

        yield(@prompt || build_prompt)
      rescue Interrupt
        CANCELLED
      rescue StandardError => e
        Rubik::Platform.debug_warn("connect prompt failed (#{e.class}: #{e.message}) — treated as cancel")
        CANCELLED
      ensure
        restore_console
      end

      def build_prompt
        TTY::Prompt.new(input: @input, output: Rubik::UI::Capability.unwrap_tee(@output) || $stdout)
      end

      def restore_console
        Rubik::REPL::InterruptHandler.restore_console_after_interrupt
      rescue StandardError
        nil
      end
    end
  end
end
