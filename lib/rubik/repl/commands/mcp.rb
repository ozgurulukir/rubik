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
                                 description: "Manage MCP servers (status|list|add|remove|enable|disable|connect|disconnect|ping)") do |args, ctx|
            manager = ctx.mcp_manager
            unless manager
              ctx.out.puts "MCP manager is not initialized."
              next
            end

            scope, clean_args = Base.parse_scope(args)
            sub = clean_args.first&.downcase || "status"

            case sub
            when "status"
              status_servers(ctx, manager)
            when "list"
              list_tools(ctx, manager, clean_args[1])
            when "add"
              handle_add(ctx, manager, clean_args, scope)
            when "remove", "rm", "delete"
              handle_remove(ctx, manager, clean_args, scope)
            when "enable", "on", "start"
              handle_enable(ctx, manager, clean_args)
            when "disable", "off", "stop"
              handle_disable(ctx, manager, clean_args)
            when "connect"
              handle_connect(ctx, manager, clean_args)
            when "disconnect"
              handle_disconnect(ctx, manager, clean_args)
            when "ping"
              handle_ping(ctx, manager, clean_args)
            else
              ctx.out.puts "Unknown !mcp action '#{sub}'. Valid actions: status, list, add, remove, enable, disable, connect, disconnect, ping."
            end
          end
        end

        def self.status_servers(ctx, manager)
          summary = manager.status_summary
          ctx.out.puts "=== Model Context Protocol (MCP) Servers ==="
          ctx.out.puts "  • Global Enabled : #{manager.enabled?}"
          ctx.out.puts "  • Servers Count  : #{summary.size}"
          if summary.empty?
            ctx.out.puts "\nNo MCP servers configured or active."
            ctx.out.puts "Use '!mcp add <name> <command> [args...]' or '!mcp connect <name> <command>' to add one."
            return
          end

          ctx.out.puts "\nConfigured Servers:"
          summary.each do |srv|
            badge = case srv[:status]
                    when :active then "[ACTIVE]"
                    when :connecting then "[CONNECTING]"
                    when :failed then "[FAILED]"
                    else "[DISABLED]"
                    end
            ctx.out.puts "  • #{srv[:name]} #{badge}"
            ctx.out.puts "      Command : #{srv[:command]}"
            ctx.out.puts "      Tools   : #{srv[:tools_count]} registered"
          end
        end

        def self.list_tools(ctx, manager, target_server = nil)
          servers_to_check = if target_server
                               [target_server.to_s]
                             else
                               manager.servers.keys
                             end

          tools_found = 0
          servers_to_check.each do |sname|
            tools = manager.tools[sname] || []
            next if tools.empty?

            ctx.out.puts "=== Tools for MCP Server '#{sname}' (#{tools.size}) ==="
            tools.each do |t|
              tools_found += 1
              ctx.out.puts "  • #{t.name} : #{t.description}"
              props = t.params_schema["properties"] || {}
              unless props.empty?
                params_str = props.keys.join(", ")
                ctx.out.puts "      Parameters: #{params_str}"
              end
            end
          end

          return unless tools_found.zero?

          if target_server
            ctx.out.puts "No active tools found for MCP server '#{target_server}'."
          else
            ctx.out.puts "No active MCP tools across servers."
          end
        end

        private_class_method def self.handle_add(ctx, manager, clean_args, scope)
          name = clean_args[1]
          cmd = clean_args[2]
          server_args = clean_args[3..] || []
          if name.nil? || cmd.nil?
            ctx.out.puts "Usage: !mcp add <name> <command> [args...] [-p|-g]"
            return
          end
          defn = { "command" => cmd, "args" => server_args }
          begin
            res = manager.add_server(name, defn, auto_start: true, persist: scope)
            if res[:ok]
              ctx.out.puts "MCP server '#{name}' added and started (#{res[:tools]} tool(s) registered) [#{Base.scope_label(scope)}]."
            else
              Base.report_persist_failure(ctx, res, scope)
            end
          rescue StandardError => e
            ctx.out.puts "Failed to add/start MCP server '#{name}': #{e.message}"
          end
        end

        private_class_method def self.handle_remove(ctx, manager, clean_args, scope)
          name = clean_args[1]
          if name.nil?
            ctx.out.puts "Usage: !mcp remove <name> [-p|-g]"
            return
          end
          begin
            res = manager.remove_server(name, persist: scope)
            if res[:ok]
              ctx.out.puts "MCP server '#{name}' removed [#{Base.scope_label(scope)}]."
            else
              Base.report_persist_failure(ctx, res, scope)
            end
          rescue StandardError => e
            ctx.out.puts "Failed to remove MCP server '#{name}': #{e.message}"
          end
        end

        private_class_method def self.handle_enable(ctx, manager, clean_args)
          name = clean_args[1]
          if name.nil?
            ctx.out.puts "Usage: !mcp enable <name>"
            return
          end
          begin
            manager.enable_server(name)
            tool_count = (manager.tools[name] || []).size
            ctx.out.puts "MCP server '#{name}' enabled (#{tool_count} tool(s) registered)."
          rescue StandardError => e
            ctx.out.puts "Failed to enable MCP server '#{name}': #{e.message}"
          end
        end

        private_class_method def self.handle_disable(ctx, manager, clean_args)
          name = clean_args[1]
          if name.nil?
            ctx.out.puts "Usage: !mcp disable <name>"
            return
          end
          begin
            manager.disable_server(name)
            ctx.out.puts "MCP server '#{name}' disabled and tools unregistered."
          rescue StandardError => e
            ctx.out.puts "Failed to disable MCP server '#{name}': #{e.message}"
          end
        end

        private_class_method def self.handle_connect(ctx, manager, clean_args)
          name = clean_args[1]
          cmd = clean_args[2]
          server_args = clean_args[3..] || []
          if name.nil? || cmd.nil?
            ctx.out.puts "Usage: !mcp connect <name> <command> [args...]"
            return
          end
          begin
            manager.connect(name, cmd, server_args)
            tool_count = (manager.tools[name] || []).size
            ctx.out.puts "MCP server '#{name}' connected [Session only] (#{tool_count} tool(s) registered)."
          rescue StandardError => e
            ctx.out.puts "Failed to connect MCP server '#{name}': #{e.message}"
          end
        end

        private_class_method def self.handle_disconnect(ctx, manager, clean_args)
          name = clean_args[1]
          if name.nil?
            ctx.out.puts "Usage: !mcp disconnect <name>"
            return
          end
          begin
            manager.disconnect(name)
            ctx.out.puts "MCP server '#{name}' disconnected."
          rescue StandardError => e
            ctx.out.puts "Failed to disconnect MCP server '#{name}': #{e.message}"
          end
        end

        private_class_method def self.handle_ping(ctx, manager, clean_args)
          name = clean_args[1]
          if name.nil?
            ctx.out.puts "Usage: !mcp ping <name>"
            return
          end
          begin
            latency = manager.ping(name)
            ctx.out.puts "MCP server '#{name}' is alive (ping: #{latency} ms)."
          rescue StandardError => e
            ctx.out.puts "Ping failed for MCP server '#{name}': #{e.message}"
          end
        end
      end
    end
  end
end
