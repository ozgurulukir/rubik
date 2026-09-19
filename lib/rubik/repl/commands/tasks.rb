# frozen_string_literal: true

require_relative "base"
require_relative "../../coeffects"

module Rubik
  module REPL
    module Commands
      # REPL bang command (!tasks) for monitoring and controlling asynchronous
      # background tasks (Plan 93).
      module Tasks
        extend Base

        def self.register(shell)
          handler = lambda do |args|
            subcmd = args.first&.downcase
            task_mgr = shell.respond_to?(:task_manager) ? shell.task_manager : nil
            if task_mgr.nil? && shell.runtime_manager&.context.respond_to?(:get)
              task_mgr = Rubik::Coeffects.get(shell.runtime_manager.context, Rubik::Coeffects::TASK_MANAGER)
            end

            unless task_mgr
              shell.output.puts "TaskManager is not available."
              return
            end

            case subcmd
            when nil, "list"
              render_list(shell, task_mgr)
            when "status"
              render_status(shell, task_mgr, args[1..])
            when "logs"
              render_logs(shell, task_mgr, args[1..])
            when "kill"
              task_id = args[1]
              if task_id.to_s.strip.empty?
                shell.output.puts "Usage: !tasks kill <task_id>"
              elsif task_mgr.kill(task_id)
                shell.output.puts "Task '#{task_id}' killed."
              else
                shell.output.puts "Task '#{task_id}' not found."
              end
            when "kill-all", "killall"
              task_mgr.kill_all
              shell.output.puts "All background tasks terminated."
            else
              shell.output.puts "Unknown !tasks subcommand: #{subcmd}. Usage: !tasks [list | status <id> | logs <id> [--tail N] | kill <id> | kill-all]"
            end
          end

          shell.register_command("tasks", description: "Manage background asynchronous tasks (list, status, logs, kill, kill-all)", audience: :both, &handler)
          shell.register_command("task", description: "Alias for !tasks", audience: :both, &handler)
        end

        def self.render_list(shell, task_mgr)
          tasks = task_mgr.list
          if tasks.empty?
            shell.output.puts "No background tasks currently running or tracked."
            return
          end

          shell.output.puts "=== Background Tasks (#{tasks.size}) ==="
          tasks.each do |t|
            dur = t.running? ? "up #{t.uptime.round(1)}s" : "exit #{t.exit_code}"
            shell.output.puts "  • [#{t.id}] #{t.status.to_s.upcase} (PID #{t.pid}, #{dur}): #{t.command}"
          end
        end

        def self.render_status(shell, task_mgr, rest)
          task_id = rest&.first
          if task_id.to_s.strip.empty?
            shell.output.puts "Usage: !tasks status <task_id>"
            return
          end

          task = task_mgr.get(task_id)
          unless task
            shell.output.puts "Task '#{task_id}' not found."
            return
          end

          dur = task.running? ? "running (#{task.uptime.round(1)}s)" : "#{task.status} (exit #{task.exit_code.inspect}, ran #{task.uptime.round(1)}s)"
          shell.output.puts "Task: #{task.id}"
          shell.output.puts "  Status:   #{dur}"
          shell.output.puts "  PID:      #{task.pid}"
          shell.output.puts "  Command:  #{task.command}"
          shell.output.puts "  Buffered: #{task.ring_buffer.size} lines"
        end

        def self.render_logs(shell, task_mgr, rest)
          rest ||= []
          task_id = rest.first
          if task_id.to_s.strip.empty?
            shell.output.puts "Usage: !tasks logs <task_id> [--tail N]"
            return
          end

          tail = 50
          tail_idx = rest.index("--tail") || rest.index("-n")
          tail = rest[tail_idx + 1].to_i if tail_idx && rest[tail_idx + 1]

          task = task_mgr.get(task_id)
          unless task
            shell.output.puts "Task '#{task_id}' not found."
            return
          end

          lines = task.ring_buffer.tail(tail)
          if lines.empty?
            shell.output.puts "No logs recorded for task '#{task_id}' yet."
          else
            shell.output.puts "=== Logs for #{task.id} (last #{lines.size} lines) ==="
            lines.each { |line| shell.output.puts line }
          end
        end
      end
    end
  end
end
