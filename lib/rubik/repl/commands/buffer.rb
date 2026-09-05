# frozen_string_literal: true

require_relative "base"
require "fileutils"
require "digest"

module Rubik
  module REPL
    module Commands
      module Buffer
        extend Base

        def self.register(shell)
          shell.register_command("diff", description: "Show unapplied buffer changes (colorized viewer on terminals)", audience: :both) do |args|
            theme = shell.theme
            target_path = args.first
            if target_path && !target_path.empty?
              rel = begin
                shell.buffer_manager.sanitize_path(target_path)
              rescue
                target_path
              end
              if shell.buffer_manager.dirty_files.key?(rel)
                full_path = File.expand_path(rel, shell.buffer_manager.root_dir)
                orig_content = File.exist?(full_path) ? File.read(full_path) : ""
                new_content = shell.buffer_manager.instance_variable_get(:@buffer)[rel] || ""
                Rubik::UI::DiffViewer.render(shell, theme, Rubik::Buffer::Diff.unified_diff(rel, orig_content, new_content))
              else
                shell.output.puts "No unapplied buffer changes for '#{target_path}'."
              end
            else
              diff_text = shell.buffer_manager.diff_all
              if diff_text.empty?
                shell.output.puts "No unapplied buffer changes."
              else
                Rubik::UI::DiffViewer.render(shell, theme, diff_text)
              end
            end
          end

          shell.register_command("apply", description: "Apply dirty buffer changes to disk") do |args|
            target_path = args.first
            if target_path && !target_path.empty?
              applied = shell.buffer_manager.apply!(target_path)
              conflicts = shell.buffer_manager.last_conflicts || []
              if applied.empty? && conflicts.empty?
                shell.output.puts "No unapplied buffer changes for '#{target_path}'."
              else
                shell.sync_context_and_ast(applied) unless applied.empty?
                shell.output.puts "Applied changes to file: #{applied.first}" unless applied.empty?
              end
            else
              applied = shell.buffer_manager.apply!
              conflicts = shell.buffer_manager.last_conflicts || []
              if applied.empty? && conflicts.empty?
                shell.output.puts "No unapplied buffer changes."
              else
                shell.sync_context_and_ast(applied) unless applied.empty?
                shell.output.puts "Applied changes to #{applied.size} file(s): #{applied.join(', ')}" unless applied.empty?
              end
            end
            conflicts.each do |c|
              shell.output.puts "[CONFLICT] #{c}: disk content changed since last read — skipped to prevent data loss. Re-read the file to resolve."
            end
          end

          shell.register_command("undo", description: "Revert the last snapshot", audience: :both) do
            if shell.snapshot_store.undo(shell.buffer_manager)
              shell.output.puts "Undo successful."
            else
              shell.output.puts "No snapshots to undo."
            end
          end

          shell.register_command("rollback", description: "Rollback to a specific snapshot ID", audience: :both) do |args|
            sid = args.first
            if sid.nil? || sid.empty?
              shell.output.puts "Usage: !rollback <snapshot_id>"
            elsif shell.snapshot_store.rollback(sid, shell.buffer_manager)
              shell.output.puts "Rollback to snapshot #{sid} successful."
            else
              shell.output.puts "Snapshot #{sid} not found."
            end
          end

          shell.register_command("autoapply", description: "Get or set buffer auto-apply policy (manual|on_test|on_finish|always)", audience: :both) do |args|
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
            elsif ["manual", "on_test", "on_finish", "always"].include?(sub)
              shell.config.set("buffer.auto_apply", sub, persist: scope)
              shell.output.puts "Buffer auto-apply policy set to '#{sub}' [#{Base.scope_label(scope)}]."
            else
              shell.output.puts "Usage: !autoapply <manual | on_test | on_finish | always | status> [--project|--global]"
            end
          end
        end
      end
    end
  end
end
