# frozen_string_literal: true

require_relative "base"
require_relative "../../tools"

module Rubik
  module REPL
    module Commands
      module System
        extend Base

        def self.register(shell)
          shell.register_command("help", description: "List available commands or show help for a command") do |args, ctx|
            if args.empty?
              ctx.out.puts "Available commands:"
              ctx.commands.sort.each do |cmd_name, meta|
                ctx.out.puts "  !#{cmd_name.ljust(14)} - #{meta[:description]}"
              end
            else
              target = args.first.downcase.delete_prefix("!")
              if (meta = ctx.commands[target])
                ctx.out.puts "!#{target}: #{meta[:description]}"
                ctx.out.puts "  #{meta[:usage]}" if meta[:usage]
              else
                ctx.out.puts "No help found for !#{target}"
              end
            end
          end

          shell.register_command("commands", description: "List all built-in and synthesized overlay commands") do |_args, ctx|
            ctx.out.puts "=== Rubik Registered REPL Commands ==="
            ctx.commands.sort.each do |name, meta|
              ctx.out.puts "  !#{name.ljust(16)} : #{meta[:description]}"
            end
          end

          shell.register_command("runtime", description: "Visually display active coeffects, fibers, toolbelt, and accumulator depth",
                                            audience: :both) do |args, ctx|
            target = args.first&.downcase || "all"
            ctx.out.puts inspect_tool(ctx).execute(target: target)
          end

          shell.register_command("fibers", description: "Visually display active, pending, and failed fibers with coeffect dependencies", audience: :both) do |_args, ctx|
            ctx.out.puts inspect_tool(ctx).execute(target: "fibers")
          end

          shell.register_command("agents", description: "Interactive agent/fiber board: states, progress, Omega depth, detail view", audience: :both) do |_args, ctx|
            Rubik::UI::Panel.render(ctx, ctx.theme)
          end

          shell.register_command("services", description: "Visually display provided runtime coeffects and service registry", audience: :both) do |_args, ctx|
            ctx.out.puts inspect_tool(ctx).execute(target: "services")
          end

          shell.register_command("quit", description: "Exit the REPL shell") { |_args, ctx| ctx.stop }
          shell.register_command("exit", description: "Exit the REPL shell") { |_args, ctx| ctx.stop }

          shell.register_command("clear", description: "Clear conversation history / dialogue turns") do |_args, ctx|
            ctx.conversation_history.clear
            ctx.out.puts "Conversation context cleared. Starting fresh topic."
          end

          shell.register_command("reset", description: "Reset conversation history and in-memory dialogue turns") do |_args, ctx|
            ctx.conversation_history.clear
            ctx.out.puts "Conversation context reset. Starting fresh topic."
          end

          shell.register_command("status", description: "Show system status", audience: :both) do |_args, ctx|
            proj = File.basename(Dir.pwd)
            branch = ctx.detect_git_branch || "no-git"
            routed = ctx.router.route(task_type: :default)
            ctx.out.puts "Project: #{proj} (#{branch})"
            ctx.out.puts "Default Model: #{routed[:spec]['provider']}/#{routed[:model]}"
            ctx.out.puts "Dirty buffer: #{ctx.buffer_manager.dirty?}"
          end
        end

        # The runtime/fibers/services trio share one inspector construction.
        private_class_method def self.inspect_tool(ctx)
          Rubik::Tools::InspectRuntimeTool.new(ctx.runtime_manager, ctx.build_tool_registry, ctx)
        end
      end
    end
  end
end
