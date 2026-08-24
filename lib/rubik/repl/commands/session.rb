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
              target_id = args[1] || :latest
              res = shell.resume_session(target_id)
              shell.output.puts "Resume failed: #{res[:error]}" unless res[:ok]
            when "info"
              shell.output.puts "Active Session File: #{shell.recorder.session_file}"
              shell.output.puts "Total Events in Session: #{shell.recorder.events.size}"
            else
              shell.output.puts "Usage: !session <list | resume [id] | info>"
            end
          end
        end
      end
    end
  end
end
