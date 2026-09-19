# frozen_string_literal: true

require "tty-prompt"
require_relative "capability"
require_relative "frame"
require_relative "theme"

module Rubik
  module UI
    # Interactive question and decision dialog for the human operator (Plan 92).
    # Presents single-choice and multi-choice menus with clean ANSI/VT100 cards
    # and handles keyboard interrupts gracefully.
    class Dialog
      attr_reader :shell, :theme

      def initialize(shell: nil, theme: nil, prompt: nil)
        @shell = shell
        @theme = theme || Theme.for(shell&.output || $stdout, shell&.config)
        @prompt = prompt
      end

      # Prompts the user with a single-choice question.
      #
      # @param question [String] Question text
      # @param options [Array<String>] List of selectable options
      # @param allow_custom [Boolean] Whether to provide a free-text write-in option
      # @return [String, Symbol] Selected answer, custom string, or :cancelled
      def ask_single(question, options, allow_custom: true)
        return :non_interactive unless interactive?

        render_card(question, multi: false)
        p = build_prompt
        choices = options.uniq.dup
        choices << "Other (write-in response)" if allow_custom

        answer = p.select("Seçiminizi yapın / Select an option:", choices, filter: true, per_page: 10)
        if answer == "Other (write-in response)"
          custom = p.ask("Yanıtınız / Your answer:")
          custom.to_s.strip.empty? ? options.first : "Other (write-in): #{custom.strip}"
        else
          answer
        end
      rescue Interrupt, StandardError
        :cancelled
      ensure
        restore_console
      end

      # Prompts the user with a multi-choice question.
      #
      # @param question [String] Question text
      # @param options [Array<String>] List of selectable options
      # @return [Array<String>, Symbol] Array of selected answers, or :cancelled
      def ask_multi(question, options)
        return :non_interactive unless interactive?

        render_card(question, multi: true)
        p = build_prompt
        answers = p.multi_select("Seçenekleri belirleyin / Select options (Space: toggle, Enter: confirm):",
                                 options.uniq, filter: true, per_page: 10)
        answers.empty? ? [options.first] : answers
      rescue Interrupt, StandardError
        :cancelled
      ensure
        restore_console
      end

      # True when the input/output streams are interactive TTYs.
      def interactive?
        return true if @prompt # Injected prompt for test mockability

        inp = @shell&.input || $stdin
        out = @shell&.output || $stdout
        Capability.interactive?(input: inp, output: out)
      end

      private

      def render_card(question, multi: false)
        return unless @shell&.output

        subtitle = multi ? "Çoklu Seçim (Boşluk: Seç/Kaldır · Enter: Onayla)" : "Tekli Seçim (Ok tuşları: Gezin · Enter: Onayla)"
        card = Frame.draw(
          [@theme.paint(question, :bold), @theme.paint(subtitle, :dim)],
          theme: @theme,
          title: @theme.paint("#{@theme.glyph(:action)} AJAN SORUSU", :accent)
        )
        @shell.output.puts(card)
      end

      def build_prompt
        return @prompt if @prompt

        out = Capability.unwrap_tee(@shell&.output) || $stdout
        TTY::Prompt.new(input: @shell&.input || $stdin, output: out)
      end

      def restore_console
        require_relative "../repl/interrupt_handler" unless defined?(Rubik::REPL::InterruptHandler)
        Rubik::REPL::InterruptHandler.restore_console_after_interrupt if defined?(Rubik::REPL::InterruptHandler)
      end
    end
  end
end
