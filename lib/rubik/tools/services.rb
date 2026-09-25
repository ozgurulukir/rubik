# frozen_string_literal: true

require_relative "../coeffects"
require_relative "../kernel/dmesg" unless defined?(Rubik::Kernel::Dmesg)

module Rubik
  module Tools
    # Lazy per-key resolution view for the tool layer (architecture-review
    # Candidate 05): ONE home for the house triple chain — explicit override
    # kwarg, then the runtime coeffect (Coeffects.get), then a fresh
    # standalone default. Collapses Registry.build_default's hand-written
    # effective_* locals into a tier table.
    #
    #   owns   : the resolution tiers per service and the fresh-default
    #            table — standalone construction policy: a zero-policy Guard
    #            and a guard-chained sandbox Runner keep toolbelt-only
    #            builds fail-closed (never wider policy than the caller gave)
    #   leaves : key STRINGS (Rubik::Coeffects SSOT); full-graph construction
    #            (REPL::ServiceCatalog — the fresh tier is deliberately the
    #            DEGENERATE construction, not Composition's); tool
    #            constructor signatures (tools layer)
    #
    # The coeffect tier exists exactly where wire_runtime_context publishes
    # the key (guard, context_index, adapter_registry, ast_graph,
    # task_manager, sandbox, subagent supervisor), so a shell-built registry
    # always resolves the session's own instances. ORDER is load-bearing:
    # sandbox_runner's fresh default chains onto the RESOLVED guard, so
    # :guard resolves first.
    class Services
      # Hash literal order IS resolution order: :guard resolves first because
      # sandbox_runner's fresh default chains onto the RESOLVED guard. ORDER
      # derives from the keys so the reader methods and the validation
      # message can never drift from the table.
      COEFFECTS = {
        guard: Rubik::Coeffects::GUARD,
        context_index: Rubik::Coeffects::CONTEXT_INDEX,
        adapter_registry: Rubik::Coeffects::ADAPTER_REGISTRY,
        ast_graph: Rubik::Coeffects::AST_GRAPH,
        task_manager: Rubik::Coeffects::TASK_MANAGER,
        sandbox_runner: Rubik::Coeffects::SANDBOX_RUNNER,
        subagent_supervisor: Rubik::Coeffects::SUBAGENT_SUPERVISOR,
        dmesg: Rubik::Coeffects::DMESG
      }.freeze

      ORDER = COEFFECTS.keys.freeze

      FRESH = {
        guard: ->(_s) { Rubik::Security::Guard.new },
        context_index: ->(s) { Rubik::Context::Index.new(root_dir: s.root_dir, native: s.native_switch&.fetch("tools.native")) },
        adapter_registry: ->(_s) { Rubik::Adapter::Registry.new },
        ast_graph: ->(_s) { Rubik::AST::Graph.new },
        sandbox_runner: ->(s) { Rubik::Sandbox::Runner.new(root_dir: s.root_dir, guard: s.resolved_guard) },
        dmesg: ->(_s) { Rubik::Kernel::Dmesg.new }
      }.freeze

      attr_reader :root_dir, :native_switch

      def initialize(ctx: nil, overrides: {}, root_dir: Dir.pwd, native_switch: nil)
        unknown = overrides.keys - ORDER
        raise ArgumentError, "unknown service override(s) #{unknown.inspect}; valid slots: #{ORDER.inspect}" unless unknown.empty?

        @ctx = ctx
        @overrides = overrides
        @root_dir = root_dir
        @native_switch = native_switch
        @resolved = {}
      end

      ORDER.each do |slot|
        define_method(slot) { resolve(slot) }
      end

      # The guard the sandbox fresh default chains onto (resolved first by
      # ORDER). Public for the FRESH lambdas and for the tier tests.
      def resolved_guard
        resolve(:guard)
      end

      private

      # The triple chain, memoized per slot: explicit override, then the
      # runtime coeffect (canonical key first, legacy alias second via
      # Coeffects.get), then the fresh standalone default. Slots without a
      # tier (task_manager, subagent_supervisor) resolve to nil when neither
      # the override nor the context supplies one — matching the registry's
      # pre-catalog behavior.
      def resolve(name)
        return @resolved[name] if @resolved.key?(name)

        @resolved[name] = @overrides[name] ||
                          (@ctx && Rubik::Coeffects.get(@ctx, COEFFECTS.fetch(name))) ||
                          FRESH[name]&.call(self)
      end
    end
  end
end
