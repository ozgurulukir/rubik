# frozen_string_literal: true

require_relative "../log"
require_relative "../orchestrator/subagent/notices"
require_relative "../prompt/conversation_rows"
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
      WAKE_KINDS = [:completed, :budget_exhausted, :error_paused, :message, :question, :task].freeze
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
        # Vakanüvis kronikçisi storage'dan HEMEN SONRA bağlanır (STORE
        # coeffect'i çözülebilir olmalı); kendi child ctx'inde yaşar,
        # subagents.vakanuvis.enabled=false ile tümüyle kurulmaz.
        Rubik::Storage::Vakanuvis::Service.bind(@runtime_manager, config: @config, event_bus: @event_bus)
        # Pruner (KÖK pencere budayıcısı, DEFAULT ON —
        # subagents.pruner.enabled; opt-out: false): SHELL/SUPERVISOR/DMESG
        # coeffect'leri Faz 2'den gelir; kendi child ctx'inde yaşar,
        # prune_context aracı REQUIRES üzerinden reaktif açılır.
        Rubik::REPL::Pruner::Service.bind(@runtime_manager, config: @config, event_bus: @event_bus)
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
        # nil = unset: Platform.async_knob falls back to the env-aware
        # default (RUBIK_TEST=1 warms synchronously-off) so the schema entry
        # never forces async warm in tests.
        warm_async = Platform.async_knob(@config, "ast.async_warm")
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
        # mcp.async_load nil = env-aware (RUBIK_TEST=1 boots synchronously),
        # resolved by the same Platform.async_knob home as ast.async_warm:
        mcp_async = Platform.async_knob(@config, "mcp.async_load")
        wire_mcp_boot_notices!(async: mcp_async)
        @mcp_manager&.load_from_config(@config, async: mcp_async)
        wire_subagent_events!
      end

      # Async MCP boot progress notices (mcp-async-boot D8): subscribe BEFORE
      # the boot triggers so no event is missed, with the unsubscribe inverse
      # registered in the same breath (wire_subagent_events! pattern). Async
      # mode only — a synchronous boot finishes before the first prompt, so
      # its failures already surfaced on stderr.
      def wire_mcp_boot_notices!(async:)
        return unless async && @event_bus
        return if @mcp_notice_tokens # idempotent re-wire

        ctx = @runtime_manager&.context
        return unless ctx.respond_to?(:on_dispose)

        @mcp_notice_tokens = [
          [:mcp_server_loaded, @event_bus.subscribe(:mcp_server_loaded) { |payload| print_mcp_boot_notice(:loaded, payload) }],
          [:mcp_server_failed, @event_bus.subscribe(:mcp_server_failed) { |payload| print_mcp_boot_notice(:failed, payload) }]
        ]
        ctx.on_dispose do
          @mcp_notice_tokens&.each { |(event, token)| @event_bus.unsubscribe(event, token) }
          @mcp_notice_tokens = nil
        end
      end

      # Same kworker-thread contract as handle_subagent_event: no shell locks,
      # drop silently when the UI is not up yet (an instant boot failure is
      # still on stderr and in dmesg). Pure display line — never enters the
      # conversation history and never wakes an idle turn.
      def print_mcp_boot_notice(state, payload)
        return unless @running && @output
        return unless payload.is_a?(Hash)

        name = payload[:server]
        line = if state == :loaded
                 "mcp: server '#{name}' ready (#{payload[:tools] || 0} tools)"
               else
                 "mcp: server '#{name}' failed (#{payload[:error]})"
               end
        @terminal_guard&.print_safe_notice(line)
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
          # Wakeloop fix 2026-10-09: an event landing inside an AUTONOMOUS
          # turn's idle-path windows (before @active_loop is set, or in the
          # ensure tail after it is cleared) must not arm a follow-up wake —
          # that is the probabilistic residue of the chained-auto-turn bug.
          # History injection and the printed line above still happen (no
          # loss); only the synthetic Enter is withheld. A fresh event at a
          # genuinely idle prompt (@autonomous_turn false) wakes as designed.
          request_reactive_wakeup!(notice) unless @autonomous_turn
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
        Rubik::Prompt::ConversationRows.append_notice!(@conversation_history, xml_payload)
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

      # Session review B3 (turn-loss fix): Loop's drain runs at the TOP of each
      # step, so notices landing during the final step stranded in the loop
      # inbox at turn end — the user channel flushed a line, but the model
      # channel never entered history and no wake was owed (Plan 109's
      # documented "late-notice asymmetry" accepted the loss; a live session
      # showed it costs a whole turn). Called from execute_free_text's ensure
      # AFTER @active_loop = nil: the notices are injected into
      # @conversation_history (visible to the next turn) and wake-worthy kinds
      # arm the reactive wake, exactly like the idle-path branch of
      # route_subagent_notice. Runs on the turn thread. Per-notice rescue is
      # the ensure block's own contract ("cleanup must never mask the
      # in-flight exception") — and a raising notice must not strand its
      # queue-mates that drain_all already popped.
      #
      # arm_wake: false keeps the model-channel delivery but does NOT fire a
      # synthetic Enter (wakeloop fix 2026-10-09): an INTERRUPTED turn and an
      # AUTONOMOUS notice turn settle instead of re-arming — otherwise every
      # stranded notice chains another auto-turn (the prompt never returns)
      # and the cycle survives Ctrl+C.
      def deliver_stranded_loop_notices!(loop_instance, arm_wake: true)
        return unless loop_instance.respond_to?(:subagent_notice_inbox)

        loop_instance.subagent_notice_inbox.drain_all.each do |notice|
          inject_subagent_notice_into_conversation_history!(notice)
          request_reactive_wakeup!(notice) if arm_wake
        rescue StandardError => e
          # Load-bearing visibility (wakeloop fix 2026-10-09): this delivery
          # is the fix's "no loss" guarantee, so a dropped notice may not
          # vanish behind the ENV-gated debug_warn. Unconditional, non-raising.
          Rubik::Log.warn(:repl, "stranded notice delivery failed (#{notice[:kind].inspect}): " \
                                 "#{e.class}: #{e.message}")
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
