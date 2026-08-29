# frozen_string_literal: true

require "tty-prompt"

module Rubik
  module UI
    # Interactive agent/fiber board (`!agents`, the Antigravity /agents
    # counterpart): lists runtime fibers with state and current activity,
    # then offers an arrow-key detail view (state history, coeffect
    # dependencies, orchestrator progress, Omega accumulator depth).
    # Falls back to a static listing for pipes and tests.
    module Panel
      STATE_GLYPHS = {
        active: "🟢",
        pending: "⏳",
        failed: "🔴",
        disposed: "⚫",
        unloaded: "⚪"
      }.freeze

      module_function

      def render(shell, theme)
        fibers = shell.runtime_manager&.fibers || {}
        if fibers.empty?
          shell.output.puts "Kayıtlı fiber/ajan yok."
          return
        end

        shell.output.puts "=== Ajan / Fiber Panosu ==="
        rows = fibers.values.sort_by { |f| STATE_ORDER[f.state] || 99 }
        rows.each do |fiber|
          shell.output.puts detail_line(fiber, theme)
        end

        return unless interactive?(shell)

        choice = select_fiber(shell, rows, theme)
        show_fiber_detail(shell, choice, theme) if choice
      end

      def detail_line(fiber, theme)
        glyph = STATE_GLYPHS[fiber.state] || "❔"
        activity = current_activity(fiber)
        name_col = fiber.name.ljust(24)
        "#{glyph} #{theme.paint(name_col, fiber.state == :active ? :accent : :dim)} #{activity}"
      end

      def current_activity(fiber)
        inst = fiber.instance
        if inst.respond_to?(:step_count)
          depth = fiber.sub_context ? " · Ω#{fiber.sub_context.disposable_count}" : ""
          "adım #{inst.step_count}/#{inst.max_steps}#{depth}"
        elsif fiber.state == :failed
          "hata: #{fiber.last_error&.message.to_s[0, 50]}"
        else
          deps = fiber.inject
          deps.empty? ? "-" : "coeffects: #{deps.join(', ')}"
        end
      end

      def select_fiber(shell, rows, _theme)
        prompt = Approvals.build_prompt(shell)
        choices = rows.map { |f| { name: "#{STATE_GLYPHS[f.state]} #{f.name}", value: f } }
        choices << { name: "← çıkış", value: nil }
        prompt.select("Detay için fiber seç:") do |menu|
          choices.each { |c| menu.choice c[:name], c[:value] }
        end
      rescue Interrupt
        Rubik::REPL::InterruptHandler.restore_console_after_interrupt
        nil
      rescue StandardError
        nil
      end

      def show_fiber_detail(shell, fiber, theme)
        inst = fiber.instance
        shell.output.puts
        shell.output.puts theme.paint("── #{fiber.name} ──", :bold)
        shell.output.puts "  Durum       : #{STATE_GLYPHS[fiber.state]} #{fiber.state}"
        shell.output.puts "  Coeffects   : #{fiber.inject.join(', ')}"
        shell.output.puts "  Ω derinliği : #{fiber.sub_context ? fiber.sub_context.disposable_count : 0}"
        if inst.respond_to?(:step_count)
          shell.output.puts "  Adım        : #{inst.step_count}/#{inst.max_steps}"
          shell.output.puts "  Token       : #{inst.total_tokens.inspect}" if inst.respond_to?(:total_tokens)
        end
        shell.output.puts "  Son hata    : #{fiber.last_error&.message}" if fiber.last_error
        shell.output.puts theme.paint("  (enter ile panoya dön)", :dim)
      end

      def interactive?(shell)
        Capability.interactive?(input: shell.input, output: shell.output)
      end

      STATE_ORDER = { active: 0, pending: 1, failed: 2, disposed: 3, unloaded: 4 }.freeze
    end
  end
end
