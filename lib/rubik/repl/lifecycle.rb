# frozen_string_literal: true

module Rubik
  module REPL
    # Plan 63 Faz C: phased initialization collaborators extracted from Shell
    # (keeps shell.rb under the decoupling line-count gate). The Shell remains
    # the coordinator: these methods depend on shell identity, so they live in
    # an included module rather than in Composition (the pure builder).
    module Lifecycle
      # Phase 1: assign built subsystems. Injected-buffer post-wiring (extra
      # roots, allowed dirs, ext-write flag) runs only on the buffer_manager
      # kwarg route, where Composition did not own the manager's config.
      def inject_parts(parts, injected_buffer: false)
        @config = parts.config
        @event_bus = parts.event_bus
        @buffer_manager = parts.buffer_manager
        if injected_buffer
          (parts.extra_roots || []).each { |r| @buffer_manager.add_root(r) }
          (parts.allowed_ext_dirs || []).each { |d| @buffer_manager.add_allowed_dir(d) if @buffer_manager.respond_to?(:add_allowed_dir) }
          @buffer_manager.allow_external_writes = parts.allow_ext_writes if @buffer_manager.respond_to?(:allow_external_writes=)
        end
        @snapshot_store = parts.snapshot_store
        @cache_store = parts.cache_store
        @ast_graph = parts.ast_graph
        @context_index = parts.context_index
        # Sync load: cache is small (no bodies), symbols instantly available;
        # the expensive walk/extract stays in the background warm-up phase.
        @ast_graph.load_from_cache(@cache_store)
        @recorder = parts.recorder
        @adapter_registry = parts.adapter_registry
        @llm_registry = parts.llm_registry
        @router = parts.router
        @runtime_manager = parts.runtime_manager
        @overlay_storage = parts.overlay_storage
        @lsp_manager = parts.lsp_manager
        @mcp_manager = parts.respond_to?(:mcp_manager) ? parts.mcp_manager : nil
        @skill_manager = parts.respond_to?(:skill_manager) ? parts.skill_manager : nil
        @guard = parts.guard
        @sandbox_runner = parts.sandbox_runner
        @plugin_manager = parts.plugin_manager
        @task_manager = parts.respond_to?(:task_manager) ? parts.task_manager : nil
        @subagent_supervisor = parts.respond_to?(:subagent_supervisor) ? parts.subagent_supervisor : nil
      end

      # Phase 2: provide the core subsystems into the Runtime Coeffect Context.
      # Canonical (long-form) keys only — short forms ("buffer", "lsp", ...)
      # remain readable via Rubik::Coeffects LEGACY_ALIASES for third parties.
      def wire_runtime_context(parts)
        {
          buffer_manager: @buffer_manager, snapshot_store: @snapshot_store,
          lsp_manager: @lsp_manager, mcp_manager: @mcp_manager,
          skill_manager: @skill_manager,
          guard: @guard, sandbox: @sandbox_runner,
          adapter_registry: @adapter_registry, events: @event_bus, config: @config,
          # SHELL coeffect (Rubik::Coeffects::SHELL) — sanctioned access path; ambient Rubik.current_shell is deprecated (sunset)
          shell: self,
          plugin_manager: @plugin_manager, plugin_storage: (parts.plugin_storage if parts.respond_to?(:plugin_storage)),
          task_manager: @task_manager,
          subagent_supervisor: @subagent_supervisor,
          router: @router
        }.each { |k, v| @runtime_manager.provide(k, v) }
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
      end

      # Audit 1: ENV["RUBIK_DEBUG"]-gated logging for intentionally swallowed
      # exceptions (convention from config/store.rb). Never raises.
      def debug_warn(msg)
        warn "[WARN] #{msg}" if ENV["RUBIK_DEBUG"]
      rescue StandardError
        nil
      end
    end
  end
end
