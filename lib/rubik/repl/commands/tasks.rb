# frozen_string_literal: true

require_relative "base"

module Rubik
  module REPL
    module Commands
      # REPL bang command (!tasks) for monitoring and controlling asynchronous
      # background tasks (Plan 93).
      module Tasks
        extend Base

        def self.register(shell)
          handler = lambda do |args, ctx|
            subcmd = args.first&.downcase
            task_mgr = ctx.task_manager

            unless task_mgr
              ctx.out.puts "TaskManager is not available."
              return
            end

            case subcmd
            when nil, "list"
              render_list(ctx, task_mgr)
            when "status"
              render_status(ctx, task_mgr, args[1..])
            when "logs"
              render_logs(ctx, task_mgr, args[1..])
            when "kill"
              task_id = args[1]
              if task_id.to_s.strip.empty?
                ctx.out.puts "Usage: !tasks kill <task_id>"
              elsif task_mgr.kill(task_id)
                ctx.out.puts "Task '#{task_id}' killed."
              else
                ctx.out.puts "Task '#{task_id}' not found."
              end
            when "kill-all", "killall"
              task_mgr.kill_all
              ctx.out.puts "All background tasks terminated."
            else
              ctx.out.puts "Unknown !tasks subcommand: #{subcmd}. Usage: !tasks [list | status <id> | logs <id> [--tail N] | kill <id> | kill-all]"
            end
          end

          shell.register_command("tasks", description: "Manage background asynchronous tasks (list, status, logs, kill, kill-all)", audience: :both, &handler)
          shell.register_command("task", description: "Alias for !tasks", audience: :both, &handler)
        end

        def self.render_list(ctx, task_mgr)
          tasks = task_mgr.list
          if tasks.empty?
            ctx.out.puts "No background tasks currently running or tracked."
            return
          end

          ctx.out.puts "=== Background Tasks (#{tasks.size}) ==="
          tasks.each do |t|
            dur = t.running? ? "up #{t.uptime.round(1)}s" : "exit #{t.exit_code}"
            ctx.out.puts "  • [#{t.id}] #{t.status.to_s.upcase} (PID #{t.pid}, #{dur}): #{t.command}"
          end
        end

        def self.render_status(ctx, task_mgr, rest)
          task_id = rest&.first
          if task_id.to_s.strip.empty?
            ctx.out.puts "Usage: !tasks status <task_id>"
            return
          end

          task = task_mgr.get(task_id)
          unless task
            ctx.out.puts "Task '#{task_id}' not found."
            return
          end

          dur = task.running? ? "running (#{task.uptime.round(1)}s)" : "#{task.status} (exit #{task.exit_code.inspect}, ran #{task.uptime.round(1)}s)"
          ctx.out.puts "Task: #{task.id}"
          ctx.out.puts "  Status:   #{dur}"
          ctx.out.puts "  PID:      #{task.pid}"
          ctx.out.puts "  Command:  #{task.command}"
          ctx.out.puts "  Buffered: #{task.ring_buffer.size} lines"
        end

        def self.render_logs(ctx, task_mgr, rest)
          rest ||= []
          task_id = rest.first
          if task_id.to_s.strip.empty?
            ctx.out.puts "Usage: !tasks logs <task_id> [--tail N]"
            return
          end

          tail = 50
          tail_idx = rest.index("--tail") || rest.index("-n")
          tail = rest[tail_idx + 1].to_i if tail_idx && rest[tail_idx + 1]

          task = task_mgr.get(task_id)
          unless task
            ctx.out.puts "Task '#{task_id}' not found."
            return
          end

          lines = task.ring_buffer.tail(tail)
          if lines.empty?
            ctx.out.puts "No logs recorded for task '#{task_id}' yet."
          else
            ctx.out.puts "=== Logs for #{task.id} (last #{lines.size} lines) ==="
            lines.each { |line| ctx.out.puts line }
          end
        end
      end
    end
  end
end
