# frozen_string_literal: true

require_relative "base"

module Rubik
  module REPL
    module Commands
      module Buffer
        extend Base

        # Whole-command synopses: shared by the spine registration (usage:)
        # and the empty-args / fallback branches that print them, so the two
        # cannot drift.
        USAGE_ROLLBACK = "Usage: !rollback <snapshot_id>"
        USAGE_AUTOAPPLY = "Usage: !autoapply <manual | on_test | on_finish | always | status> [--project|--global]"

        def self.register(shell)
          shell.register_command(
            "diff",
            description: "Preview unapplied buffer changes (staged edits that are NOT yet on disk). " \
                         "Scope: buffer only — never shows committed/git history. " \
                         "For ground-truth file content, use read_file; for git history, use run_command with git. " \
                         "(colorized viewer on terminals)",
            audience: :both
          ) do |args, ctx|
            theme = ctx.theme
            target_path = args.first
            if target_path && !target_path.empty?
              rel = begin
                ctx.buffer_manager.sanitize_path(target_path)
              rescue
                target_path
              end
              if ctx.buffer_manager.dirty_files.key?(rel)
                full_path = File.expand_path(rel, ctx.buffer_manager.root_dir)
                orig_content = File.exist?(full_path) ? File.read(full_path) : ""
                new_content = ctx.buffer_manager.read(rel) || ""
                Rubik::UI::DiffViewer.render(ctx, theme, Rubik::Buffer::Diff.unified_diff(rel, orig_content, new_content))
              else
                ctx.out.puts "No unapplied buffer changes for '#{target_path}'."
              end
            else
              diff_text = ctx.buffer_manager.diff_all
              if diff_text.empty?
                ctx.out.puts "No unapplied buffer changes."
              else
                Rubik::UI::DiffViewer.render(ctx, theme, diff_text)
              end
            end
          end

          shell.register_command("apply", description: "Apply dirty buffer changes to disk") do |args, ctx|
            target_path = args.first
            if target_path && !target_path.empty?
              applied = ctx.buffer_manager.apply!(target_path)
              conflicts = ctx.buffer_manager.last_conflicts || []
              if applied.empty? && conflicts.empty?
                ctx.out.puts "No unapplied buffer changes for '#{target_path}'."
              else
                ctx.sync_context_and_ast(applied) unless applied.empty?
                ctx.out.puts "Applied changes to file: #{applied.first}" unless applied.empty?
              end
            else
              applied = ctx.buffer_manager.apply!
              conflicts = ctx.buffer_manager.last_conflicts || []
              if applied.empty? && conflicts.empty?
                ctx.out.puts "No unapplied buffer changes."
              else
                ctx.sync_context_and_ast(applied) unless applied.empty?
                ctx.out.puts "Applied changes to #{applied.size} file(s): #{applied.join(', ')}" unless applied.empty?
              end
            end
            conflicts.each do |c|
              ctx.out.puts "[CONFLICT] #{c}: disk content changed since last read — skipped to prevent data loss. Re-read the file to resolve."
            end
          end

          shell.register_command("undo", description: "Revert the last snapshot", audience: :both) do |_args, ctx|
            if ctx.snapshot_store.undo(ctx.buffer_manager)
              ctx.out.puts "Undo successful."
            else
              ctx.out.puts "No snapshots to undo."
            end
          end

          shell.register_command("rollback", description: "Rollback to a specific snapshot ID", usage: USAGE_ROLLBACK, audience: :both) do |args, ctx|
            sid = args.first
            if sid.nil? || sid.empty?
              ctx.out.puts USAGE_ROLLBACK
            elsif ctx.snapshot_store.rollback(sid, ctx.buffer_manager)
              ctx.out.puts "Rollback to snapshot #{sid} successful."
            else
              ctx.out.puts "Snapshot #{sid} not found."
            end
          end

          shell.register_command("autoapply",
                                 description: "Get or set buffer auto-apply policy (manual|on_test|on_finish|always)",
                                 usage: USAGE_AUTOAPPLY, audience: :both) do |args, ctx|
            scope, clean_args = Base.parse_scope(args)
            sub = clean_args.first&.downcase

            if sub.nil? || sub == "status"
              cur = ctx.config.fetch("buffer.auto_apply", "manual")
              can_m = ctx.config.fetch("buffer.model_can_apply", true)
              ctx.out.puts "Buffer Auto-Apply Policy:"
              ctx.out.puts "  • Mode             : #{cur} (manual | on_test | on_finish | always)"
              ctx.out.puts "  • Model Can Apply  : #{can_m}"
              ctx.out.puts "  • Prompt Indicator : #{ctx.config.fetch('buffer.prompt_indicator', true)}"
              ctx.out.puts "  • Reminder Interval: #{ctx.config.fetch('buffer.reminder_interval', 3)} turns"
            elsif ["manual", "on_test", "on_finish", "always"].include?(sub)
              res = ctx.config.set("buffer.auto_apply", sub, persist: scope)
              next if Base.report_persist_failure(ctx, res, scope)

              ctx.out.puts "Buffer auto-apply policy set to '#{sub}' [#{Base.scope_label(scope)}]."
            else
              ctx.out.puts USAGE_AUTOAPPLY
            end
          end
        end
      end
    end
  end
end
