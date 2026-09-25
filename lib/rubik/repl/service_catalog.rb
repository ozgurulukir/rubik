# frozen_string_literal: true

require_relative "../coeffects"
require_relative "../event_bus" unless defined?(Rubik::EventBus)
require_relative "../orchestrator/subagent/supervisor"
require_relative "../runtime/service_definition"

module Rubik
  module REPL
    # The ONE ordered, declarative catalog of everything Composition builds
    # and the Shell publishes (architecture-review Candidate 05). Entry order
    # IS construction order — the historical Shell#initialize sequence, which
    # is load-bearing: the shared guard is built BEFORE every consumer
    # (buffer, mcp, sandbox runner, task manager) so they all share the same
    # instance; runtime_manager precedes task_manager / skills / mcp, which
    # wire into its context; buffer precedes the subagent supervisor.
    #
    #   owns   : the entries (builders, provide keys, optional/reader flags,
    #            inject hooks) and the load-time derivations — Parts struct
    #            members, shell reader names, the build fold, wire provide rows
    #   leaves : key STRINGS and legacy aliases (Rubik::Coeffects SSOT —
    #            entries reference the constants); shell-identity phases
    #            (register shims, tool registry, UI, LLM route — lifecycle.rb);
    #            override-kwarg resolution and root resolution (composition.rb);
    #            tool-layer fallback defaults (Tools::Services)
    #
    # Adding a runtime service = its file + barrel require + a Coeffects key
    # constant + ONE entry here. Parts members, the Shell ivar, the public
    # reader and the wire provide all derive from that entry at load time;
    # test_service_catalog.rb locks catalog <-> Parts <-> readers <->
    # provides <-> Coeffects consistency so the derivation cannot drift.
    module ServiceCatalog
      # The fold scope: root inputs, caller-supplied overrides, and hash
      # access to already-constructed entries. Service constants referenced
      # inside builders resolve lazily (at fold time), so catalog load order
      # carries no construction coupling.
      class Scope
        attr_reader :root_dir, :built

        def initialize(root_dir:, overrides:)
          @root_dir = root_dir
          @overrides = overrides
          @built = {}
        end

        def override_for(name)
          @overrides[name]
        end

        def store(name, instance)
          @built[name] = instance
        end

        # Forward-reference guard: a builder reaching for a service the fold
        # has not produced yet fails here, loudly, instead of silently
        # threading nil downstream. Overrides are visible immediately (an
        # injected part IS the value its entry will adopt).
        def [](name)
          return @built[name] if @built.key?(name)
          return @overrides[name] if @overrides.key?(name)

          raise KeyError, "ServiceCatalog: :#{name} is not constructed yet — ordered later in the catalog (or missing)"
        end

        # instance_variable_get (not the home_dir reader) is kept verbatim
        # from the pre-catalog Shell#initialize: it tolerates duck-typed
        # configs without the reader.
        def home_dir
          @home_dir ||= self[:config]&.instance_variable_get(:@home_dir) || ENV.fetch("HOME", nil)
        end
      end

      DEFINITION = Rubik::Runtime::ServiceDefinition

      ENTRIES = [
        DEFINITION.new(
          name: :config,
          builder: ->(s) { Rubik::Config.new(root_dir: s.root_dir) },
          provide: Rubik::Coeffects::CONFIG
        ),
        DEFINITION.new(
          name: :event_bus,
          builder: ->(_s) { Rubik::EventBus.new },
          provide: Rubik::Coeffects::EVENTS,
          after_build: ->(s) { s[:config].event_bus = s[:event_bus] if s[:config].respond_to?(:event_bus=) }
        ),
        DEFINITION.new(
          name: :extra_roots,
          input: true,
          builder: ->(s) { Array(s[:config].fetch("workspace.additional_roots", [])).compact }
        ),
        DEFINITION.new(
          name: :allowed_ext_dirs,
          input: true,
          builder: ->(s) { Array(s[:config].fetch("workspace.allowed_external_dirs", [])).compact }
        ),
        DEFINITION.new(
          name: :allow_ext_writes,
          input: true,
          builder: ->(s) { s[:config].fetch("workspace.allow_external_writes", false) || false }
        ),
        # The ONE operator-policy guard (security.*) — built BEFORE every
        # consumer below (buffer, mcp, sandbox runner, task manager) so they
        # all share this instance. Live in-place mutation from !allow-cmd /
        # !config (repl/config_wiring.rb) then reaches every verification
        # path in the same session without restarts.
        DEFINITION.new(
          name: :guard,
          builder: ->(s) { Rubik::Security::Guard.for_config(s[:config]) },
          provide: Rubik::Coeffects::GUARD
        ),
        DEFINITION.new(
          name: :buffer_manager,
          builder: lambda do |s|
            Rubik::Buffer::Manager.new(
              root_dir: s.root_dir, additional_roots: s[:extra_roots],
              allowed_external_dirs: s[:allowed_ext_dirs], allow_external_writes: s[:allow_ext_writes],
              event_bus: s[:event_bus], config: s[:config], guard: s[:guard]
            )
          end,
          provide: Rubik::Coeffects::BUFFER_MANAGER,
          after_inject: lambda do |values, parts, injected_buffer|
            next unless injected_buffer

            # Injected-buffer post-wiring runs only on the buffer_manager
            # kwarg route, where Composition did not own the manager's config.
            bm = values.fetch(:buffer_manager)
            (parts.extra_roots || []).each { |r| bm.add_root(r) }
            (parts.allowed_ext_dirs || []).each { |d| bm.add_allowed_dir(d) if bm.respond_to?(:add_allowed_dir) }
            bm.allow_external_writes = parts.allow_ext_writes if bm.respond_to?(:allow_external_writes=)
          end
        ),
        DEFINITION.new(
          name: :snapshot_store,
          builder: lambda do |s|
            Rubik::Buffer::SnapshotStore.new(storage_dir: File.join(s.home_dir, ".rubik", "snapshots",
                                                                    File.basename(s.root_dir)))
          end,
          provide: Rubik::Coeffects::SNAPSHOT_STORE
        ),
        DEFINITION.new(
          name: :cache_store,
          builder: ->(s) { Rubik::AST::CacheStore.new(root_dir: s.root_dir, home_dir: s.home_dir) }
        ),
        DEFINITION.new(
          name: :ast_graph,
          # Provided into the context later, by Runtime::ASTService (Shell
          # phase 4) — not by wire_runtime_context.
          builder: ->(_s) { Rubik::AST::Graph.new },
          # Sync load: cache is small (no bodies), symbols instantly
          # available; the expensive walk/extract stays in the background
          # warm-up phase.
          after_inject: lambda do |values, _parts, _injected|
            values.fetch(:ast_graph).load_from_cache(values.fetch(:cache_store))
          end
        ),
        # Provided into the context later, by Runtime::IndexService (Shell
        # phase 4) — not by wire_runtime_context.
        DEFINITION.new(
          name: :context_index,
          builder: lambda do |s|
            includes = Array(s[:config]&.fetch("context.include", [])).compact
            excludes = Array(s[:config]&.fetch("context.exclude", [])).compact
            Rubik::Context::Index.new(
              root_dir: s.root_dir,
              additional_roots: (s[:config].fetch("workspace.auto_index_additional", true) ? s[:extra_roots] : []),
              includes: includes,
              excludes: excludes,
              native: s[:config]&.fetch("tools.native")
            )
          end
        ),
        DEFINITION.new(
          name: :recorder,
          builder: ->(s) { Rubik::Session::Recorder.new(root_dir: s.root_dir, home_dir: s.home_dir) }
        ),
        DEFINITION.new(
          name: :adapter_registry,
          builder: ->(_s) { Rubik::Adapter::Registry.new },
          provide: Rubik::Coeffects::ADAPTER_REGISTRY
        ),
        DEFINITION.new(
          name: :llm_registry,
          builder: ->(s) { Rubik::LLM::Registry.new(s[:config]) }
        ),
        DEFINITION.new(
          name: :router,
          builder: ->(s) { Rubik::LLM::Router.new(config: s[:config], registry: s[:llm_registry]) },
          provide: Rubik::Coeffects::ROUTER
        ),
        # The context owner every later entry wires into; provided to tools
        # by constructor injection, never as a coeffect.
        DEFINITION.new(
          name: :runtime_manager,
          builder: ->(_s) { Rubik::Runtime::Manager.new }
        ),
        DEFINITION.new(
          name: :overlay_storage,
          builder: ->(s) { Rubik::Runtime::OverlayStorage.new(root_dir: s.root_dir, home_dir: s.home_dir) }
        ),
        DEFINITION.new(
          name: :lsp_manager,
          builder: ->(s) { Rubik::LSP::Manager.new(config: s[:config], root_dir: s.root_dir) },
          provide: Rubik::Coeffects::LSP_MANAGER,
          optional: true
        ),
        DEFINITION.new(
          name: :mcp_manager,
          builder: lambda do |s|
            Rubik::MCP::Manager.new(config: s[:config], root_dir: s.root_dir,
                                    runtime_manager: s[:runtime_manager], guard: s[:guard])
          end,
          provide: Rubik::Coeffects::MCP_MANAGER,
          optional: true
        ),
        DEFINITION.new(
          name: :skill_manager,
          builder: lambda do |s|
            Rubik::Skills::Manager.new(config: s[:config], root_dir: s.root_dir, home_dir: s.home_dir,
                                       runtime_context: s[:runtime_manager].context)
          end,
          provide: Rubik::Coeffects::SKILL_MANAGER,
          optional: true
        ),
        # Provide key deliberately differs from the member name: third
        # parties resolve "sandbox" (ctx.require / Coeffects bridge).
        DEFINITION.new(
          name: :sandbox_runner,
          builder: lambda do |s|
            Rubik::Sandbox::Runner.new(root_dir: s.root_dir, config: s[:config],
                                       allowed_external_dirs: s[:allowed_ext_dirs], guard: s[:guard])
          end,
          provide: Rubik::Coeffects::SANDBOX_RUNNER
        ),
        DEFINITION.new(
          name: :plugin_manager,
          builder: ->(_s) { Rubik::Plugin::Manager.new },
          provide: Rubik::Coeffects::PLUGIN_MANAGER,
          reader: false
        ),
        DEFINITION.new(
          name: :plugin_storage,
          builder: lambda do |s|
            defined?(Rubik::Plugin::Storage) ? Rubik::Plugin::Storage.new(root_dir: s.root_dir, home_dir: s.home_dir) : nil
          end,
          provide: Rubik::Coeffects::PLUGIN_STORAGE,
          provide_from: :parts,
          assign_ivar: false
        ),
        DEFINITION.new(
          name: :task_manager,
          builder: lambda do |s|
            Rubik::Runtime::TaskManager.new(guard: s[:guard], context: s[:runtime_manager].context, root_dir: s.root_dir)
          end,
          provide: Rubik::Coeffects::TASK_MANAGER,
          optional: true
        ),
        DEFINITION.new(
          name: :subagent_supervisor,
          builder: lambda do |s|
            Rubik::Orchestrator::Subagent::Supervisor.new(
              root_context: s[:runtime_manager].context,
              buffer_manager: s[:buffer_manager],
              tool_registry: nil,
              provider: nil,
              router: s[:router],
              config: s[:config],
              root_dir: s.root_dir,
              event_bus: s[:event_bus]
            )
          end,
          provide: Rubik::Coeffects::SUBAGENT_SUPERVISOR,
          optional: true
        ),
        DEFINITION.new(
          name: :dmesg,
          builder: ->(_s) { Rubik::Kernel::Dmesg.new },
          provide: Rubik::Coeffects::DMESG
        ),
        # The shell identity itself — provided at wire time, never built.
        DEFINITION.new(
          name: :shell,
          parts_member: false,
          builder: nil,
          provide: Rubik::Coeffects::SHELL,
          provide_from: :self
        )
      ].each(&:freeze).freeze

      class << self
        def member_names
          ENTRIES.reject { |e| e.parts_member == false }.map(&:name)
        end

        def parts_struct
          Struct.new(*member_names, keyword_init: true)
        end

        def injectable
          ENTRIES.select(&:injectable?)
        end

        def reader_names
          ENTRIES.select(&:expose_reader?).map(&:name)
        end

        def provided
          ENTRIES.select(&:provided?)
        end

        # The construction fold. Caller-supplied overrides (config, event_bus,
        # buffer_manager, snapshot_store kwargs) adopt their entry verbatim;
        # everything else runs its builder with the scope. after_build hooks
        # run per-entry (the config.event_bus cross-wire).
        def build(scope)
          ENTRIES.each do |entry|
            next if entry.parts_member == false

            scope.store(entry.name, scope.override_for(entry.name) || entry.builder&.call(scope))
            entry.after_build&.call(scope)
          end
          scope.built
        end

        # Wire provide rows, in catalog order. Order is inert at wire time:
        # the runtime manager holds zero registered fibers until phase 4
        # (register_runtime_services) and phase 3 (load_plugins) run — every
        # reconcile_all inside Manager#provide iterates an empty fiber map.
        def wire_rows(shell, parts)
          provided.to_h do |entry|
            [entry.provide, case entry.provide_from
                            when :ivar  then shell.instance_variable_get(:"@#{entry.name}")
                            when :parts then parts.respond_to?(entry.name) ? parts[entry.name] : nil
                            when :self  then shell
                            end]
          end
        end
      end
    end
  end
end
