# frozen_string_literal: true

require "monitor"
require_relative "client"
require_relative "proxy_tool"
require_relative "errors"
require_relative "../runtime/context"

module Rubik
  module MCP
    class Manager
      attr_reader :config, :root_dir, :servers, :clients, :tools, :statuses
      attr_accessor :tools_registry, :runtime_manager, :context

      def initialize(config: nil, tools_registry: nil, runtime_manager: nil, context: nil, root_dir: Dir.pwd)
        @config = config
        @tools_registry = tools_registry
        @runtime_manager = runtime_manager
        @context = context || runtime_manager&.context
        @root_dir = File.expand_path(root_dir)

        @servers = {}
        @clients = {}
        @contexts = {}
        @tools = {}
        @statuses = {}
        @monitor = Monitor.new
      end

      def enabled?
        return true unless @config

        @config.fetch("mcp.enabled", true) != false
      end

      def add_server(name, defn, auto_start: true, persist: nil)
        name_str = name.to_s
        parsed_defn = defn.is_a?(Hash) ? defn.transform_keys(&:to_s) : {}

        @monitor.synchronize do
          @servers[name_str] = parsed_defn
          @statuses[name_str] ||= :disabled

          if @config && persist && persist != :session && persist != "session"
            server_hash = {
              "command" => parsed_defn["command"],
              "args" => Array(parsed_defn["args"]),
              "env" => parsed_defn["env"] || {}
            }
            @config.set("mcp.servers.#{name_str}", server_hash, persist: persist)
          end

          if auto_start && enabled?
            enable_server(name_str)
          else
            @statuses[name_str] = :disabled
          end
        end
      end

      def remove_server(name, persist: nil)
        name_str = name.to_s
        @monitor.synchronize do
          disable_server(name_str) if @statuses[name_str] == :active || @clients.key?(name_str)

          @servers.delete(name_str)
          @contexts.delete(name_str)
          @clients.delete(name_str)
          @tools.delete(name_str)
          @statuses.delete(name_str)

          if @config
            if persist && persist != :session && persist != "session" && @config.respond_to?(:transaction)
              begin
                @config.transaction(persist) do |store|
                  store["mcp"]["servers"].delete(name_str) if store && store["mcp"] && store["mcp"]["servers"]
                end
              rescue StandardError => e
                warn "[WARN] Failed to delete MCP server from store: #{e.message}" if ENV["RUBIK_DEBUG"]
              end
            end

            if @config.respond_to?(:data) && @config.data.is_a?(Hash)
              mcp_node = @config.data["mcp"]
              mcp_node["servers"]&.delete(name_str) if mcp_node.is_a?(Hash) && mcp_node["servers"].is_a?(Hash)
            end
          end

          true
        end
      end

      def enable_server(name)
        name_str = name.to_s
        @monitor.synchronize do
          server_defn = @servers[name_str]
          raise Rubik::MCP::Error, "MCP server '#{name_str}' not found" unless server_defn

          return @clients[name_str] if @statuses[name_str] == :active && @clients[name_str]&.running?

          @contexts[name_str].dispose if @contexts[name_str] && !@contexts[name_str].disposed?

          base_ctx = @context || @runtime_manager&.context
          server_ctx = base_ctx ? base_ctx.extend : Rubik::Runtime::Context.new
          @contexts[name_str] = server_ctx

          begin
            cmd = server_defn["command"] || server_defn[:command]
            args = server_defn["args"] || server_defn[:args] || []
            env = server_defn["env"] || server_defn[:env] || {}

            client = Rubik::MCP::Client.new(
              cmd,
              args: args,
              env: env,
              name: name_str,
              root_dir: @root_dir
            )

            client.start!

            if base_ctx
              base_ctx.provide("mcp:#{name_str}", client)
              server_ctx.on_dispose do
                base_ctx.instance_variable_get(:@services)&.delete("mcp:#{name_str}")
              end
            else
              server_ctx.provide("mcp:#{name_str}", client)
            end
            server_ctx.on_dispose { client.stop }

            tool_defs = client.list_tools
            server_tools = []
            if @tools_registry
              tool_defs.each do |tdef|
                proxy = Rubik::MCP::ProxyTool.new(server_name: name_str, tool_def: tdef, client: client)
                @tools_registry.register(proxy)
                server_tools << proxy
                server_ctx.on_dispose { @tools_registry.unregister(proxy.name) }
              end
            end

            @tools[name_str] = server_tools
            @clients[name_str] = client
            @statuses[name_str] = :active
            client
          rescue StandardError => e
            @statuses[name_str] = :failed
            server_ctx.dispose if server_ctx && !server_ctx.disposed?
            @contexts.delete(name_str)
            @clients.delete(name_str)
            @tools.delete(name_str)
            raise e
          end
        end
      end

      def disable_server(name)
        name_str = name.to_s
        @monitor.synchronize do
          raise Rubik::MCP::Error, "MCP server '#{name_str}' not found" unless @servers.key?(name_str)

          ctx = @contexts[name_str]
          if ctx && !ctx.disposed?
            ctx.dispose
          elsif @clients[name_str]
            @clients[name_str].stop
          end

          @contexts.delete(name_str)
          @clients.delete(name_str)
          @tools.delete(name_str)
          @statuses[name_str] = :disabled
          true
        end
      end

      def connect(name, command, args = [], env = {})
        add_server(name, { "command" => command, "args" => args, "env" => env }, auto_start: true, persist: nil)
      end

      def disconnect(name)
        remove_server(name, persist: nil)
      end

      def ping(name)
        name_str = name.to_s
        client = @monitor.synchronize { @clients[name_str] }
        raise Rubik::MCP::Error, "MCP server '#{name_str}' is not running" unless client&.running?

        client.ping
      end

      def load_from_config(cfg = nil)
        target_config = cfg || @config
        return unless target_config

        mcp_enabled = target_config.fetch("mcp.enabled", true) != false
        servers_cfg = target_config.fetch("mcp.servers", {})
        return unless servers_cfg.is_a?(Hash)

        servers_cfg.each do |sname, sdefn|
          next unless sdefn.is_a?(Hash)

          auto_start = mcp_enabled && (sdefn.fetch("enabled", true) != false)
          begin
            add_server(sname, sdefn, auto_start: auto_start, persist: nil)
          rescue StandardError => e
            warn "[WARN] Failed to load MCP server '#{sname}': #{e.message}" if ENV["RUBIK_DEBUG"]
          end
        end
      end

      def stop_all
        @monitor.synchronize do
          @servers.each_key do |name|
            disable_server(name)
          rescue StandardError
            nil
          end
        end
      end
      alias dispose! stop_all
      alias dispose stop_all

      def status_summary
        @monitor.synchronize do
          @servers.map do |name, _defn|
            server_status(name)
          end.compact
        end
      end

      def server_status(name)
        name_str = name.to_s
        defn = @servers[name_str]
        return nil unless defn

        cmd_display = ([defn["command"] || defn[:command]] + Array(defn["args"] || defn[:args])).compact.join(" ")
        {
          name: name_str,
          status: @statuses[name_str] || :disabled,
          tools_count: (@tools[name_str] || []).size,
          tools: (@tools[name_str] || []).map(&:name),
          command: cmd_display
        }
      end

      def client(name)
        @monitor.synchronize { @clients[name.to_s] }
      end

      def active_tools
        @monitor.synchronize { @tools.values.flatten }
      end
    end
  end
end
