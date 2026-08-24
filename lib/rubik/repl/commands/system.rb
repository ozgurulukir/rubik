# frozen_string_literal: true

require_relative "base"
require_relative "../../tools"

module Rubik
  module REPL
    module Commands
      module System
        extend Base

        def self.register(shell)
          shell.register_command("help", description: "List available commands or show help for a command") do |args|
            if args.empty?
              shell.output.puts "Available commands:"
              shell.commands.sort.each do |cmd_name, meta|
                shell.output.puts "  !#{cmd_name.ljust(14)} - #{meta[:description]}"
              end
            else
              target = args.first.downcase.delete_prefix("!")
              if (meta = shell.commands[target])
                shell.output.puts "!#{target}: #{meta[:description]}"
              else
                shell.output.puts "No help found for !#{target}"
              end
            end
          end

          shell.register_command("commands", description: "List all built-in and synthesized overlay commands") do
            shell.output.puts "=== Rubik Registered REPL Commands ==="
            shell.commands.sort.each do |name, meta|
              shell.output.puts "  !#{name.ljust(16)} : #{meta[:description]}"
            end
          end

          shell.register_command("runtime", description: "Visually display active coeffects, fibers, toolbelt, and accumulator depth") do |args|
            target = args.first&.downcase || "all"
            tool = Rubik::Tools::InspectRuntimeTool.new(shell.runtime_manager, shell.build_tool_registry, shell)
            shell.output.puts tool.execute(target: target)
          end

          shell.register_command("fibers", description: "Visually display active, pending, and failed fibers with coeffect dependencies") do
            tool = Rubik::Tools::InspectRuntimeTool.new(shell.runtime_manager, shell.build_tool_registry, shell)
            shell.output.puts tool.execute(target: "fibers")
          end

          shell.register_command("services", description: "Visually display provided runtime coeffects and service registry") do
            tool = Rubik::Tools::InspectRuntimeTool.new(shell.runtime_manager, shell.build_tool_registry, shell)
            shell.output.puts tool.execute(target: "services")
          end

          shell.register_command("quit", description: "Exit the REPL shell") { shell.stop }
          shell.register_command("exit", description: "Exit the REPL shell") { shell.stop }

          shell.register_command("clear", description: "Clear conversation history / dialogue turns") do
            shell.conversation_history.clear
            shell.output.puts "Conversation context cleared. Starting fresh topic."
          end

          shell.register_command("reset", description: "Reset conversation history and in-memory dialogue turns") do
            shell.conversation_history.clear
            shell.output.puts "Conversation context reset. Starting fresh topic."
          end

          shell.register_command("status", description: "Show system status") do
            proj = File.basename(Dir.pwd)
            branch = shell.detect_git_branch || "no-git"
            routed = shell.router.route(task_type: :default)
            shell.output.puts "Project: #{proj} (#{branch})"
            shell.output.puts "Default Model: #{routed[:spec]['provider']}/#{routed[:model]}"
            shell.output.puts "Dirty buffer: #{shell.buffer_manager.dirty?}"
          end
        end
      end
    end
  end
end
