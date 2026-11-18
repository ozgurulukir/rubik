# frozen_string_literal: true

require_relative "../events"
require_relative "../log"
require_relative "../platform"
require_relative "../storage/layout"
require_relative "../ui/capability"
require_relative "../connect"
require_relative "../orchestrator/subagent/notices"
require_relative "../prompt/conversation_rows"
require_relative "pending_notice_queue"
require_relative "notice_router"

module Rubik
  module REPL
    # Plan 63 Faz C: phased initialization collaborators extracted from Shell
    # (keeps shell.rb under the decoupling line-count gate). The Shell remains
    # the coordinator: these methods depend on shell identity, so they live in
    # an included module rather than in Composition (the pure builder).
    #
    # Issue #469: the notice-routing half (MCP boot notices, subagent event
    # routing, reactive wakeup state) now lives in NoticeRouter; the methods
    # below delegate to a lazily-created router so the public Shell surface
    # (and the bare-Lifecycle test-double harnesses) stay unchanged. The
    # router owns the queue/mutex/token concurrency state.
    module Lifecycle
      # Plan 109 Faz B: notice kinds worth interrupting the idle prompt —
      # vocabulary now owned by NoticeRouter; re-exported here because
      # callers (and silence-contract tests) pin Rubik::REPL::Lifecycle::
      # WAKE_KINDS.
      WAKE_KINDS = NoticeRouter::WAKE_KINDS

      # The notice-routing collaborator (issue #469): lazily created so bare
      # Lifecycle test doubles (which set plain ivars, no constructor) keep
      # working; the router reads host state live via instance_variable_get.
      def notice_router
        @notice_router ||= NoticeRouter.new(self)
      end

      # Plan 1, Phase 1: assign built subsystems. Entries derive from the
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

        Array(Rubik::Storage::Layout.config_get(@config, "plugins.load", [])).each { |g| @plugin_manager.load_plugin_gem(g, runtime_manager: @runtime_manager) }
        if Rubik::Storage::Layout.config_get(@config, "plugins.autoload_dropin", true) && parts.respond_to?(:plugin_storage) && parts.plugin_storage
          @plugin_manager.load_dropin_plugins(runtime_manager: @runtime_manager, storage: parts.plugin_storage)
        end
        aliases_cfg = Rubik::Storage::Layout.config_get(@config, "plugins.aliases", {})
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

      # First-run onboarding: after the banner shows "model yapılandırılmamış",
      # offer the connect wizard once when boot could not resolve an LLM
      # client. Opt-in ask (default no — Confirmations#ask_yes_no collapses
      # to the default off live TTYs, so scripted boots are untouched),
      # knob-gated (connect.first_run_offer), once per process, never
      # raises — the same boot-path honesty as sync_default_llm_route.
      def maybe_offer_connect_wizard!
        return if @connect_offer_shown

        @connect_offer_shown = true
        return unless @config && @output && @input
        return unless respond_to?(:ask_yes_no)
        return unless Rubik::UI::Capability.interactive?(input: @input, output: @output)
        return unless Rubik::Storage::Layout.config_get(@config, "connect.first_run_offer", true)
        return unless llm_client_pending?

        answer = ask_yes_no("No LLM provider is configured yet. Run the connect wizard?", default: "n")
        return unless ["y", "yes", "evet"].include?(answer.to_s.downcase)

        ui = Rubik::Connect::PromptUI.new(input: @input,
                                          output: Rubik::UI::Capability.unwrap_tee(@output) || @output,
                                          theme: @ui_theme)
        Rubik::Connect::Wizard.new(config: @config, ui: ui, io: @output, scope: :global,
                                   refresh: -> { refresh_llm_registry! }).run
      rescue StandardError => e
        debug_warn("Connect wizard offer failed: #{e.class}: #{e.message}")
      end

      # True when boot's default route failed to satisfy the llm_client
      # coeffect — the honest "nothing usable is configured" signal, so a
      # locally-running Ollama user is never offered the wizard.
      def llm_client_pending?
        context = @runtime_manager&.context
        context.respond_to?(:get) ? context.get(:llm_client).nil? : false
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
        maybe_warn_huge_root!
        # Boot accumulated config problems (unknown keys, corrupt YAML, legacy
        # env vars) surface here — same notices seam, still before the banner.
        maybe_emit_config_warnings!
        # A strong huge-root signal skips the boot warm walk: the index
        # stays empty and tools answer the honest not-ready message until
        # an explicit '!context scan' opts in. Warning only — never a block.
        warm_ast_graph(async: warm_async) unless skip_huge_root_boot_scan?
        register_default_commands
        Rubik.current_shell = self
        Rubik.runtime_manager = @runtime_manager
        @overlay_storage.load_all(self, @runtime_manager)
        @config_cleanups = ConfigWiring.wire(self)
        if @runtime_manager&.context.respond_to?(:on_dispose)
          @runtime_manager.context.on_dispose do
            while (cleanup = @config_cleanups&.pop)
              begin
                cleanup.call
              rescue StandardError => e
                Rubik::Log.warn(:repl, "[WARN] Config cleanup failed: #{e.message}")
              end
            end
          end
        end
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

      # Huge-root guidance: classify the session root with cheap probes,
      # print ONE guidance notice per session, and (via skip_huge_root_boot_scan?)
      # gate the boot warm walk. Boot warns on STRONG signals only — a plain
      # gitless root stays silent so ordinary sessions and tests see no new
      # output; the weak gitless aggravator surfaces at the explicit
      # '!context scan' (strong_only: false). Memoized so the scan reuses
      # the assessment without a second git spawn.
      def maybe_warn_huge_root!(strong_only: true)
        return unless @config.nil? || Rubik::Storage::Layout.config_get(@config, "context.huge_root_notice", true)
        return if @huge_root_notice_shown

        assessment = huge_root_assessment
        return if strong_only && !assessment.strong

        guidance = Rubik::Context::RootHeuristics.guidance(assessment, boot_scan_skipped: huge_root_boot_scan_skipped?)
        return if guidance.empty?

        @huge_root_notice_shown = true
        NoticeRouter.print_safe_notice_line(@terminal_guard, @output, guidance)
      end

      def huge_root_assessment
        @huge_root_assessment ||= Rubik::Context::RootHeuristics.assess(
          @buffer_manager&.root_dir || @config&.root_dir || Dir.pwd,
          home_dir: @config.respond_to?(:home_dir) ? @config.home_dir : nil
        )
      end

      # Boot scans by default; only a STRONG signal (home dir, filesystem
      # root, OS-data dir) skips the walk, and the knob re-enables it.
      # Gitless roots are weak: guidance only, boot unaffected.
      def skip_huge_root_boot_scan?
        huge_root_boot_scan_skipped?
      end

      def huge_root_boot_scan_skipped?
        return false unless huge_root_assessment.strong

        !Rubik::Storage::Layout.config_get(@config, "context.boot_scan_on_huge_root", false)
      end

      # Boot-time config observability (issue #399): Config#warnings
      # accumulates unknown-key, corrupt-YAML, ~/.rubik and env-deprecation
      # problems during load with no reader; this surfaces them through the
      # notices seam right after the huge-root check, before the banner.
      # Once per REPL process boot — warnings appended later in the session
      # (runtime set()) stay in the array for !config/tests without printing.
      # Rubik::Log.warn mirrors each notice so headless/scripted boots see
      # them on stderr too.
      def maybe_emit_config_warnings!
        warnings = @config&.warnings
        return if warnings.nil? || warnings.empty?
        return if @config_warnings_shown

        @config_warnings_shown = true
        warnings.each do |w|
          line = "⚠ Config: #{w}"
          Rubik::Log.warn(:config, line)
          NoticeRouter.print_safe_notice_line(@terminal_guard, @output, line)
        end
      end

      # --- Notice routing (issue #469): thin delegation to NoticeRouter ----
      # The router owns the queue/mutex/token concurrency state; these
      # delegators keep the historical Shell surface (and the bare-Lifecycle
      # test-double harnesses that include this module) unchanged.

      # Async MCP boot progress notices (mcp-async-boot D8). See
      # NoticeRouter#wire_mcp_boot_notices!.
      def wire_mcp_boot_notices!(async:)
        notice_router.wire_mcp_boot_notices!(async: async)
      end

      def print_mcp_boot_notice(state, payload)
        notice_router.print_mcp_boot_notice(state, payload)
      end

      def wire_subagent_events!
        notice_router.wire_subagent_events!
      end

      def handle_subagent_event(event_name, payload)
        notice_router.handle_subagent_event(event_name, payload)
      end

      def handle_unit_event(payload)
        notice_router.handle_unit_event(payload)
      end

      def handle_parent_message(payload)
        notice_router.handle_parent_message(payload)
      end

      def route_subagent_notice(notice)
        notice_router.route_subagent_notice(notice)
      end

      def request_reactive_wakeup!(notice)
        notice_router.request_reactive_wakeup!(notice)
      end

      def reactive_wakeup_enabled?
        notice_router.reactive_wakeup_enabled?
      end

      def pending_notice_queue
        notice_router.pending_notice_queue
      end

      def pending_wake_notices?
        notice_router.pending_wake_notices?
      end

      def drain_pending_wake_notices!
        notice_router.drain_pending_wake_notices!
      end

      def clear_pending_wake_notices!
        notice_router.clear_pending_wake_notices!
      end

      def inject_subagent_notice_into_conversation_history!(notice)
        notice_router.inject_subagent_notice_into_conversation_history!(notice)
      end

      def flush_subagent_notices!
        notice_router.flush_subagent_notices!
      end

      def deliver_stranded_loop_notices!(loop_instance, arm_wake: true)
        notice_router.deliver_stranded_loop_notices!(loop_instance, arm_wake: arm_wake)
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
      # Delegates to Platform.debug_warn (issue #452): the platform channel is
      # the ONE home of RUBIK_DEBUG-gated debug warnings — Log.debug is gated
      # by RUBIK_LOG_LEVEL instead, so reusing the sanctioned platform sink
      # keeps this channel's exact semantics ([WARN] prefix, audible under
      # $VERBOSE=nil, silent unless RUBIK_DEBUG is set, error-isolated).
      def debug_warn(msg)
        Rubik::Platform.debug_warn(msg)
      end
    end
  end
end
