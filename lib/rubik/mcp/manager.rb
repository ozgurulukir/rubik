# frozen_string_literal: true

require "monitor"
require_relative "client"
require_relative "proxy_tool"
require_relative "errors"
require_relative "../runtime/context"

module Rubik
  module MCP
    class Manager
      attr_reader :config, :root_dir, :servers, :clients, :tools, :statuses, :guard
      attr_accessor :tools_registry, :runtime_manager, :context

      def initialize(config: nil, tools_registry: nil, runtime_manager: nil, context: nil, root_dir: Dir.pwd, guard: nil,
                     client_factory: nil)
        @config = config
        @tools_registry = tools_registry
        @runtime_manager = runtime_manager
        @context = context || runtime_manager&.context
        @root_dir = File.expand_path(root_dir)
        @guard = guard
        # DI seam for tests: production always builds Rubik::MCP::Client.
        @client_factory = client_factory

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

      # Returns {ok:, tools:} — the config persist outcome plus the registered
      # tool count; ok is false when the disk write failed (the server still
      # runs for this session).
      def add_server(name, defn, auto_start: true, persist: nil)
        name_str = name.to_s
        parsed_defn = defn.is_a?(Hash) ? defn.transform_keys(&:to_s) : {}
        persist_res = { ok: true }
        tools_count = 0

        @monitor.synchronize do
          @servers[name_str] = parsed_defn
          @statuses[name_str] ||= :disabled

          if @config && persist && @config.persisting?(persist)
            server_hash = {
              "command" => parsed_defn["command"],
              "args" => Array(parsed_defn["args"]),
              "env" => parsed_defn["env"] || {}
            }
            persist_res = @config.set("mcp.servers.#{name_str}", server_hash, persist: persist)
          end

          if auto_start && enabled?
            enable_server(name_str)
          else
            @statuses[name_str] = :disabled
          end
          tools_count = (@tools[name_str] || []).size
        end

        persist_res.merge(tools: tools_count)
      end

      # Returns the config persist outcome ({ok:, error?:}); the server is
      # always torn down from the live session, deletion is idempotent.
      def remove_server(name, persist: nil)
        name_str = name.to_s
        persist_res = { ok: true }
        @monitor.synchronize do
          disable_server(name_str) if @statuses[name_str] == :active || @clients.key?(name_str)

          @servers.delete(name_str)
          @contexts.delete(name_str)
          @clients.delete(name_str)
          @tools.delete(name_str)
          @statuses.delete(name_str)

          persist_res = @config.delete("mcp.servers.#{name_str}", persist: persist) if @config
        end
        persist_res
      end

      # Connect phase of enable_server: PURE I/O — client construction,
      # spawn + initialize handshake, tools/list. No monitor, no context
      # wiring, no registry mutation, so config-boot fan-out can overlap
      # many of these on the concurrency boundary while every state change
      # stays sequential in apply_connected_server.
      def connect_server(name_str, server_defn)
        cmd = server_defn["command"] || server_defn[:command]
        args = server_defn["args"] || server_defn[:args] || []
        env = server_defn["env"] || server_defn[:env] || {}
        base_ctx = @context || @runtime_manager&.context

        client =
          if @client_factory
            @client_factory.call(cmd, args: args, env: env, name: name_str, root_dir: @root_dir,
                                      guard: @guard || (base_ctx ? Rubik::Coeffects.get(base_ctx, Rubik::Coeffects::GUARD) : nil))
          else
            Rubik::MCP::Client.new(
              cmd,
              args: args,
              env: env,
              name: name_str,
              root_dir: @root_dir,
              # Resolved live at connect time: the composed kwarg wins, but a
              # Manager built before wire_runtime_context still picks up the
              # session guard once the context provides it (construction-time
              # snapshots of coeffects go stale — this matches base_ctx above).
              guard: @guard || (base_ctx ? Rubik::Coeffects.get(base_ctx, Rubik::Coeffects::GUARD) : nil)
            )
          end

        client.start!
        { client: client, tools: client.list_tools }
      end

      # Apply phase of enable_server: the post-connect half, extracted
      # verbatim — context wiring FIRST (so any later failure cleans up via
      # the child drain), proxy registration, registry flips, and the
      # original rollback on failure. On ANY failure the client is stopped
      # exactly once: post-wiring via the context drain's on_dispose
      # inverse, pre-wiring via the explicit stop in the rescue (Client#stop
      # is idempotent, so the overlap is harmless). Callers hold @monitor.
      def apply_connected_server(name_str, _server_defn, client:, tools:)
        base_ctx = nil
        server_ctx = nil
        begin
          @contexts[name_str].dispose if @contexts[name_str] && !@contexts[name_str].disposed?

          base_ctx = @context || @runtime_manager&.context
          server_ctx = base_ctx ? base_ctx.extend : Rubik::Runtime::Context.new
          @contexts[name_str] = server_ctx

          if base_ctx
            base_ctx.provide("mcp:#{name_str}", client)
          else
            server_ctx.provide("mcp:#{name_str}", client)
          end
          server_ctx.on_dispose { client.stop }

          server_tools = []
          if @tools_registry
            tools.each do |tdef|
              proxy = Rubik::MCP::ProxyTool.new(server_name: name_str, tool_def: tdef, client: client)
              @tools_registry.register(proxy, origin: :mcp)
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
          # Lock order: unprovide OUTSIDE the child drain — child disposal
          # must never acquire an ancestor's monitor (see Context#prune_child).
          base_ctx&.unprovide("mcp:#{name_str}")
          @contexts.delete(name_str)
          @clients.delete(name_str)
          @tools.delete(name_str)
          # Post-wiring failures stopped the client via the ctx drain above;
          # pre-wiring failures (stale-context dispose, ctx.extend) reach
          # only this line — idempotent Client#stop makes it exactly-once.
          begin
            client.stop
          rescue StandardError
            nil
          end
          raise e
        end
      end

      def enable_server(name)
        name_str = name.to_s
        @monitor.synchronize do
          server_defn = @servers[name_str]
          raise Rubik::MCP::Error, "MCP server '#{name_str}' not found" unless server_defn

          return @clients[name_str] if @statuses[name_str] == :active && @clients[name_str]&.running?

          connected = begin
            connect_server(name_str, server_defn)
          rescue StandardError
            @statuses[name_str] = :failed
            raise
          end
          apply_connected_server(name_str, server_defn, **connected)
        end
      end

      def disable_server(name)
        name_str = name.to_s
        @monitor.synchronize do
          raise Rubik::MCP::Error, "MCP server '#{name_str}' not found" unless @servers.key?(name_str)

          base_ctx = @context || @runtime_manager&.context
          ctx = @contexts[name_str]
          if ctx && !ctx.disposed?
            ctx.dispose
            # Lock order: unprovide OUTSIDE the child drain — child disposal
            # must never acquire an ancestor's monitor (see Context#prune_child).
            base_ctx&.unprovide("mcp:#{name_str}")
          elsif @clients[name_str]
            @clients[name_str].stop
            base_ctx&.unprovide("mcp:#{name_str}")
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

      # Config boot, two phases over the concurrency boundary so N servers'
      # connect handshakes (spawn + initialize + tools/list — the slow I/O)
      # overlap while every observable state change stays sequential in
      # config order. Boot wall clock goes sum(per-server) → max(per-server);
      # one hung server no longer delays the rest. Per-server failure
      # isolation and log lines are byte-identical to the sequential path.
      def load_from_config(cfg = nil)
        target_config = cfg || @config
        return unless target_config

        mcp_enabled = target_config.fetch("mcp.enabled", true) != false
        servers_cfg = target_config.fetch("mcp.servers", {})
        return unless servers_cfg.is_a?(Hash)

        # Phase 0 (sequential, config order): registration still goes
        # through add_server — subclasses and plugins wrap that seam, and a
        # broken definition must fail exactly as before (logged, skipped,
        # not half-registered). auto_start is deliberately false here: the
        # connect half moved to the fan-out below.
        entries = []
        servers_cfg.each do |sname, sdefn|
          next unless sdefn.is_a?(Hash)

          auto_start = mcp_enabled && (sdefn.fetch("enabled", true) != false)
          begin
            add_server(sname, sdefn, auto_start: false, persist: nil)
          rescue StandardError => e
            # ENSURE-LOG (G3 round-1): one broken server config used to
            # vanish behind an ENV["RUBIK_DEBUG"] gate; a misconfigured
            # server must surface without debug mode.
            Rubik::Log.warn(:mcp, "failed to load MCP server '#{sname}' (#{e.class}: #{e.message})")
            next
          end
          next unless auto_start

          name_str = sname.to_s
          already_active = @monitor.synchronize do
            @statuses[name_str] == :active && @clients[name_str]&.running?
          end
          entries << [name_str, sdefn.transform_keys(&:to_s)] unless already_active
        end

        # Phase 1 (fan-out): pure I/O connects. Slots are captured by SIDE
        # EFFECT inside the item blocks: when an Exception-level error (a
        # boot interrupt) kills .map before it returns, the assignment below
        # never happens — a value-only `connected` would leave the ensure
        # blind to every successfully-started client.
        # Phase 2 (sequential, config order): apply state; identical
        # per-server warning on either phase's failure. One ensure spans
        # both: phase 1 deliberately did no context wiring, so stopping the
        # client is the ONLY cleanup an unapplied prepared slot owes — no
        # orphaned child processes, even when an interrupt lands mid-boot.
        connected = ::Array.new(entries.size)
        applied = {}
        begin
          unless entries.empty?
            Rubik::Concurrency.map(entries.each_with_index.to_a) do |(name_str, parsed_defn), index|
              connected[index] = { ok: true, **connect_server(name_str, parsed_defn) }
            rescue StandardError => e
              connected[index] = { ok: false, error: e }
            end
          end

          entries.each_with_index do |(name_str, parsed_defn), index|
            slot = connected[index]
            next unless slot # never connected (interrupt during phase 1)

            if slot[:ok]
              begin
                @monitor.synchronize { apply_connected_server(name_str, parsed_defn, client: slot[:client], tools: slot[:tools]) }
                applied[index] = true
              rescue StandardError => e
                # ENSURE-LOG (G3 round-1): one broken server config used to
                # vanish behind an ENV["RUBIK_DEBUG"] gate; a misconfigured
                # server must surface without debug mode. apply's own
                # rollback already set :failed and stopped its client via
                # the context drain; :failed marks the slot so the ensure
                # never double-stops it.
                applied[index] = :failed
                Rubik::Log.warn(:mcp, "failed to load MCP server '#{name_str}' (#{e.class}: #{e.message})")
              end
            else
              @monitor.synchronize { @statuses[name_str] = :failed }
              error = slot[:error]
              Rubik::Log.warn(:mcp, "failed to load MCP server '#{name_str}' (#{error.class}: #{error.message})")
            end
          end
        ensure
          # Stop every prepared client that did not end up registered: a
          # failed apply already rolled its own client back via the context
          # drain (:failed marks those), while a never-applied one
          # (interrupt between phases) owes a stop here.
          entries.each_with_index do |(name_str, _defn), index|
            slot = connected[index]
            next if !slot.is_a?(Hash) || !slot[:client] || applied.key?(index)

            registered = @monitor.synchronize { @clients[name_str] }
            next if registered.equal?(slot[:client])

            begin
              slot[:client].stop
            rescue StandardError => e
              Rubik::Log.warn(:mcp, "failed to stop unapplied MCP server '#{name_str}' (#{e.class}: #{e.message})")
            end
          end
        end
        nil
      end

      def stop_all
        @monitor.synchronize do
          @servers.each_key do |name|
            disable_server(name)
          rescue StandardError => e
            Rubik::Log.warn(:mcp, "failed to stop MCP server '#{name}' during teardown (#{e.class}: #{e.message})")
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
