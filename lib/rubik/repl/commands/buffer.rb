# frozen_string_literal: true

require_relative "base"

module Rubik
  module REPL
    module Commands
      module Buffer
        extend Base

        def self.register(shell)
          shell.register_command("diff", description: "Show unapplied buffer changes") do
            diff_text = shell.buffer_manager.diff_all
            if diff_text.empty?
              shell.output.puts "No unapplied buffer changes."
            else
              shell.output.puts diff_text
            end
          end

          shell.register_command("apply", description: "Apply dirty buffer changes to disk") do
            applied = shell.buffer_manager.apply!
            shell.sync_context_and_ast(applied)
            shell.output.puts "Applied changes to #{applied.size} file(s): #{applied.join(', ')}"
          end

          shell.register_command("undo", description: "Revert the last snapshot") do
            if shell.snapshot_store.undo(shell.buffer_manager)
              shell.output.puts "Undo successful."
            else
              shell.output.puts "No snapshots to undo."
            end
          end

          shell.register_command("rollback", description: "Rollback to a specific snapshot ID") do |args|
            sid = args.first
            if sid && shell.snapshot_store.rollback(sid, shell.buffer_manager)
              shell.output.puts "Rollback to snapshot #{sid} successful."
            else
              shell.output.puts "Snapshot #{sid} not found."
            end
          end

          shell.register_command("autoapply", description: "Get or set buffer auto-apply policy (manual|on_test|on_finish|always)") do |args|
            scope, clean_args = Base.parse_scope(args)
            sub = clean_args.first&.downcase

            if sub.nil? || sub == "status"
              cur = shell.config.fetch("buffer.auto_apply", "manual")
              can_m = shell.config.fetch("buffer.model_can_apply", true)
              shell.output.puts "Buffer Auto-Apply Policy:"
              shell.output.puts "  • Mode             : #{cur} (manual | on_test | on_finish | always)"
              shell.output.puts "  • Model Can Apply  : #{can_m}"
              shell.output.puts "  • Prompt Indicator : #{shell.config.fetch('buffer.prompt_indicator', true)}"
              shell.output.puts "  • Reminder Interval: #{shell.config.fetch('buffer.reminder_interval', 3)} turns"
            elsif %w[manual on_test on_finish always].include?(sub)
              shell.config.set("buffer.auto_apply", sub, persist: scope)
              shell.output.puts "Buffer auto-apply policy set to '#{sub}' [Saved to #{scope} config]"
            else
              shell.output.puts "Usage: !autoapply <manual | on_test | on_finish | always | status> [--project|--global]"
            end
          end
        end
      end
    end
  end
end
