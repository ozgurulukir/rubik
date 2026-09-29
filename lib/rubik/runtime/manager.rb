# frozen_string_literal: true

require "monitor"
require_relative "context"
require_relative "fiber"
require_relative "fiber_ordering"
require_relative "fiber_retry_gate"

module Rubik
  module Runtime
    class Manager
      attr_reader :context, :retry_gate

      def initialize(context = nil)
        @context = context || Context.new
        @fibers = {}
        @monitor = Monitor.new
        # Fiber names with a factory currently in flight (reentrant reconcile
        # guard): a factory that re-provides its own dependency re-enters
        # reconcile_all on the same thread; without this marker the pending/
        # active branches would re-activate the fiber and recurse unbounded
        # (Monitor is reentrant, so the spiral ends in SystemStackError, not
        # a deadlock).
        @activating = {}
        # Failed-fiber retry budget/backoff (G4): the gate owns the
        # bookkeeping; the manager routes clear/attempt through it.
        @retry_gate = FiberRetryGate.new(@monitor, @context)
        # name -> Set of canonical coeffect keys this fiber's factory injects.
        # The reactive surface (provide/unprovide) consults this to decide which
        # fibers are gated on a coeffect that changed, so retracting a service
        # through the reactive path retracts (deactivates) every fiber gated on
        # it — matching provide's on-demand reactivation (AGENTS.md §5, Finding B).
        @fiber_deps = {}
        @disposed = false
      end

      # Retry-policy constants moved to FiberRetryGate (G4); aliases keep the
      # Manager-facing names (tests, warn-message text) stable.
      MAX_FIBER_RETRIES = FiberRetryGate::MAX_RETRIES
      RETRY_BACKOFF_BASE_S = FiberRetryGate::BACKOFF_BASE_S

      def fibers
        @monitor.synchronize { @fibers.dup }
      end

      def disposed?
        @monitor.synchronize { @disposed }
      end

      def register_component(name, inject: [], requires: [], provides: [], config: {}, &factory)
        name_str = name.to_s
        fiber = ComponentFiber.new(name: name_str, inject: inject, requires: requires, provides: provides, config: config, &factory)
        register_fiber(fiber)
      end

      # Reentrant lock safety: Monitor#synchronize is explicitly reentrant (recursive),
      # allowing register_fiber to store the fiber and activate it. The activation
      # is performed OUTSIDE the lock (via reconcile_fiber) so a failing fiber's
      # backoff sleep never serializes other threads (Finding 3).
      def register_fiber(fiber)
        deps = Array(fiber.inject).map { |n| n.to_s.downcase }
        @monitor.synchronize do
          raise ContextDisposedError, "Cannot register fiber on a disposed Manager" if @disposed

          @fiber_deps.delete(fiber.name) unless deps.empty?
          @fiber_deps[fiber.name] = deps.to_set unless deps.empty?
          @fibers[fiber.name] = fiber
          @retry_gate.clear(fiber.name) # explicit re-registration resets the retry budget
        end
        reconcile_fiber(fiber)
        fiber
      end

      def unregister_component(name)
        @monitor.synchronize do
          name_str = name.to_s
          fiber = @fibers.delete(name_str)
          @fiber_deps.delete(name_str)
          @retry_gate.clear(name_str) # fresh-eye R2: disposed fibers must not leak their retry budget
          fiber&.dispose!
        end
      end

      # Reactive retraction (AGENTS.md §5, Finding B): unlike Context#unprovide
      # (which removes a service from the coeffect registry without touching
      # dependents), retraction here routes through reconcile_all(changed_service:).
      # Any fiber whose factory injects this coeffect therefore transitions
      # Active->Pending and its partial inverse runs (LIFO via its sub-context),
      # instead of orphaning against a now-stale/coeffect-less context. Re-
      # providing the key afterwards is symmetric to provide: the fiber is
      # reactivated on-demand.
      def unprovide(service_name)
        key = service_name.to_s.downcase
        @monitor.synchronize { @context.unprovide(key) }
        reconcile_all(changed_service: key)
        nil # idempotent no-op returns nil (unprovide has no meaningful return)
      end

      # Reactive provide (AGENTS.md §5): adding a coeffect activates any pending
      # fiber gated on it, and reactivates an active fiber when the SAME service
      # object is re-provided (identity change), so its new instance is injected.
      # Both transitions run reconcile_all(changed_service:) OUTSIDE the monitor.
      def provide(service_name, service)
        @monitor.synchronize { @context.provide(service_name, service) }
        # reconcile_all runs OUTSIDE this lock so a failing fiber's backoff sleep
        # never serializes other threads (Finding 3).
        reconcile_all(changed_service: service_name)
      end

      # Reentrant lock safety: Monitor#synchronize is explicitly reentrant (recursive),
      # allowing swap_component to safely invoke unregister_component and register_component
      # from within the same thread without deadlocking.
      def swap_component(name, inject: [], requires: [], provides: [], config: {}, &new_factory)
        @monitor.synchronize do
          name_str = name.to_s
          unregister_component(name_str)
          register_component(name_str, inject: inject, requires: requires, provides: provides, config: config, &new_factory)
        end
      end

      def reconcile_all(changed_service: nil)
        fibers = @monitor.synchronize { @fibers.values.dup }
        sorted_fibers = topological_sort_fibers(fibers)
        sorted_fibers.each do |fiber|
          reconcile_fiber(fiber, changed_service: changed_service)
        end
      end

      def topological_sort_fibers(fibers)
        sorted, cycled = FiberOrdering.sort(fibers)
        handle_fiber_cycle(cycled) unless cycled.empty?
        sorted
      end

      def handle_fiber_cycle(cycle_fibers)
        names = cycle_fibers.map(&:name).join(", ")
        msg = "Dependency cycle detected among fibers: #{names}"
        Rubik::Log.warn(:runtime, msg)
        dmesg = begin
          @context.resolve(Rubik::Coeffects::DMESG)
        rescue StandardError
          nil
        end
        dmesg&.log(:runtime, :err, msg) if dmesg.respond_to?(:log)

        err = StandardError.new(msg)
        @monitor.synchronize do
          cycle_fibers.each { |cf| cf.mark_failed!(err) if cf.respond_to?(:mark_failed!) }
        end
      end

      def reconcile_fiber(fiber, changed_service: nil)
        # pending / active branches activate with the monitor held at depth 1
        # (the factory returns while we still hold it, so nested reconciles see
        # the newest value). The :failed branch defers activation until AFTER
        # the monitor is released so the backoff sleep serializes no one.
        deferred = nil
        @monitor.synchronize do
          # Reentrancy guard: skip fibers whose factory is currently running
          # (nested reconcile from a factory-side provide). The in-flight
          # factory already observes the newest value it provided, so the
          # outer activation converges; a skipped re-run would only recurse.
          return if @activating.key?(fiber.name)

          case fiber.state
          when :pending
            with_activation_marker(fiber) { fiber.activate!(@context) } if fiber.ready_to_activate?(@context)
          when :active
            if !fiber.ready_to_activate?(@context)
              fiber.deactivate!
            elsif changed_service && fiber_depends_on_service?(fiber, changed_service.to_s.downcase)
              with_activation_marker(fiber) { fiber.reactivate!(@context) }
            end
          when :failed
            deferred = fiber if fiber.ready_to_activate?(@context)
          end
        end

        # Monitor is now fully released (depth 0); the deferred retry's backoff
        # sleep therefore runs with no lock held.
        return unless deferred

        @retry_gate.attempt(deferred) do |fiber|
          with_activation_marker(fiber) { fiber.activate!(@context) }
        end
      end

      def active_fibers
        @monitor.synchronize { @fibers.values.select { |f| f.state == :active } }
      end

      def pending_fibers
        @monitor.synchronize { @fibers.values.select { |f| f.state == :pending } }
      end

      def failed_fibers
        @monitor.synchronize { @fibers.values.select { |f| f.state == :failed } }
      end

      def dispose!
        @monitor.synchronize do
          return if @disposed

          @disposed = true
          begin
            @fibers.values.reverse_each do |fiber|
              fiber.dispose!
            rescue StandardError => e
              Rubik::Log.warn(:runtime, "fiber '#{fiber.name}' dispose failed: #{e.class}: #{e.message}")
            end
          ensure
            @fibers.clear
            @retry_gate.clear_all # fresh-eye R2: no bookkeeping outlives the manager
            @context.dispose
          end
        end
      end

      private

      # Marks the fiber while its factory runs so nested reconciles skip it;
      # ensure-based so a raising factory (→ :failed) never wedges the marker.
      def with_activation_marker(fiber)
        @activating[fiber.name] = true
        begin
          yield
        ensure
          @activating.delete(fiber.name)
        end
      end

      # A fiber depends on a changed service when it injects the literal key
      # or a legacy alias of it (Rubik::Coeffects SSOT), so alias-injected
      # fibers react to canonical re-provides instead of holding stale
      # service instances.
      def fiber_depends_on_service?(fiber, changed_key)
        fiber.inject.any? { |dep| dep == changed_key || Rubik::Coeffects.canonical(dep) == changed_key }
      end
    end
  end
end
