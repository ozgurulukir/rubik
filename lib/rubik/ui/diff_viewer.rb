# frozen_string_literal: true

module Rubik
  module UI
    # Colorized unified-diff viewer for `!diff`: added/removed lines carry a
    # color-blind safe cyan/red pair (never green-vs-red), hunk headers blue.
    # The +/- signs stay in the text, so color is never the only channel.
    # On interactive consoles a follow-up single-keypress menu offers apply.
    # Non-TTY runs keep the plain diff byte-for-byte (tests, pipes, session
    # replay).
    module DiffViewer
      module_function

      def render(shell, theme, diff_text)
        return if diff_text.to_s.empty?

        require_relative "../security/redactor" unless defined?(Rubik::Security::Redactor)
        clean_diff = Rubik::Security::Redactor.redact(diff_text.to_s)

        if theme.color?
          shell.output.puts colorize(clean_diff, theme)
        else
          shell.output.puts clean_diff
        end

        offer_actions(shell, theme) if interactive?(shell)
      end

      def colorize(diff_text, theme)
        diff_text.lines.map do |line|
          stripped = line.chomp
          styled =
            if stripped.start_with?("+++", "---", "===")
              theme.paint(stripped, :bold)
            elsif stripped.start_with?("@@")
              theme.paint(stripped, :info)
            elsif stripped.start_with?("+")
              theme.paint(stripped, :added)
            elsif stripped.start_with?("-")
              theme.paint(stripped, :removed)
            else
              theme.paint(stripped, :dim)
            end
          "#{styled}\n"
        end.join
      end

      # Single-key follow-up. Never raw #gets: mixing plain gets with Reline
      # wedges the prompt on Windows (see Confirmations) — tty-prompt's
      # keypress uses the same raw-mode path as every other UI surface.
      def offer_actions(shell, theme)
        prompt = Approvals.build_prompt(shell)
        key = prompt.keypress(theme.paint("  a: uygula (!apply) · q veya enter: çık ", :dim))
        apply_all(shell) if key.to_s.strip.downcase == "a"
      rescue Interrupt
        Rubik::REPL::InterruptHandler.restore_console_after_interrupt
      rescue StandardError => e
        # apply! fails loud on containment breaks and IO errors — the user
        # pressed "a", so the verdict must reach them, not vanish here.
        shell.output.puts "\n[Hata] Uygulama başarısız: #{e.message}"
      end

      def apply_all(shell)
        applied = shell.buffer_manager.apply!
        if applied.empty?
          shell.output.puts "Uygulanacak değişiklik kalmadı."
        else
          shell.sync_context_and_ast(applied)
          shell.output.puts "Uygulandı: #{applied.join(', ')}"
        end
      end

      def interactive?(shell)
        Capability.interactive?(input: shell.input, output: shell.output)
      end
    end
  end
end
