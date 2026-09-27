# frozen_string_literal: true

require_relative "base"
require_relative "../../orchestrator/subagent/budget"
require_relative "../../orchestrator/subagent/notices"

module Rubik
  module REPL
    module Commands
      # REPL bang command (!subagents) for monitoring and supervising autonomous
      # subagents (Plan 94 - Linux Init PID 1 Supervisor Model).
      module Subagents
        extend Base

        # Whole-command synopsis: shared by the spine registration (usage:)
        # and the unknown-subcommand fallback branch, so the two cannot drift.
        USAGE_SUBAGENTS = "Usage: !subagents [list | status <id> | types | wait [id] [sec] | extend <id> [steps] | resume [id] | kill <id> | kill-all]"

        def self.register(shell)
          handler = lambda do |args, ctx|
            subcmd = args.first&.downcase
            sup = resolve_supervisor(ctx)

            unless sup
              ctx.out.puts "SubagentSupervisor is not available."
              return
            end

            case subcmd
            when nil, "list"
              render_list(ctx, sup)
            when "status"
              render_status(ctx, sup, args[1])
            when "types"
              render_types(ctx, sup)
            when "extend", "grant", "steps"
              handle_extend(ctx, sup, args[1], args[2])
            when "resume", "retry"
              handle_resume(ctx, sup, args[1])
            when "wait"
              handle_wait(ctx, sup, args[1], args[2])
            when "kill"
              handle_kill(ctx, sup, args[1])
            when "kill-all", "killall"
              sup.kill_all
              ctx.out.puts "All subagents terminated."
            else
              ctx.out.puts "Unknown !subagents subcommand: '#{subcmd}'. #{USAGE_SUBAGENTS}"
            end
          end

          description = "Supervise and manage autonomous subagents (list, status, types, extend, resume, kill, kill-all)"
          shell.register_command("subagents", description: description, usage: USAGE_SUBAGENTS, audience: :both, &handler)
          shell.register_command("subagent", description: "Alias for !subagents", usage: USAGE_SUBAGENTS, audience: :both, &handler)
          # NB: no "agents" alias — System owns !agents (the interactive
          # agent/fiber board); a second registration here would silently
          # overwrite it (register_command only refuses custom-over-builtin).
        end

        def self.resolve_supervisor(ctx)
          ctx.subagent_supervisor
        end

        def self.render_list(ctx, sup)
          instances = sup.list
          if instances.empty?
            ctx.out.puts "No subagents currently running or tracked."
            return
          end

          ctx.out.puts "=== Subagent Process Hierarchy (#{instances.size} tracked, #{sup.active_count} active) ==="
          instances.each do |inst|
            dur = inst.running? ? "up #{inst.uptime.round(1)}s" : "ended (#{inst.uptime.round(1)}s)"
            ctx.out.puts "  • [#{inst.id}] #{inst.state.to_s.upcase} (role: #{inst.role}, type: #{inst.type_name}, #{dur})"
          end
        end

        def self.render_status(ctx, sup, id)
          if id.to_s.strip.empty?
            ctx.out.puts "Usage: !subagents status <subagent_id>"
            return
          end

          inst = sup.get(id)
          unless inst
            ctx.out.puts "Subagent '#{id}' not found."
            return
          end

          ctx.out.puts "Subagent: #{inst.id} (Parent: #{inst.parent_id})"
          ctx.out.puts "  Role:        #{inst.role}"
          ctx.out.puts "  Type:        #{inst.type_name}"
          ctx.out.puts "  State:       #{inst.state.to_s.upcase}"
          ctx.out.puts "  Steps:       #{inst.current_step}/#{inst.max_steps}"
          ctx.out.puts "  Uptime:      #{inst.uptime.round(2)}s"
          ctx.out.puts "  Workspace:   #{inst.workspace}"
          ctx.out.puts "  Transcript:  #{inst.transcript_uri}"
          ctx.out.puts "  Last Error:  #{inst.last_error}" if inst.last_error
          ctx.out.puts "  Result:      #{inst.result.to_s.slice(0, 150)}..." if inst.result
        end

        def self.render_types(ctx, sup)
          types = sup.type_registry.list
          ctx.out.puts "=== Available Subagent Archetypes (#{types.size}) ==="
          types.each do |t|
            flags = []
            flags << "write" if t.enable_write_tools
            flags << "nesting" if t.enable_subagent_tools
            flag_str = flags.empty? ? "read-only" : flags.join(", ")
            ctx.out.puts "  • #{t.name.ljust(12)} [#{flag_str}]: #{t.description}"
          end
        end

        def self.handle_kill(ctx, sup, id)
          if id.to_s.strip.empty?
            ctx.out.puts "Usage: !subagents kill <subagent_id>"
            return
          end

          if sup.kill(id)
            ctx.out.puts "Subagent '#{id}' and child tree killed."
          else
            ctx.out.puts "Subagent '#{id}' not found."
          end
        end

        def self.handle_extend(ctx, sup, id, steps_arg)
          if id.to_s.strip.empty?
            ctx.out.puts "Usage: !subagents extend <subagent_id> [additional_steps]"
            return
          end

          steps = Rubik::Orchestrator::Subagent::Budget.normalize_grant(steps_arg)
          if sup.extend_budget(id, steps)
            inst = sup.get(id)
            ctx.out.puts "Extended budget for #{id} by #{steps} steps (total: #{inst.max_steps}, state: #{inst.state.to_s.upcase})."
          else
            ctx.out.puts "Could not extend budget for #{id} (not found or inactive)."
          end
        end

        def self.handle_resume(ctx, sup, id)
          if id.to_s.strip.empty?
            resumed = sup.resume_all
            return ctx.out.puts "No paused subagents to resume." if resumed.empty?

            ctx.out.puts "Resumed #{resumed.size} subagent(s): #{resumed.join(', ')}."
          elsif sup.resume(id)
            inst = sup.get(id)
            ctx.out.puts "Resumed subagent '#{id}' (state: #{inst.state.to_s.upcase})."
          else
            ctx.out.puts "Could not resume subagent '#{id}' (not found or not in pausable state)."
          end
        end

        def self.handle_wait(ctx, sup, arg1, arg2)
          ids = nil
          timeout = Rubik::Orchestrator::Subagent::Notices::DEFAULT_WAIT_TIMEOUT
          if arg1 =~ /^\d+$/
            timeout = arg1.to_i
          elsif arg1 && !arg1.empty?
            ids = [arg1]
            timeout = arg2.to_i if arg2 =~ /^\d+$/
          end

          ctx.out.puts "Waiting for subagents (timeout: #{timeout}s)..."
          results = sup.wait_for(ids, timeout: timeout)
          return ctx.out.puts "No active subagents tracked." if results.empty?

          ctx.out.puts "=== Subagents Wait Finished (#{results.size}) ==="
          results.each do |r|
            ctx.out.puts "  • #{r[:id].ljust(12)} [#{r[:state].to_s.upcase}]: #{r[:role]}"
          end
        end
      end
    end
  end
end
