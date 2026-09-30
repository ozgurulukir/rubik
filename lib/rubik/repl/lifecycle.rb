# frozen_string_literal: true

require_relative "../orchestrator/subagent/notices"
require_relative "pending_notice_queue"

module Rubik
  module REPL
    # Plan 63 Faz C: phased initialization collaborators extracted from Shell
    # (keeps shell.rb under the decoupling line-count gate). The Shell remains
    # the coordinator: these methods depend on shell identity, so they live in
    # an included module rather than in Composition (the pure builder).
    module Lifecycle
      # Plan 109 Faz B: notice kinds worth interrupting the idle prompt
      # with an autonomous agent-0 turn. Excludes :context_compacted
      # (self-healed, guidance says no action needed) and
      # :auto_apply_failed (informational; the subagent's own next step
      # reports it).
      WAKE_KINDS = [:completed, :budget_exhausted, :error_paused, :message, :task].freeze
      # Phase 1: assign built subsystems. Entries derive from the
      # ServiceCatalog (the single declaration point): one loop assigns every
      # injectable entry's ivar, then a second pass runs the per-entry
      # after_inject hooks (injected-buffer post-wiring — which runs only on
      # the buffer_manager kwarg route, where Composition did not own the
      # manager's config — and the ast_graph sync cache load). Optional
      # entries keep their respond_to? nil-guard for older parts fixtures.
      def inject_parts(parts, injected_buffer: false)
        values = {}
        ServiceCatalog.injectable.each do |entry|
          values[entry.name] =
            if entry.optional
              parts.respond_to?(entry.name) ? parts[entry.name] : nil
            else
              parts[entry.name]
            end
          instance_variable_set(:"@#{entry.name}", values[entry.name])
        end
        # Two passes by design: after_inject hooks may reference ANY entry's
        # value (the ast_graph cache load reads cache_store), so they run
        # only after every ivar is assigned — combining the loops would tie
        # hooks to catalog order.
        ServiceCatalog.wire_after_inject(values, parts, injected_buffer: injected_buffer)
      end

      # Phase 2: provide the core subsystems into the Runtime Coeffect
      # Context. Rows derive from the ServiceCatalog; canonical (long-form)
      # keys only — short forms ("buffer", "lsp", ...) remain readable via
      # Rubik::Coeffects LEGACY_ALIASES for third parties.
      def wire_runtime_context(parts)
        ServiceCatalog.wire_rows(self, parts).each { |key, value| @runtime_manager.provide(key, value) }
      end

      # Phase 3: plugins declared in config (gems, drop-ins, aliases).
      def load_plugins(parts)
        return unless @plugin_manager

        Array(@config.fetch("plugins.load", [])).each { |g| @plugin_manager.load_plugin_gem(g, runtime_manager: @runtime_manager) }
        if @config.fetch("plugins.autoload_dropin", true) && parts.respond_to?(:plugin_storage) && parts.plugin_storage
          @plugin_manager.load_dropin_plugins(runtime_manager: @runtime_manager, storage: parts.plugin_storage)
        end
        aliases_cfg = @config.fetch("plugins.aliases", {})
        aliases_cfg.each { |s, f| @plugin_manager.register_alias(s, f) } if aliases_cfg.is_a?(Hash)
      end

      # Phase 4: AST, context-index and agent-loop runtime services.
      def register_runtime_services
        Rubik::Runtime::ASTService.register(@runtime_manager, @ast_graph, cache_store: @cache_store)
        Rubik::Runtime::IndexService.register(@runtime_manager, @context_index)
        Rubik::Runtime::LoopService.register(@runtime_manager, shell: self)
        Rubik::Storage::Service.register(@runtime_manager, Rubik::Storage::Service.build(config: @config, root_dir: @root_dir))
      end

      # Phase 5: build the tool registry and publish it to the runtime.
      def build_and_provide_tool_registry
        @tool_registry = build_tool_registry
        @mcp_manager.tools_registry = @tool_registry if @mcp_manager
        @subagent_supervisor.tool_registry = @tool_registry if @subagent_supervisor.respond_to?(:tool_registry=)
        @runtime_manager.provide(:tool_registry, @tool_registry)
      end

      # Phase 6: UI theme/renderer wiring into the runtime.
      def sync_ui
        @ui_theme = Rubik::UI::Theme.for(@output, @config)
        @ui_renderer = Rubik::UI::RenderService.register(@runtime_manager, shell: self)
      end

      # Phase 7: route :default; on resolve, satisfy the `llm` coeffect.
      # Audit 1: rescue is intentional (credentials may be unconfigured).
      def sync_default_llm_route
        default_routed = @router.route(task_type: :default)
        @runtime_manager.provide(:llm_client, default_routed[:provider]) if default_routed && default_routed[:provider]
        @subagent_supervisor.router = @router if @subagent_supervisor.respond_to?(:router=)
      rescue StandardError => e
        debug_warn("Default LLM route unavailable at startup (coeffect stays pending): #{e.class}: #{e.message}")
      end

      # Reload the provider catalog from config and re-route the live client —
      # the mandatory pair after any providers.* mutation. Reactive wiring
      # (wire_llm_change) runs it for listener-driven changes; commands run it
      # explicitly because the Config verbs mutate the live spec hash in
      # place, so set sees old == new and never fires the providers.*
      # notification — dropping this "redundant-looking" refresh would
      # silently desync the registry.
      def refresh_llm_registry!
        llm_registry&.load_from_config(config)
        resync_llm_route!
      end

      # Live LLM re-route (reactive config wiring, !model/!provider switches):
      # re-open sticky routing so the next free-text turn re-resolves with the
      # new model (Plan 61 D-7), then re-provide the default llm_client
      # coeffect. A failing route keeps the previous client — the same silent
      # contract as the extracted Commands::AgentModels.sync_default_provider.
      def resync_llm_route!
        @conversation_route_stamp = nil
        default_routed = begin
          @router&.route(task_type: :default)
        rescue StandardError => e
          debug_warn("Live LLM re-route failed (keeping previous client): #{e.class}: #{e.message}")
          nil
        end
        return unless default_routed && default_routed[:provider]

        @runtime_manager.provide(:llm_client, default_routed[:provider])
      end

      # Phase 8: warm-up — AST indexing, built-in commands, ambient globals,
      # overlay loading, reactive config wiring.
      def warm_up!
        warm_async = @config.fetch("ast.async_warm", ENV["RUBIK_TEST"] != "1")
        warm_ast_graph(async: warm_async)
        register_default_commands
        Rubik.current_shell = self
        Rubik.runtime_manager = @runtime_manager
        @overlay_storage.load_all(self, @runtime_manager)
        @config_cleanups = ConfigWiring.wire(self)
        # Phase 5 built the tool registry; the skill tool's epoch (its
        # revertible registration + inverse) opens on the manager's own
        # sub-context only after config wiring so enable/disable knobs react.
        @skill_manager&.open_epoch!(@tool_registry)
        @mcp_manager&.load_from_config(@config)
        wire_subagent_events!
      end

      def wire_subagent_events!
        return unless @event_bus
        return if @subagent_event_tokens # idempotent re-wire (RenderService precedent)

        # Inverse-by-construction: subscribe only where the unsubscribe
        # inverse can be registered in the same breath (AGENTS.md §1A).
        ctx = @runtime_manager&.context
        return unless ctx.respond_to?(:on_dispose)

        @subagent_notices_mutex = Mutex.new
        @subagent_notices = []
        # Plan 109: the idle-turn wake flag, eagerly initialized BEFORE any
        # subscription exists so handlers never race its construction.
        @pending_notice_queue = PendingNoticeQueue.new
        tokens = Rubik::Orchestrator::Subagent::Notices::EVENTS.keys.map do |event|
          [event, @event_bus.subscribe(event) { |payload| handle_subagent_event(event, payload) }]
        end
        tokens << [:unit_state_changed, @event_bus.subscribe(:unit_state_changed) { |payload| handle_unit_event(payload) }]
        tokens << [:subagent_message_to_parent, @event_bus.subscribe(:subagent_message_to_parent) { |payload| handle_parent_message(payload) }]
        @subagent_event_tokens = tokens
        ctx.on_dispose do
          @subagent_event_tokens&.each { |(event, token)| @event_bus.unsubscribe(event, token) }
          @subagent_event_tokens = nil
        end
      end

      # ONE routing seam for subagent notices (Candidate 02, unified for
      # Plan 109): bus event -> normalized notice -> channel-split
      # delivery. Called on the kworker thread (bus dispatch is
      # synchronous): Queue pushes, the standby Mutex, and the guard
      # monitor only — no shell locks. Model channel (structured hash)
      # enters the active loop queue and is rendered to XML at drain
      # time; user channel (terminal line) is buffered to stdout while a
      # loop is active and flushed at turn end. Between turns the notice
      # is injected into @conversation_history, printed, and — when
      # wake-worthy — queued to owe agent-0 an autonomous notice turn.
      def handle_subagent_event(event_name, payload)
        return unless @running && @output && !@replaying

        notice = Rubik::Orchestrator::Subagent::Notices.normalize(event_name, payload)
        route_subagent_notice(notice) if notice
      end

      def handle_unit_event(payload)
        return unless @running && @output && !@replaying
        return unless payload.is_a?(Hash)

        type = payload[:type]&.to_sym
        return unless [:process, :task].include?(type)

        to_state = payload[:to_state]&.to_sym
        return unless [:completed, :failed].include?(to_state)

        route_subagent_notice({ kind: :task, id: payload[:unit_id], role: "Background Task", state: to_state.to_s, reason: payload[:reason] })
      end

      def handle_parent_message(payload)
        return unless @running && @output && !@replaying
        return unless payload.is_a?(Hash)

        route_subagent_notice({ kind: :message, id: payload[:sender_id] || "subagent",
                                role: "Subagent", state: "message", reason: payload[:message].to_s })
      end

      def route_subagent_notice(notice)
        line = Rubik::Orchestrator::Subagent::Notices.user_line(notice)
        if @active_loop
          @active_loop.enqueue_subagent_notice(notice) if @active_loop.respond_to?(:enqueue_subagent_notice)
          @subagent_notices_mutex&.synchronize { @subagent_notices << line }
        else
          inject_subagent_notice_into_conversation_history!(notice)
          if @terminal_guard
            @terminal_guard.print_safe_notice(line)
          else
            @output.puts "\n#{line}"
          end
          request_reactive_wakeup!(notice)
        end
      end

      # Plan 109 Faz B: the reactive wake composition — vocabulary policy
      # (WAKE_KINDS), kill-switch (subagents.reactive_wakeup config),
      # state (PendingNoticeQueue), mechanism (TerminalGuard#safe_wakeup!).
      # Every wake-worthy enqueue attempts the kick (no empty->non-empty
      # coalescing): a kick refused earlier (user typing / paste
      # collection) must retry on the next event, or the wake would wait
      # for a manual Enter. TerminalGuard re-verifies emptiness under its
      # monitor, so a typing user is never disturbed, and a surplus
      # injected Enter degrades to the :empty noop. Runs on the kworker
      # thread: queue push and the guard monitor only.
      def request_reactive_wakeup!(notice)
        return unless reactive_wakeup_enabled?
        return unless notice.is_a?(Hash) && WAKE_KINDS.include?(notice[:kind])

        pending_notice_queue.enqueue(notice)
        @terminal_guard&.safe_wakeup!
      end

      def reactive_wakeup_enabled?
        @config.respond_to?(:fetch) ? @config.fetch("subagents.reactive_wakeup", true) != false : true
      end

      # Eager init happens in wire_subagent_events! (before any
      # subscription exists); the lazy fallback keeps bare Lifecycle test
      # doubles working (SubagentNoticeInbox mold).
      def pending_notice_queue
        @pending_notice_queue ||= PendingNoticeQueue.new
      end

      def pending_wake_notices?
        pending_notice_queue.any?
      end

      def drain_pending_wake_notices!
        pending_notice_queue.drain_all
      end

      # Staleness rule: any real turn's context already includes the
      # idle-injected notices in @conversation_history — a surviving
      # pending wake would turn the next stray Enter into a redundant
      # notice turn.
      def clear_pending_wake_notices!
        pending_notice_queue.clear!
      end

      def inject_subagent_notice_into_conversation_history!(notice)
        xml_payload = Rubik::Orchestrator::Subagent::Notices.history_block([notice])
        @conversation_history ||= []
        if @conversation_history.last && (@conversation_history.last[:role] == "user" || @conversation_history.last["role"] == "user")
          key = @conversation_history.last.key?(:content) ? :content : "content"
          existing = @conversation_history.last[key].to_s
          @conversation_history.last[key] = existing.empty? ? xml_payload : "#{existing}\n\n#{xml_payload}"
        else
          @conversation_history << { role: "user", content: xml_payload }
        end
      end

      def flush_subagent_notices!
        return unless @output && @subagent_notices_mutex

        notices = @subagent_notices_mutex.synchronize do
          list = @subagent_notices.dup
          @subagent_notices.clear
          list
        end
        return if notices.empty?

        if @terminal_guard
          notices.each { |m| @terminal_guard.print_safe_notice(m) }
        else
          @output.puts ""
          notices.each { |m| @output.puts m }
        end
      end

      def reap_dead_kernel_units!
        init = @init || (@runtime_manager&.context&.get(:init) if @runtime_manager&.context.respond_to?(:get))
        init&.reap_dead_units!
      rescue StandardError => e
        debug_warn("reap_dead_kernel_units failed: #{e.class}: #{e.message}")
      end

      # Audit 1: ENV["RUBIK_DEBUG"]-gated logging for intentionally swallowed
      # exceptions (convention from config/store.rb). Never raises.
      #
      # $stderr.puts, not Kernel#warn: warn is silenced when $VERBOSE is nil
      # (bundler/rake -W0). Same ruling as Log.emit and Platform.debug_warn.
      def debug_warn(msg)
        $stderr.puts "[WARN] #{msg}" if ENV["RUBIK_DEBUG"] # rubocop:disable Style/StderrPuts
      rescue StandardError
        nil
      end
    end
  end
end
