# frozen_string_literal: true

require_relative "context"

module Rubik
  module Runtime
    # = Rubik::Runtime::ComponentFiber
    #
    # Component Lifecycle Unit for Spatiotemporal Composability (AGENTS.md §2).
    #
    # == Architecture & State Machine:
    # A ComponentFiber represents the running instance of a pluggable runtime component.
    # It strictly follows the Fiber Lifecycle State Machine defined in AGENTS.md:
    #
    #   [Registered] -> PENDING <-------------------------+
    #                      |                              |
    #                      | Coeffects Satisfied          | Coeffects Lost /
    #                      v                              | Unload Requested
    #                    ACTIVE --------------------------+
    #                      |
    #                      | Error during Activation
    #                      v
    #                    FAILED -> (Partial Inverses / Rollback) -> DISPOSED
    #
    # == Distinction from Ruby's ::Fiber:
    # Rubik::Runtime::ComponentFiber is NOT a Ruby standard library coroutine (::Fiber) or
    # lightweight cooperative thread. Instead, it is an architectural lifecycle fiber
    # that encapsulates a component's coeffect dependencies (:inject), scoped sub-context
    # (@sub_context = context.extend), and LIFO effect inverses (Omega accumulator)
    # ensuring zero-restart reloading and atomic rollback.
    #
    # == Concurrency Contract (review 2026-09-17, Finding 2):
    # ComponentFiber is intentionally lock-free: correctness relies on external
    # serialization, NOT on internal locking. State mutations (@state,
    # @sub_context, @instance) and the multi-step activate!/deactivate! sequences
    # MUST happen under the owning Manager's Monitor (via register_component /
    # provide / reconcile_all / swap_component) or in single-threaded code.
    #
    # Why no blanket per-fiber Mutex: the factory passed to activate! runs while
    # the caller holds the Manager's Monitor, and factories may call back into
    # the Manager (Monitor is reentrant). A fiber-local mutex would create a
    # lock-order inversion (fiber lock -> Manager Monitor vs Manager Monitor ->
    # fiber lock) and deadlock. The Manager's reentrant Monitor is the single
    # serialization point; this class deliberately stays lock-free.
    class ComponentFiber
      STATES = [:unloaded, :pending, :active, :failed, :disposed].freeze

      attr_reader :name, :inject, :requires, :provides, :config, :state, :last_error, :sub_context, :instance

      def initialize(name:, inject: [], requires: [], provides: [], config: {}, &factory)
        @name = name.to_s
        @inject = Array(inject).map(&:to_s).map(&:downcase)
        @requires = Array(requires).map(&:to_s).map(&:downcase)
        @provides = ([@name.downcase] + Array(provides).map(&:to_s).map(&:downcase)).uniq
        @config = config || {}
        @factory = factory
        @state = :pending
        @last_error = nil
        @sub_context = nil
        @instance = nil
      end

      def satisfiable?(context)
        @inject.all? { |dep| context.has?(dep) }
      end

      # A fiber is ready to activate when its inject dependencies are satisfied
      # AND all its requires: coeffect prerequisites are also present in the context.
      # `requires:` is a pre-activation gate (Plan 86 D-3): the fiber stays Pending
      # until every declared requirement is available, preventing partial activation.
      def ready_to_activate?(context)
        satisfiable?(context) && @requires.all? { |dep| context.has?(dep) }
      end

      def activate!(context)
        return true if @state == :active
        return false unless ready_to_activate?(context)

        # Scoped sub-context for fiber lifecycle
        @sub_context = context.extend

        begin
          @instance = if @factory
                        @factory.call(@sub_context, @config)
                      else
                        build_instance(@sub_context, @config)
                      end
          @state = :active
          @last_error = nil
          true
        rescue StandardError => e
          # Atomic Rollback on Error: unwind partial inverses immediately
          @sub_context&.dispose
          @sub_context = nil
          @instance = nil
          @state = :failed
          @last_error = e
          false
        end
      end

      def deactivate!
        return false unless @state == :active

        if @sub_context
          @sub_context.dispose
          @sub_context = nil
        end
        @instance = nil
        @state = :pending
        true
      end

      def reactivate!(context)
        deactivate! if @state == :active
        activate!(context)
      end

      def mark_failed!(error = nil)
        deactivate! if @state == :active
        @state = :failed
        @last_error = error || StandardError.new("Fiber '#{@name}' marked failed")
      end

      def dispose!
        deactivate! if @state == :active
        @state = :disposed
      end

      def build_instance(_sub_context, _config)
        nil
      end
    end

    # Backwards-compatibility alias (AGENTS.md terminology). Kept for external
    # consumers and pin test `test_component_fiber_naming_and_alias_compatibility`;
    # internal code must use ComponentFiber directly — a bare `Fiber` inside
    # Rubik::Runtime shadows ::Fiber and corrupts grep/grep-ability (review
    # Finding 6). Enforced by test_no_bare_fiber_alias_use_in_lib.
    Fiber = ComponentFiber
  end
end
