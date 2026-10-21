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
        USAGE_SUBAGENTS = "Usage: !subagents [list | status <id> | wait [id] [sec] | extend <id> [steps] | resume [id] | reuse <id> <prompt> | clean | kill <id> | kill-all]"

        def self.register(shell)
          handler = lambda do |args, ctx|
            subcmd = args.first&.downcase
            sup = resolve_supervisor(ctx)

            unless sup
              ctx.out.puts "SubagentSupervisor is not available."
              return
            end

            case subcmd
            when nil, "list" then render_list(ctx, sup)
            when "status" then render_status(ctx, sup, args[1])
            when "types" then render_types(ctx, sup)
            when "extend", "grant", "steps" then handle_extend(ctx, sup, args[1], args[2])
            when "resume", "retry" then handle_resume(ctx, sup, args[1])
            when "reuse", "redeploy" then handle_reuse(ctx, sup, args[1], args[2..])
            when "clean", "reap" then handle_clean(ctx, sup)
            when "wait" then handle_wait(ctx, sup, args[1], args[2])
            when "kill" then handle_kill(ctx, sup, args[1])
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

        def self.resolve_supervisor(ctx) = ctx.subagent_supervisor

        def self.render_list(ctx, sup)
          instances = sup.list
          if instances.empty?
            ctx.out.puts "No subagents currently running or tracked."
            return
          end

          ctx.out.puts "=== Subagent Process Hierarchy (#{instances.size} tracked, #{sup.active_count} active) ==="
          instances.each do |inst|
            dur = if inst.running?
                    "up #{inst.uptime.round(1)}s"
                  elsif inst.state == :queued
                    "queued (waiting on: #{inst.depends_on.join(', ')})"
                  else
                    "ended (#{inst.uptime.round(1)}s)"
                  end
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
          # Canonical read reference (issue #123): the path above is diagnostic.
          ctx.out.puts "  Read Ref:    #{inst.transcript_ref}" if inst.respond_to?(:transcript_ref)
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
          return ctx.out.puts "Usage: !subagents kill <subagent_id>" if id.to_s.strip.empty?

          if sup.kill(id)
            ctx.out.puts "Subagent '#{id}' and child tree killed."
          else
            ctx.out.puts "Subagent '#{id}' not found."
          end
        end

        def self.handle_extend(ctx, sup, id, steps_arg)
          return ctx.out.puts "Usage: !subagents extend <subagent_id> [additional_steps]" if id.to_s.strip.empty?

          steps = Rubik::Orchestrator::Subagent::Budget.normalize_grant(steps_arg)
          if sup.extend_budget(id, steps)
            inst = sup.get(id)
            ceiling = inst.respond_to?(:max_total_steps) ? "/#{inst.max_total_steps}" : ""
            ctx.out.puts "Extended budget for #{id} by #{steps} steps (total: #{inst.max_steps}#{ceiling}, " \
                         "state: #{inst.state.to_s.upcase})."
          else
            inst = sup.get(id)
            msg = if inst&.respond_to?(:max_total_steps) && inst.max_steps >= inst.max_total_steps
                    "Could not extend budget for #{id}: lifetime step limit of #{inst.max_total_steps} reached."
                  else
                    "Could not extend budget for #{id} (not found or inactive)."
                  end
            ctx.out.puts msg
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

        # Context-preserving reuse of a finished subagent (maestro persona).
        def self.handle_reuse(ctx, sup, id, words)
          prompt = Array(words).join(" ").strip
          return ctx.out.puts "Usage: !subagents reuse <subagent_id> <new task prompt>" if id.to_s.strip.empty? || prompt.empty?

          begin
            inst = sup.redeploy(id, prompt: prompt)
            ctx.out.puts "Redeployed '#{id}' with a new task — context preserved (state: #{inst.state.to_s.upcase})."
          rescue ArgumentError => e
            ctx.out.puts e.message
          end
        end

        def self.handle_clean(ctx, sup)
          reaped = sup.reap_finished!(force: true)
          return ctx.out.puts "No finished subagents to reap." if reaped.empty?

          ctx.out.puts "Reaped #{reaped.size} finished subagent(s): #{reaped.join(', ')} (transcripts persist)."
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
          results.each { |r| ctx.out.puts "  • #{r[:id].ljust(12)} [#{r[:state].to_s.upcase}]: #{r[:role]}" }
        end
      end
    end
  end
end
