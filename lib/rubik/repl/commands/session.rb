# frozen_string_literal: true

require_relative "base"
require_relative "../../session"

module Rubik
  module REPL
    module Commands
      module Session
        extend Base

        # Whole-command synopsis: shared by the spine registration (usage:)
        # and the unknown-subcommand fallback branch, so the two cannot drift.
        USAGE_SESSION = "Usage: !session <list | resume [id] | save <name> | info | prune [days] [--apply] [--all]>"
        PRUNE_DEFAULT_DAYS = 7

        def self.register(shell)
          shell.register_command("history", description: "List recent session history", audience: :both) do |args, ctx|
            limit = (args.first || 20).to_i
            hist = ctx.recorder.read_history(limit)
            hist.each_with_index do |item, idx|
              ctx.out.puts " #{idx + 1}: #{item['payload']}"
            end
          end

          # Plan 91 — explicit multi-line paste mode: collects lines until a
          # lone "." line, then dispatches the joined text as one prompt turn.
          shell.register_command("paste", description: "Multi-line paste mode (finish with lone '.')") do |_args, ctx|
            ctx.request_paste!
            ctx.out.puts "[Rubik] Paste modu bir sonraki prompt'ta başlayacak."
          end

          shell.register_command("replay", description: "Replay session file") do |args, ctx|
            path = args.first
            replayer = ctx.session_replayer
            if replayer.replay_file(path)
              ctx.out.puts "Replay completed."
            else
              ctx.out.puts "Session file not found: #{path}"
            end
          end

          shell.register_command("session", description: "Manage recorded sessions (list|resume|info|prune)",
                                            usage: USAGE_SESSION) do |args, ctx|
            sub = args.first&.downcase || "list"
            root_d = ctx.buffer_manager&.root_dir || Dir.pwd
            home_d = ctx.config&.home_dir || ENV.fetch("HOME", nil)

            case sub
            when "list"
              sessions = Rubik::Session::Manager.list_sessions(root_d, home_d)
              if sessions.empty?
                ctx.out.puts "No recorded sessions found for this workspace."
              else
                ctx.out.puts "=== Recorded Sessions (#{sessions.size}) ==="
                sessions.each_with_index do |s, idx|
                  mark = s[:path] == ctx.recorder.session_file ? " [CURRENT]" : ""
                  ctx.out.puts "  #{idx + 1}. #{s[:id]} (#{s[:scope]}) - #{s[:event_count]} events - Last: \"#{s[:last_prompt]}\"#{mark}"
                end
              end
            when "resume", "continue", "load"
              target_id = args[1]
              if target_id.nil?
                picked = interactive_session_pick(ctx)
                if picked == :picker_cancelled
                  ctx.out.puts "[Rubik::Session] Resume iptal edildi."
                  next
                end
                target_id = picked || :latest
              end
              res = ctx.resume_session(target_id)
              ctx.out.puts "Resume failed: #{res[:error]}" unless res[:ok]
            when "info"
              ctx.out.puts "Active Session File: #{ctx.recorder.session_file}"
              ctx.out.puts "Total Events in Session: #{ctx.recorder.events.size}"
            when "prune", "clean", "cleanup"
              run_prune(args.drop(1), ctx)
            when "save"
              target_name = args[1]
              if target_name.nil? || target_name.strip.empty?
                ctx.out.puts "Usage: !session save <name>"
              else
                safe_name = File.basename(target_name.strip.sub(/\.jsonl$/, ""))
                if safe_name.empty? || safe_name.start_with?(".")
                  ctx.out.puts "Error: Invalid session name '#{target_name}'."
                  next
                end

                target_dir = File.join(root_d, ".rubik", "sessions")
                FileUtils.mkdir_p(target_dir)
                target_file = File.join(target_dir, "#{safe_name}.jsonl")

                if ctx.recorder.session_file && File.exist?(ctx.recorder.session_file)
                  FileUtils.cp(ctx.recorder.session_file, target_file)
                else
                  File.open(target_file, "w") do |f|
                    ctx.recorder.events.each { |ev| f.puts(JSON.dump(ev)) }
                  end
                end
                ctx.recorder.switch_session_file(target_file, cleanup_empty_current: false)
                ctx.out.puts "[Rubik::Session] Session saved to #{target_file}"
              end
            else
              ctx.out.puts USAGE_SESSION
            end
          end
        end

        # Interactive session picker (Antigravity /resume style): arrow-key
        # selection over recorded sessions on capable TTYs. Returns the
        # session id, :picker_cancelled on Ctrl+C (caller aborts the
        # resume), or nil in pipes/tests so `resume` falls back to :latest.
        class << self
          # `!session prune [days] [--apply] [--all]` — dry-run by default:
          # prints the blast radius of files that WOULD be deleted and only
          # unlinks once the operator passes --apply. The active session file
          # is always protected. `--all` widens scope to ~/.rubik/sessions.
          def run_prune(rest, ctx)
            apply = rest.any? { |a| ["--apply", "--yes", "-y", "apply", "delete"].include?(a.downcase) }
            include_global = rest.any? { |a| ["--all", "-a", "all", "global"].include?(a.downcase) }
            day_arg = rest.find { |a| a =~ /\A\d+(\.\d+)?\z/ }
            days = day_arg ? day_arg.to_f : PRUNE_DEFAULT_DAYS
            days = PRUNE_DEFAULT_DAYS unless days.positive?

            root_d = ctx.buffer_manager&.root_dir || Dir.pwd
            home_d = ctx.config&.home_dir || ENV.fetch("HOME", nil)
            active = ctx.recorder&.session_file

            report = Rubik::Session::Manager.prune_sessions(
              days: days, root_dir: root_d, home_dir: home_d,
              exclude_file: active, apply: apply, include_global: include_global
            )

            scope_label = include_global ? "project + global" : "project"
            size_mb = report[:bytes] / 1_048_576.0

            if report[:candidates].zero?
              ctx.out.puts "[Rubik::Session] No #{scope_label} sessions older than #{format_days(days)} to prune."
              return
            end

            verb = apply ? "Deleted" : "Would delete"
            ctx.out.puts "[Rubik::Session] #{verb} #{report[:candidates]} #{scope_label} session(s) " \
                         "older than #{format_days(days)} (#{format('%.1f', size_mb)} MB)."
            unless report[:sample].empty?
              ctx.out.puts "  e.g. #{report[:sample].join(', ')}#{report[:candidates] > report[:sample].size ? ', …' : ''}"
            end
            if report[:protected_skipped].positive?
              ctx.out.puts "  [CURRENT] active session protected: #{File.basename(active.to_s)}"
            end

            ctx.out.puts "  Dry run — nothing removed. Re-run with '--apply' to delete." unless apply
          end

          def format_days(days)
            days == days.to_i ? "#{days.to_i}d" : "#{days.round(1)}d"
          end

          def interactive_session_pick(ctx)
            return nil unless Rubik::UI::Capability.interactive?(input: ctx.input, output: ctx.output)

            root_d = ctx.buffer_manager&.root_dir || Dir.pwd
            home_d = ctx.config&.home_dir || ENV.fetch("HOME", nil)
            sessions = Rubik::Session::Manager.list_sessions(root_d, home_d)
            return nil if sessions.empty?

            prompt = Rubik::UI::Approvals.build_prompt(ctx)
            prompt.select("Devam edilecek oturumu seç:") do |menu|
              sessions.first(15).each do |s|
                menu.choice "#{s[:id]} · #{s[:event_count]} olay · \"#{s[:last_prompt].to_s[0, 40]}\"", s[:id]
              end
              menu.choice "← en son oturum (:latest)", :latest
            end
          rescue Interrupt
            Rubik::REPL::InterruptHandler.restore_console_after_interrupt
            :picker_cancelled
          rescue StandardError => e
            Rubik::Log.warn(:repl, "session picker failed (#{e.class}: #{e.message}); resume selection skipped")
            nil
          end
        end
      end
    end
  end
end
