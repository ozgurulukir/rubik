# frozen_string_literal: true

require_relative "../event_bus" unless defined?(Rubik::EventBus)
require_relative "../orchestrator/subagent/supervisor"

module Rubik
  module REPL
    # Plan 63 Faz B: pure construction layer extracted from Shell#initialize.
    # Composition.build materializes every subsystem the Shell coordinates
    # (buffer, snapshot, AST cache/graph, context index, session recorder,
    # adapter/LLM registries, router, runtime manager, overlay storage, LSP,
    # security guard, sandbox) in the exact historical construction order.
    # The Shell stays the coordinator: runtime coeffect provides, service
    # registrations, tool-registry wiring and UI/route warm-up remain there
    # because they depend on the shell identity itself. Every part stays
    # injectable for tests through the Shell's optional parts: kwarg.
    module Composition
      # Built subsystems plus the derived workspace wiring inputs the Shell
      # needs when a pre-built buffer_manager is injected from outside.
      Parts = Struct.new(
        :config, :event_bus, :buffer_manager, :snapshot_store, :cache_store, :ast_graph,
        :context_index, :recorder, :adapter_registry, :llm_registry, :router,
        :runtime_manager, :overlay_storage, :lsp_manager, :mcp_manager, :skill_manager, :guard, :sandbox_runner,
        :extra_roots, :allowed_ext_dirs, :allow_ext_writes, :plugin_manager, :plugin_storage, :task_manager,
        :subagent_supervisor,
        keyword_init: true
      )

      def self.build(config:, root_dir: nil, event_bus: nil, buffer_manager: nil, snapshot_store: nil)
        effective_root = File.expand_path(root_dir || buffer_manager&.root_dir || config&.root_dir || Dir.pwd)
        config ||= Rubik::Config.new(root_dir: effective_root)
        event_bus ||= Rubik::EventBus.new
        config.event_bus = event_bus if config.respond_to?(:event_bus=)

        extra_roots = Array(config.fetch("workspace.additional_roots", [])).compact
        allowed_ext_dirs = Array(config.fetch("workspace.allowed_external_dirs", [])).compact
        allow_ext_writes = config.fetch("workspace.allow_external_writes", false) || false
        auto_index_ext = config.fetch("workspace.auto_index_additional", true)

        buffer_manager ||= Rubik::Buffer::Manager.new(
          root_dir: effective_root, additional_roots: extra_roots,
          allowed_external_dirs: allowed_ext_dirs, allow_external_writes: allow_ext_writes,
          event_bus: event_bus, config: config
        )

        # instance_variable_get (not the home_dir reader) is kept verbatim from
        # Shell#initialize: it tolerates duck-typed configs without the reader.
        effective_home = config&.instance_variable_get(:@home_dir) || ENV.fetch("HOME", nil)
        snapshot_store ||= Rubik::Buffer::SnapshotStore.new(storage_dir: File.join(effective_home, ".rubik", "snapshots",
                                                                                   File.basename(effective_root)))
        cache_store = Rubik::AST::CacheStore.new(root_dir: effective_root, home_dir: effective_home)
        ast_graph = Rubik::AST::Graph.new
        native_switch = config&.fetch("tools.native")
        context_includes = Array(config&.fetch("context.include", [])).compact
        context_excludes = Array(config&.fetch("context.exclude", [])).compact
        context_index = Rubik::Context::Index.new(
          root_dir: effective_root,
          additional_roots: (auto_index_ext ? extra_roots : []),
          includes: context_includes,
          excludes: context_excludes,
          native: native_switch
        )
        recorder = Rubik::Session::Recorder.new(root_dir: effective_root, home_dir: effective_home)
        adapter_registry = Rubik::Adapter::Registry.new
        llm_registry = Rubik::LLM::Registry.new(config)
        router = Rubik::LLM::Router.new(config: config, registry: llm_registry)
        runtime_manager = Rubik::Runtime::Manager.new
        overlay_storage = Rubik::Runtime::OverlayStorage.new(root_dir: effective_root, home_dir: effective_home)
        lsp_manager = Rubik::LSP::Manager.new(config: config, root_dir: effective_root)
        mcp_manager = Rubik::MCP::Manager.new(config: config, root_dir: effective_root, runtime_manager: runtime_manager)
        skill_manager = Rubik::Skills::Manager.new(config: config, root_dir: effective_root, home_dir: effective_home,
                                                   runtime_context: runtime_manager.context)
        audit_log = config&.fetch("security.audit_log_path", nil) || File.join(Rubik::Platform.home_dir, ".rubik", "audit.log")
        guard = Rubik::Security::Guard.new(
          audit_log_path: audit_log,
          command_allowlist: Array(config&.fetch("security.command_allowlist", [])),
          # Stringy "false" from persisted config must disable probes too.
          allow_safe_probes: config&.fetch("security.allow_safe_probes", true).to_s.downcase != "false"
        )
        sandbox_runner = Rubik::Sandbox::Runner.new(root_dir: effective_root, config: config, allowed_external_dirs: allowed_ext_dirs)
        plugin_manager = Rubik::Plugin::Manager.new
        plugin_storage = defined?(Rubik::Plugin::Storage) ? Rubik::Plugin::Storage.new(root_dir: effective_root, home_dir: effective_home) : nil
        task_manager = Rubik::Runtime::TaskManager.new(guard: guard, context: runtime_manager.context, root_dir: effective_root)
        subagent_supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(
          root_context: runtime_manager.context,
          buffer_manager: buffer_manager,
          tool_registry: nil,
          provider: nil,
          config: config,
          root_dir: effective_root
        )

        Parts.new(
          config: config, event_bus: event_bus, buffer_manager: buffer_manager, snapshot_store: snapshot_store,
          cache_store: cache_store, ast_graph: ast_graph, context_index: context_index, recorder: recorder,
          adapter_registry: adapter_registry, llm_registry: llm_registry, router: router,
          runtime_manager: runtime_manager, overlay_storage: overlay_storage, lsp_manager: lsp_manager,
          mcp_manager: mcp_manager, skill_manager: skill_manager, guard: guard, sandbox_runner: sandbox_runner,
          extra_roots: extra_roots, allowed_ext_dirs: allowed_ext_dirs, allow_ext_writes: allow_ext_writes,
          plugin_manager: plugin_manager, plugin_storage: plugin_storage, task_manager: task_manager,
          subagent_supervisor: subagent_supervisor
        )
      end
    end
  end
end
