# frozen_string_literal: true

require_relative "base"
require_relative "../../session"

module Rubik
  module REPL
    module Commands
      module Session
        extend Base

        def self.register(shell)
          shell.register_command("history", description: "List recent session history") do |args|
            limit = (args.first || 20).to_i
            hist = shell.recorder.read_history(limit)
            hist.each_with_index do |item, idx|
              shell.output.puts " #{idx + 1}: #{item['payload']}"
            end
          end

          shell.register_command("replay", description: "Replay session file") do |args|
            path = args.first
            replayer = Rubik::Session::Replayer.new(shell)
            if replayer.replay_file(path)
              shell.output.puts "Replay completed."
            else
              shell.output.puts "Session file not found: #{path}"
            end
          end

          shell.register_command("session", description: "Manage recorded sessions (list|resume [id]|info)") do |args|
            sub = args.first&.downcase || "list"
            root_d = shell.buffer_manager&.root_dir || Dir.pwd
            home_d = shell.config&.instance_variable_get(:@home_dir) || ENV["HOME"]

            case sub
            when "list"
              sessions = Rubik::Session::Manager.list_sessions(root_d, home_d)
              if sessions.empty?
                shell.output.puts "No recorded sessions found for this workspace."
              else
                shell.output.puts "=== Recorded Sessions (#{sessions.size}) ==="
                sessions.each_with_index do |s, idx|
                  mark = (s[:path] == shell.recorder.session_file) ? " [CURRENT]" : ""
                  shell.output.puts "  #{idx + 1}. #{s[:id]} (#{s[:scope]}) - #{s[:event_count]} events - Last: \"#{s[:last_prompt]}\"#{mark}"
                end
              end
            when "resume", "continue", "load"
              target_id = args[1]
              if target_id.nil?
                picked = interactive_session_pick(shell)
                if picked == :picker_cancelled
                  shell.output.puts "[Rubik::Session] Resume iptal edildi."
                  next
                end
                target_id = picked || :latest
              end
              res = shell.resume_session(target_id)
              shell.output.puts "Resume failed: #{res[:error]}" unless res[:ok]
            when "info"
              shell.output.puts "Active Session File: #{shell.recorder.session_file}"
              shell.output.puts "Total Events in Session: #{shell.recorder.events.size}"
            when "save"
              target_name = args[1]
              if target_name.nil? || target_name.strip.empty?
                shell.output.puts "Usage: !session save <name>"
              else
                safe_name = File.basename(target_name.strip.sub(/\.jsonl$/, ""))
                if safe_name.empty? || safe_name.start_with?(".")
                  shell.output.puts "Error: Invalid session name '#{target_name}'."
                  next
                end

                target_dir = File.join(root_d, ".rubik", "sessions")
                FileUtils.mkdir_p(target_dir)
                target_file = File.join(target_dir, "#{safe_name}.jsonl")

                if shell.recorder.session_file && File.exist?(shell.recorder.session_file)
                  FileUtils.cp(shell.recorder.session_file, target_file)
                else
                  File.open(target_file, "w") do |f|
                    shell.recorder.events.each { |ev| f.puts(JSON.dump(ev)) }
                  end
                end
                shell.recorder.switch_session_file(target_file, cleanup_empty_current: false)
                shell.output.puts "[Rubik::Session] Session saved to #{target_file}"
              end
            else
              shell.output.puts "Usage: !session <list | resume [id] | save <name> | info>"
            end
          end
        end

        # Interactive session picker (Antigravity /resume style): arrow-key
        # selection over recorded sessions on capable TTYs. Returns the
        # session id, :picker_cancelled on Ctrl+C (caller aborts the
        # resume), or nil in pipes/tests so `resume` falls back to :latest.
        class << self
          def interactive_session_pick(shell)
            return nil unless Rubik::UI::Capability.interactive?(input: shell.input, output: shell.output)

            root_d = shell.buffer_manager&.root_dir || Dir.pwd
            home_d = shell.config&.instance_variable_get(:@home_dir) || ENV["HOME"]
            sessions = Rubik::Session::Manager.list_sessions(root_d, home_d)
            return nil if sessions.empty?

            prompt = Rubik::UI::Approvals.build_prompt(shell)
            prompt.select("Devam edilecek oturumu seç:") do |menu|
              sessions.first(15).each do |s|
                menu.choice "#{s[:id]} · #{s[:event_count]} olay · \"#{s[:last_prompt].to_s[0, 40]}\"", s[:id]
              end
              menu.choice "← en son oturum (:latest)", :latest
            end
          rescue Interrupt
            Rubik::REPL::InterruptHandler.restore_console_after_interrupt
            :picker_cancelled
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
