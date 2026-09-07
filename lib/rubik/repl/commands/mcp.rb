# frozen_string_literal: true

require_relative "base"

module Rubik
  module REPL
    module Commands
      module Mcp
        extend Base

        def self.register(shell)
          shell.register_command("mcp",
                                 audience: :both,
                                 description: "Manage MCP servers (status|list|add|remove|enable|disable|connect|disconnect|ping)") do |args|
            manager = shell.mcp_manager
            unless manager
              shell.output.puts "MCP manager is not initialized."
              next
            end

            scope, clean_args = Base.parse_scope(args)
            sub = clean_args.first&.downcase || "status"

            case sub
            when "status"
              status_servers(shell, manager)
            when "list"
              list_tools(shell, manager, clean_args[1])
            when "add"
              name = clean_args[1]
              cmd = clean_args[2]
              server_args = clean_args[3..] || []
              if name.nil? || cmd.nil?
                shell.output.puts "Usage: !mcp add <name> <command> [args...] [-p|-g]"
                next
              end
              defn = { "command" => cmd, "args" => server_args }
              begin
                manager.add_server(name, defn, auto_start: true, persist: scope)
                tool_count = (manager.tools[name] || []).size
                shell.output.puts "MCP server '#{name}' added and started (#{tool_count} tool(s) registered) [#{Base.scope_label(scope)}]."
              rescue StandardError => e
                shell.output.puts "Failed to add/start MCP server '#{name}': #{e.message}"
              end
            when "remove", "rm", "delete"
              name = clean_args[1]
              if name.nil?
                shell.output.puts "Usage: !mcp remove <name> [-p|-g]"
                next
              end
              begin
                manager.remove_server(name, persist: scope)
                shell.output.puts "MCP server '#{name}' removed [#{Base.scope_label(scope)}]."
              rescue StandardError => e
                shell.output.puts "Failed to remove MCP server '#{name}': #{e.message}"
              end
            when "enable", "on", "start"
              name = clean_args[1]
              if name.nil?
                shell.output.puts "Usage: !mcp enable <name>"
                next
              end
              begin
                manager.enable_server(name)
                tool_count = (manager.tools[name] || []).size
                shell.output.puts "MCP server '#{name}' enabled (#{tool_count} tool(s) registered)."
              rescue StandardError => e
                shell.output.puts "Failed to enable MCP server '#{name}': #{e.message}"
              end
            when "disable", "off", "stop"
              name = clean_args[1]
              if name.nil?
                shell.output.puts "Usage: !mcp disable <name>"
                next
              end
              begin
                manager.disable_server(name)
                shell.output.puts "MCP server '#{name}' disabled and tools unregistered."
              rescue StandardError => e
                shell.output.puts "Failed to disable MCP server '#{name}': #{e.message}"
              end
            when "connect"
              name = clean_args[1]
              cmd = clean_args[2]
              server_args = clean_args[3..] || []
              if name.nil? || cmd.nil?
                shell.output.puts "Usage: !mcp connect <name> <command> [args...]"
                next
              end
              begin
                manager.connect(name, cmd, server_args)
                tool_count = (manager.tools[name] || []).size
                shell.output.puts "MCP server '#{name}' connected [Session only] (#{tool_count} tool(s) registered)."
              rescue StandardError => e
                shell.output.puts "Failed to connect MCP server '#{name}': #{e.message}"
              end
            when "disconnect"
              name = clean_args[1]
              if name.nil?
                shell.output.puts "Usage: !mcp disconnect <name>"
                next
              end
              begin
                manager.disconnect(name)
                shell.output.puts "MCP server '#{name}' disconnected."
              rescue StandardError => e
                shell.output.puts "Failed to disconnect MCP server '#{name}': #{e.message}"
              end
            when "ping"
              name = clean_args[1]
              if name.nil?
                shell.output.puts "Usage: !mcp ping <name>"
                next
              end
              begin
                latency = manager.ping(name)
                shell.output.puts "MCP server '#{name}' is alive (ping: #{latency} ms)."
              rescue StandardError => e
                shell.output.puts "Ping failed for MCP server '#{name}': #{e.message}"
              end
            else
              shell.output.puts "Unknown !mcp action '#{sub}'. Valid actions: status, list, add, remove, enable, disable, connect, disconnect, ping."
            end
          end
        end

        def self.status_servers(shell, manager)
          summary = manager.status_summary
          shell.output.puts "=== Model Context Protocol (MCP) Servers ==="
          shell.output.puts "  • Global Enabled : #{manager.enabled?}"
          shell.output.puts "  • Servers Count  : #{summary.size}"
          if summary.empty?
            shell.output.puts "\nNo MCP servers configured or active."
            shell.output.puts "Use '!mcp add <name> <command> [args...]' or '!mcp connect <name> <command>' to add one."
            return
          end

          shell.output.puts "\nConfigured Servers:"
          summary.each do |srv|
            badge = case srv[:status]
                    when :active then "[ACTIVE]"
                    when :failed then "[FAILED]"
                    else "[DISABLED]"
                    end
            shell.output.puts "  • #{srv[:name]} #{badge}"
            shell.output.puts "      Command : #{srv[:command]}"
            shell.output.puts "      Tools   : #{srv[:tools_count]} registered"
          end
        end

        def self.list_tools(shell, manager, target_server = nil)
          servers_to_check = if target_server
                               [target_server.to_s]
                             else
                               manager.servers.keys
                             end

          tools_found = 0
          servers_to_check.each do |sname|
            tools = manager.tools[sname] || []
            next if tools.empty?

            shell.output.puts "=== Tools for MCP Server '#{sname}' (#{tools.size}) ==="
            tools.each do |t|
              tools_found += 1
              shell.output.puts "  • #{t.name} : #{t.description}"
              props = t.params_schema["properties"] || {}
              unless props.empty?
                params_str = props.keys.join(", ")
                shell.output.puts "      Parameters: #{params_str}"
              end
            end
          end

          return unless tools_found.zero?

          if target_server
            shell.output.puts "No active tools found for MCP server '#{target_server}'."
          else
            shell.output.puts "No active MCP tools across servers."
          end
        end
      end
    end
  end
end
