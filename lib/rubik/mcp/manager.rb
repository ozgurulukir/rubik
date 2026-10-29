# frozen_string_literal: true

require "monitor"
require_relative "boot_lifecycle"
require_relative "client"
require_relative "proxy_tool"
require_relative "errors"
require_relative "../runtime/context"

module Rubik
  module MCP
    class Manager
      include BootLifecycle

      attr_reader :config, :root_dir, :servers, :clients, :tools, :guard
      attr_accessor :tools_registry, :runtime_manager, :context

      # Frozen-by-copy snapshot of the boot states (Context#services
      # precedent); the guarded write path is transition_server!. The former
      # attr_reader handed out the live hash — an unlocked race against the
      # boot thread. Read through this door.
      def statuses
        @monitor.synchronize { @statuses.dup }
      end

      # Boot race gate state (mcp-async-boot D5): true while the manager is
      # being torn down, so an in-flight boot thread never applies state into
      # a dying context.
      def stopped?
        @stopped
      end

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
        # Boot race guards (mcp-async-boot D5/D6): @stopped flips when the
        # manager is being torn down; :connecting marks are tagged with the
        # boot epoch that owns them (@boot_marks).
        @stopped = false
        @boot_thread = nil
        @boot_slot = nil
        @boot_marks = {}
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

        @monitor.synchronize do
          @servers[name_str] = parsed_defn
          @statuses[name_str] ||= :disabled

          if @config && persist && @config.persisting?(persist)
            server_hash = {
              "command" => parsed_defn["command"],
              "args" => Array(parsed_defn["args"]),
              "env" => parsed_defn["env"] || {}
            }
            # Per-server handshake override round-trips only when present,
            # so `!mcp add` output stays minimal (the knob is hand-written
            # config, not a CLI flag).
            server_hash["timeout"] = parsed_defn["timeout"] if parsed_defn["timeout"]
            persist_res = @config.set("mcp.servers.#{name_str}", server_hash, persist: persist)
          end

          transition_server!(name_str, :disabled) unless auto_start && enabled?
        end

        enable_server(name_str) if auto_start && enabled?

        tools_count = @monitor.synchronize { (@tools[name_str] || []).size }
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
          clear_server_record!(name_str)

          persist_res = @config.delete("mcp.servers.#{name_str}", persist: persist) if @config
        end
        persist_res
      end

      # Connect phase of enable_server: PURE I/O — client construction,
      # spawn + initialize handshake, tools/list. No monitor, no context
      # wiring, no registry mutation, so config-boot fan-out can overlap
      # many of these on the concurrency boundary while every state change
      # stays sequential in apply_connected_server.
      def connect_server(name_str, server_defn, timeout: nil)
        cmd = server_defn["command"] || server_defn[:command]
        args = server_defn["args"] || server_defn[:args] || []
        env = server_defn["env"] || server_defn[:env] || {}
        base_ctx = @context || @runtime_manager&.context
        connect_timeout = resolve_connect_timeout(server_defn, timeout)
        # Config boundary (D2 mirror): validated for BOTH construction
        # routes — the client_factory DI seam replaces the client, not the
        # manager's own knob validation.
        call_timeout = resolve_call_timeout_config

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
              guard: @guard || (base_ctx ? Rubik::Coeffects.get(base_ctx, Rubik::Coeffects::GUARD) : nil),
              call_timeout: call_timeout
            )
          end

        begin
          client.start!(timeout: connect_timeout)
          { client: client, tools: client.list_tools(timeout: connect_timeout) }
        rescue StandardError, Interrupt => e
          # A failed handshake must not leak the spawned child process (the
          # boot fan-out's slot capture alone cannot stop it). Client#stop is
          # idempotent, so apply-phase rollback stays exactly-once.
          begin
            client.stop
          rescue StandardError => stop_err
            Rubik::Log.warn(:mcp, "failed to stop MCP client '#{name_str}' after failed handshake (#{stop_err.class}: #{stop_err.message})")
          end
          raise e
        end
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
          transition_server!(name_str, :active)
          client
        rescue StandardError => e
          transition_server!(name_str, :failed)
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
          rescue StandardError => stop_err
            Rubik::Log.warn(:mcp, "failed to stop rolled-back MCP client '#{name_str}' (#{stop_err.class}: #{stop_err.message})")
          end
          raise e
        end
      end

      def enable_server(name)
        name_str = name.to_s
        server_defn = nil
        epoch = nil
        @monitor.synchronize do
          server_defn = @servers[name_str]
          raise Rubik::MCP::Error, "MCP server '#{name_str}' not found" unless server_defn

          return @clients[name_str] if @statuses[name_str] == :active && @clients[name_str]&.running?

          epoch = Object.new
          transition_server!(name_str, :connecting)
          @boot_marks[name_str] = epoch
        end

        connected = begin
          connect_server(name_str, server_defn)
        rescue StandardError => e
          @monitor.synchronize do
            transition_server!(name_str, :failed, epoch: epoch)
          end
          raise e
        end

        @monitor.synchronize do
          if @stopped || @statuses[name_str] != :connecting || !@boot_marks[name_str].equal?(epoch)
            begin
              connected[:client].stop
            rescue StandardError => e
              Rubik::Log.warn(:mcp, "failed to stop rolled-back MCP client '#{name_str}' (#{e.class}: #{e.message})")
            end
            return @clients[name_str]
          end

          apply_connected_server(name_str, server_defn, **connected)
          transition_server!(name_str, :active, epoch: epoch)
          @clients[name_str]
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
          transition_server!(name_str, :disabled)
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

      # Config boot dispatcher (mcp-async-boot D4): synchronous by default,
      # or spawned onto a named background thread with async: true. The
      # thread is returned in async mode (test seam); sync mode returns nil
      # exactly as before. Repeated async boots first drain any previous
      # boot thread (AstWarmup precedent) and re-open the @stopped gate; the
      # sync path re-opens it only when no boot thread is alive, so a wedged
      # background boot stays gated after a stop_all.
      def load_from_config(cfg = nil, async: false)
        unless async
          @monitor.synchronize { @stopped = false if @boot_thread.nil? }
          return perform_load_from_config(cfg)
        end

        join_boot_safely(2.0)
        epoch = Object.new
        @monitor.synchronize { @stopped = false }
        thread = Thread.new do
          perform_load_from_config(cfg)
        rescue StandardError, Interrupt => e
          Rubik::Log.warn(:mcp, "background MCP boot failed (#{e.class}: #{e.message})")
        ensure
          # Epoch-tagged clear: only clear OUR reference so a wedged boot A
          # expiring past the drain bound cannot clobber a newer boot B's slot.
          @monitor.synchronize do
            if @boot_slot && @boot_slot[:epoch].equal?(epoch)
              @boot_slot = nil
              @boot_thread = nil
            end
          end
        end
        thread.name = "rubik-mcp-boot" if thread.respond_to?(:name=)
        @monitor.synchronize do
          if thread.alive?
            @boot_slot = { thread: thread, epoch: epoch }
            @boot_thread = thread
          elsif @boot_slot && @boot_slot[:epoch].equal?(epoch)
            @boot_slot = nil
            @boot_thread = nil
          end
        end
        thread
      end

      private

      # Config boot, decomposed into the named phases over the concurrency
      # boundary so N servers' connect handshakes (spawn + initialize +
      # tools/list — the slow I/O) overlap while every observable state
      # change stays sequential in config order. Boot wall clock goes
      # sum(per-server) → max(per-server); one hung server no longer delays
      # the rest. Pure orchestration below: each phase is a private method,
      # moved verbatim from the former single body (zero logic change).
      def perform_load_from_config(cfg = nil)
        target_config = cfg || @config
        return unless target_config

        mcp_enabled = target_config.fetch("mcp.enabled", true) != false
        servers_cfg = target_config.fetch("mcp.servers", {})
        return unless servers_cfg.is_a?(Hash)

        # Boot epoch (review round): :connecting marks are tagged with a
        # per-invocation identity so a wedged older boot's failure branch or
        # ensure sweep can never downgrade a newer boot's fresh mark.
        boot_epoch = Object.new
        entries = register_config_servers(servers_cfg, mcp_enabled, boot_epoch)

        # Phase 1 deliberately did no context wiring, so stopping the client
        # is the ONLY cleanup an unapplied prepared slot owes — no orphaned
        # child processes, even when an interrupt lands mid-boot. One ensure
        # spans both post-registration phases.
        connected = ::Array.new(entries.size)
        outcomes = {}
        begin
          connect_fanout(entries, connected)
          apply_connected_slots(entries, connected, boot_epoch, outcomes)
        ensure
          stop_unapplied_clients(entries, connected, outcomes)
          fail_orphaned_connecting_marks(entries, boot_epoch)
        end
        nil
      end

      # Phase 0 (sequential, config order): registration still goes
      # through add_server — subclasses and plugins wrap that seam, and a
      # broken definition must fail exactly as before (logged, skipped,
      # not half-registered). auto_start is deliberately false here: the
      # connect half moved to the fan-out. Ends each auto-start candidate
      # with the phase-0 claim (D5) and returns the entries to boot.
      def register_config_servers(servers_cfg, mcp_enabled, boot_epoch)
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
            emit_mcp_event(:mcp_server_failed, :err, sname.to_s, error: e.message)
            next
          end
          next unless auto_start

          name_str = sname.to_s
          # Phase-0 claim (D5): check+mark in ONE monitor hold — a user
          # enable/disable/remove that races the boot reads a definite
          # state, and phase 2's gate below can never miss a window.
          entries << [name_str, sdefn.transform_keys(&:to_s)] unless claim_boot_slot!(name_str, boot_epoch)
        end
        entries
      end

      # Phase 1 (fan-out): pure I/O connects. Slots are captured by SIDE
      # EFFECT inside the item blocks: when an Exception-level error (a
      # boot interrupt) kills .map before it returns, the assignment below
      # never happens — a value-only `connected` would leave the ensure
      # blind to every successfully-started client. Hence the pre-built
      # array passed in rather than a returned value.
      def connect_fanout(entries, connected)
        return if entries.empty?

        Rubik::Concurrency.map(entries.each_with_index.to_a) do |(name_str, parsed_defn), index|
          connected[index] = { ok: true, **connect_server(name_str, parsed_defn) }
        rescue StandardError => e
          connected[index] = { ok: false, error: e }
        end
      end

      # Phase 2 (sequential, config order): apply state; identical
      # per-server warning on either phase's failure. Outcomes ledger is an
      # explicit atom map (index -> :applied | :failed; absence = skipped or
      # never ran — exactly what owes_stop? reads).
      def apply_connected_slots(entries, connected, boot_epoch, outcomes)
        entries.each_with_index do |(name_str, parsed_defn), index|
          slot = connected[index]
          next unless slot # never connected (interrupt during phase 1)

          if slot[:ok]
            begin
              outcome = @monitor.synchronize do
                # Single race gate (D5), checked at apply time under the
                # monitor: a disable/remove/enable during boot wins over
                # the boot's own apply, and a stop_all skips it entirely.
                # Epoch-complete gate: this boot may only apply into the
                # slot its own phase-0 claim marked, so a user decision
                # that moved the slot or a newer boot's fresh mark wins.
                # In the synchronous path nothing can interleave, so the
                # guard is provably inert there.
                if @stopped || @statuses[name_str] != :connecting || !@boot_marks[name_str].equal?(boot_epoch)
                  :skipped
                else
                  apply_connected_server(name_str, parsed_defn, client: slot[:client], tools: slot[:tools])
                  # Post-apply revalidation under the boot actor: a no-op
                  # when apply already landed :active.
                  transition_server!(name_str, :active, epoch: boot_epoch)
                  :applied
                end
              end
              outcomes[index] = :applied if outcome == :applied
              emit_mcp_event(:mcp_server_loaded, :info, name_str, tools: (@tools[name_str] || []).size) if outcome == :applied
            rescue StandardError => e
              # ENSURE-LOG (G3 round-1): one broken server config used to
              # vanish behind an ENV["RUBIK_DEBUG"] gate; a misconfigured
              # server must surface without debug mode. apply's own
              # rollback already set :failed and stopped its client via
              # the context drain; :failed marks the slot so the ensure
              # never double-stops it.
              outcomes[index] = :failed
              Rubik::Log.warn(:mcp, "failed to load MCP server '#{name_str}' (#{e.class}: #{e.message})")
              emit_mcp_event(:mcp_server_failed, :err, name_str, error: e.message)
            end
          else
            # Only our own epoch's mark may flip to :failed — a user
            # disable/remove during the handshake, or a newer boot's fresh
            # mark, must win over this boot's connect failure (D5). The
            # epoch gate and flip happen in the same monitor hold inside
            # transition_server!.
            transition_server!(name_str, :failed, epoch: boot_epoch)
            error = slot[:error]
            Rubik::Log.warn(:mcp, "failed to load MCP server '#{name_str}' (#{error.class}: #{error.message})")
            emit_mcp_event(:mcp_server_failed, :err, name_str, error: error.message)
          end
        end
      end

      # Ensure part 1: stop every prepared client that did not end up
      # registered: a failed apply already rolled its own client back via
      # the context drain, while a never-applied one (interrupt between
      # phases) owes a stop here. A :skipped slot also owes a stop —
      # skipping the APPLY must not orphan its prepared child process (that
      # is the exact leak D10 closed for handshakes). owes_stop? is the
      # structural form of that rule: skipped and never-ran slots owe.
      def stop_unapplied_clients(entries, connected, outcomes)
        entries.each_with_index do |(name_str, _defn), index|
          slot = connected[index]
          next if !slot.is_a?(Hash) || !slot[:client] || !BootLifecycle.owes_stop?(outcomes[index])

          registered = @monitor.synchronize { @clients[name_str] }
          next if registered.equal?(slot[:client])

          begin
            slot[:client].stop
          rescue StandardError => e
            Rubik::Log.warn(:mcp, "failed to stop unapplied MCP server '#{name_str}' (#{e.class}: #{e.message})")
          end
        end
      end

      # Ensure part 2 — terminal state for boot entries that never reached
      # apply (D6): anything still :connecting failed to boot; user-chosen
      # values (:disabled, :active, deleted-by-remove) are left untouched.
      # The epoch check inside transition_server! keeps an older wedged
      # boot's sweep from downgrading a newer boot's fresh mark.
      def fail_orphaned_connecting_marks(entries, boot_epoch)
        entries.each do |(name_str, _defn)|
          transition_server!(name_str, :failed, epoch: boot_epoch)
        end
      end

      public

      # Teardown (mcp-async-boot slice 3): arms the boot gate, drains an
      # in-flight boot thread, then disables every server. The join happens
      # OUTSIDE the monitor (G5): the boot thread takes @monitor in its apply
      # phase, so joining under it would deadlock.
      def stop_all(join_timeout: 2.0)
        @monitor.synchronize { @stopped = true }
        join_boot_safely(join_timeout)

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

      private

      # Boot observability door (mcp-async-boot D7): publish through the
      # session event bus so the dispatcher's dmesg door records boot
      # outcomes under the "mcp" subsystem. post (enqueue) — never emit
      # (drain): the caller may be the boot thread. An unresolved bus
      # (headless manager) is a no-op; a failing post is a warn, never a
      # boot failure.
      def emit_mcp_event(event_name, level, name_str, **data)
        ctx = @context || @runtime_manager&.context
        bus = Rubik::Coeffects.get(ctx, Rubik::Coeffects::EVENTS)
        return unless bus.respond_to?(:post)

        bus.post(event_name, { server: name_str }, subsystem: :mcp, level: level, **data)
      rescue StandardError => e
        Rubik::Log.warn(:mcp, "failed to emit MCP event '#{event_name}' (#{e.class}: #{e.message})")
      end

      # Bounded drain of the boot thread. Mechanics live in
      # Concurrency::Join (monotonic-deadline poll, never raises); the
      # still-alive warn and the :mcp log channel stay here. Reads
      # @boot_thread under the monitor but joins OUTSIDE it (G5).
      def join_boot_safely(timeout = nil)
        result = Rubik::Concurrency::Join.thread(@monitor.synchronize { @boot_thread }, timeout: timeout)
        case result
        when :timeout
          Rubik::Log.warn(:mcp, "MCP boot thread still alive after #{timeout}s join; continuing (stop gate armed)")
        when StandardError
          Rubik::Log.warn(:mcp, "MCP boot thread join failed (#{result.class}: #{result.message})")
        end
        nil
      rescue StandardError => e
        # Join.thread never raises; this covers the monitor acquisition
        # (and Log itself) — hence "drain", not "join".
        Rubik::Log.warn(:mcp, "MCP boot thread drain failed (#{e.class}: #{e.message})")
        nil
      end

      # mcp.call_timeout at the config boundary (D2 mirror): an invalid
      # value warns and falls through to the client default, exactly like a
      # bad mcp.timeout — the knob must never fail the boot silently.
      def resolve_call_timeout_config
        raw = @config&.fetch("mcp.call_timeout", nil)
        return nil if raw.nil?
        return raw if raw.is_a?(Numeric) && raw.positive?

        Rubik::Log.warn(:mcp, "ignoring non-positive MCP call_timeout #{raw.inspect}; using the client default")
        nil
      end

      # Handshake timeout resolution (explicit kwarg > per-server "timeout" >
      # mcp.timeout config > DEFAULT_TIMEOUT). A non-positive value warns and
      # falls through to the next source — a miswritten knob must never fail
      # the boot at the config boundary.
      def resolve_connect_timeout(server_defn, explicit)
        sources = [explicit, server_defn["timeout"] || server_defn[:timeout]]
        cfg_timeout = @config&.fetch("mcp.timeout", nil)
        sources << cfg_timeout unless cfg_timeout.nil?

        sources.each do |candidate|
          return candidate if candidate.is_a?(Numeric) && candidate.positive?
          next if candidate.nil?

          Rubik::Log.warn(:mcp, "ignoring non-positive MCP timeout #{candidate.inspect}; falling back to the next source")
        end
        Client::DEFAULT_TIMEOUT
      end
    end
  end
end
