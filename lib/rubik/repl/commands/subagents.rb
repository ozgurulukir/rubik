# frozen_string_literal: true

require_relative "base"
require_relative "../../coeffects"

module Rubik
  module REPL
    module Commands
      # REPL bang command (!subagents) for monitoring and supervising autonomous
      # subagents (Plan 94 - Linux Init PID 1 Supervisor Model).
      module Subagents
        extend Base

        def self.register(shell)
          handler = lambda do |args, _ctx|
            subcmd = args.first&.downcase
            sup = resolve_supervisor(shell)

            unless sup
              shell.output.puts "SubagentSupervisor is not available."
              return
            end

            case subcmd
            when nil, "list"
              render_list(shell, sup)
            when "status"
              render_status(shell, sup, args[1])
            when "types"
              render_types(shell, sup)
            when "extend", "grant", "steps"
              handle_extend(shell, sup, args[1], args[2])
            when "wait"
              handle_wait(shell, sup, args[1], args[2])
            when "kill"
              handle_kill(shell, sup, args[1])
            when "kill-all", "killall"
              sup.kill_all
              shell.output.puts "All subagents terminated."
            else
              shell.output.puts "Unknown !subagents subcommand: '#{subcmd}'. " \
                                "Usage: !subagents [list | status <id> | types | wait [id] [sec] | extend <id> [steps] | kill <id> | kill-all]"
            end
          end

          description = "Supervise and manage autonomous subagents (list, status, types, extend, kill, kill-all)"
          shell.register_command("subagents", description: description, audience: :both, &handler)
          shell.register_command("subagent", description: "Alias for !subagents", audience: :both, &handler)
          shell.register_command("agents", description: "Alias for !subagents", audience: :both, &handler)
        end

        def self.resolve_supervisor(shell)
          return shell.subagent_supervisor if shell.respond_to?(:subagent_supervisor) && shell.subagent_supervisor
          return nil unless shell.runtime_manager&.context.respond_to?(:get)

          Rubik::Coeffects.get(shell.runtime_manager.context, Rubik::Coeffects::SUBAGENT_SUPERVISOR)
        end

        def self.render_list(shell, sup)
          instances = sup.list
          if instances.empty?
            shell.output.puts "No subagents currently running or tracked."
            return
          end

          shell.output.puts "=== Subagent Process Hierarchy (#{instances.size} tracked, #{sup.active_count} active) ==="
          instances.each do |inst|
            dur = inst.running? ? "up #{inst.uptime.round(1)}s" : "ended (#{inst.uptime.round(1)}s)"
            shell.output.puts "  • [#{inst.id}] #{inst.state.to_s.upcase} (role: #{inst.role}, type: #{inst.type_name}, #{dur})"
          end
        end

        def self.render_status(shell, sup, id)
          if id.to_s.strip.empty?
            shell.output.puts "Usage: !subagents status <subagent_id>"
            return
          end

          inst = sup.get(id)
          unless inst
            shell.output.puts "Subagent '#{id}' not found."
            return
          end

          shell.output.puts "Subagent: #{inst.id} (Parent: #{inst.parent_id})"
          shell.output.puts "  Role:        #{inst.role}"
          shell.output.puts "  Type:        #{inst.type_name}"
          shell.output.puts "  State:       #{inst.state.to_s.upcase}"
          shell.output.puts "  Steps:       #{inst.current_step}/#{inst.max_steps}"
          shell.output.puts "  Uptime:      #{inst.uptime.round(2)}s"
          shell.output.puts "  Workspace:   #{inst.workspace}"
          shell.output.puts "  Transcript:  #{inst.transcript_uri}"
          shell.output.puts "  Last Error:  #{inst.last_error}" if inst.last_error
          shell.output.puts "  Result:      #{inst.result.to_s.slice(0, 150)}..." if inst.result
        end

        def self.render_types(shell, sup)
          types = sup.type_registry.list
          shell.output.puts "=== Available Subagent Archetypes (#{types.size}) ==="
          types.each do |t|
            flags = []
            flags << "write" if t.enable_write_tools
            flags << "nesting" if t.enable_subagent_tools
            flag_str = flags.empty? ? "read-only" : flags.join(", ")
            shell.output.puts "  • #{t.name.ljust(12)} [#{flag_str}]: #{t.description}"
          end
        end

        def self.handle_kill(shell, sup, id)
          if id.to_s.strip.empty?
            shell.output.puts "Usage: !subagents kill <subagent_id>"
            return
          end

          if sup.kill(id)
            shell.output.puts "Subagent '#{id}' and child tree killed."
          else
            shell.output.puts "Subagent '#{id}' not found."
          end
        end

        def self.handle_extend(shell, sup, id, steps_arg)
          if id.to_s.strip.empty?
            shell.output.puts "Usage: !subagents extend <subagent_id> [additional_steps]"
            return
          end

          steps = (steps_arg || 10).to_i
          steps = 10 if steps <= 0
          if sup.extend_budget(id, steps)
            inst = sup.get(id)
            shell.output.puts "Extended budget for #{id} by #{steps} steps (total: #{inst.max_steps}, state: #{inst.state.to_s.upcase})."
          else
            shell.output.puts "Could not extend budget for #{id} (not found or inactive)."
          end
        end

        def self.handle_wait(shell, sup, arg1, arg2)
          ids = nil
          timeout = 30
          if arg1 =~ /^\d+$/
            timeout = arg1.to_i
          elsif arg1 && !arg1.empty?
            ids = [arg1]
            timeout = arg2.to_i if arg2 =~ /^\d+$/
          end

          shell.output.puts "Waiting for subagents (timeout: #{timeout}s)..."
          results = sup.wait_for(ids, timeout: timeout)
          return shell.output.puts "No active subagents tracked." if results.empty?

          shell.output.puts "=== Subagents Wait Finished (#{results.size}) ==="
          results.each do |r|
            shell.output.puts "  • #{r[:id].ljust(12)} [#{r[:state].to_s.upcase}]: #{r[:role]}"
          end
        end
      end
    end
  end
end
