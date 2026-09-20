# frozen_string_literal: true

require "monitor"
require "set"
require_relative "context"
require_relative "fiber"

module Rubik
  module Runtime
    class Manager
      attr_reader :context

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
        # name -> { attempts:, last_attempt_at: } bookkeeping for :failed fibers
        @retry_bookkeeping = {}
        # name -> Set of canonical coeffect keys this fiber's factory injects.
        # The reactive surface (provide/unprovide) consults this to decide which
        # fibers are gated on a coeffect that changed, so retracting a service
        # through the reactive path retracts (deactivates) every fiber gated on
        # it — matching provide's on-demand reactivation (AGENTS.md §5, Finding B).
        @fiber_deps = {}
      end

      # Default retry policy for failed fiber re-activation (review 2026-09-17,
      # Finding 3): a permanently-broken factory used to re-run on EVERY
      # reconcile_all (each provide/register). Now failures back off
      # exponentially and stop after MAX_FIBER_RETRIES attempts; a successful
      # activation or a fresh register_fiber clears the bookkeeping.
      MAX_FIBER_RETRIES = 5
      RETRY_BACKOFF_BASE_S = 0.05

      def fibers
        @monitor.synchronize { @fibers.dup }
      end

      def register_component(name, inject: [], requires: [], config: {}, &factory)
        name_str = name.to_s
        fiber = ComponentFiber.new(name: name_str, inject: inject, requires: requires, config: config, &factory)
        register_fiber(fiber)
      end

      # Reentrant lock safety: Monitor#synchronize is explicitly reentrant (recursive),
      # allowing register_fiber to store the fiber and activate it. The activation
      # is performed OUTSIDE the lock (via reconcile_fiber) so a failing fiber's
      # backoff sleep never serializes other threads (Finding 3).
      def register_fiber(fiber)
        deps = Array(fiber.inject).map { |n| n.to_s.downcase }
        @monitor.synchronize do
          @fiber_deps.delete(fiber.name) unless deps.empty?
          @fiber_deps[fiber.name] = deps.to_set unless deps.empty?
          @fibers[fiber.name] = fiber
          @retry_bookkeeping.delete(fiber.name) # explicit re-registration resets the retry budget
        end
        reconcile_fiber(fiber)
        fiber
      end

      def unregister_component(name)
        @monitor.synchronize do
          name_str = name.to_s
          fiber = @fibers.delete(name_str)
          @fiber_deps.delete(name_str)
          @retry_bookkeeping.delete(name_str) # fresh-eye R2: disposed fibers must not leak their retry budget
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
      def swap_component(name, inject: [], config: {}, &new_factory)
        @monitor.synchronize do
          name_str = name.to_s
          unregister_component(name_str)
          register_component(name_str, inject: inject, config: config, &new_factory)
        end
      end

      def reconcile_all(changed_service: nil)
        # Snapshot the fiber list under the monitor, release the lock, then
        # reconcile the snapshot outside it. This keeps activation side-effects
        # (and, crucially, a failing fiber's backoff sleep) OUTSIDE the manager
        # Monitor so they never serialize provide/register/reconcile on other
        # threads (Finding 3).
        fibers = @monitor.synchronize { @fibers.values.dup }
        fibers.each do |fiber|
          reconcile_fiber(fiber, changed_service: changed_service)
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
        attempt_failed_retry(deferred) if deferred
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
          @fibers.values.each(&:dispose!) # rubocop:disable Style/HashEachMethods -- snapshot array required to prevent mutation during disposal iteration
          @fibers.clear
          @retry_bookkeeping.clear # fresh-eye R2: no bookkeeping outlives the manager
          @context.dispose
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

      # Failed-fiber retry gate (Finding 3): exponential backoff between
      # attempts, hard stop after MAX_FIBER_RETRIES. The backoff sleep must NOT
      # run while holding the Manager Monitor: reconcile_fiber invokes this from
      # inside @monitor.synchronize regions. Monitor is reentrant per-thread but
      # serializes every OTHER thread, so a single failing fiber's exponential
      # backoff (0.05 -> 0.1 -> 0.2 -> ...s) would block every provide/
      # register_fiber/reconcile_all on any thread. The exhaustion warn and the
      # bookkeeping update stay atomic under the monitor; the sleep runs fully
      # OUTSIDE it (a Kernel#sleep cannot be held by a non-reentrant Monitor),
      # and the factory activation re-acquires the lock (depth 1) afterwards.
      #
      # Delay semantics from the original gate: the first attempt has no prior
      # timestamp so it backs off zero; later attempts wait
      # base * 2^(attempts-before-this-one), and the sleep is skipped when the
      # elapsed time since the previous attempt already exceeds the backoff (so
      # a backdated bookkeeping entry advances the retry without an artificial
      # wait, keeping the test-suite deterministic).
      def attempt_failed_retry(fiber)
        delay = 0.0
        elapsed = 0.0
        @monitor.synchronize do
          book = @retry_bookkeeping[fiber.name] ||= { attempts: 0, last_attempt_at: nil }
          if book[:attempts] >= MAX_FIBER_RETRIES
            warn_retry_budget_exhausted(fiber, book) # atomic, one-shot, stays under the lock
            return
          end

          prev_attempts = book[:attempts]
          ts_prev = book[:last_attempt_at]
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          delay = ts_prev ? RETRY_BACKOFF_BASE_S * (2**prev_attempts) : 0.0
          elapsed = ts_prev ? (now - ts_prev) : Float::INFINITY
          book[:attempts] += 1
          book[:last_attempt_at] = now
        end

        # Sleep happens with the monitor FULLY released (depth 0) so it never
        # serializes other threads; bookkeeping is already committed above.
        sleep(delay - elapsed) if delay > elapsed

        # Re-acquire (depth 1) and run the factory: the failing fiber is not in
        # @activating, so the reentrancy guard lets this re-activate it. A
        # successful activation clears its bookkeeping.
        @monitor.synchronize do
          with_activation_marker(fiber) { fiber.activate!(@context) }
          @retry_bookkeeping.delete(fiber.name) if fiber.state == :active
        end
      end

      # One-shot visibility when a fiber's retry budget is exhausted (fresh-eye
      # R3): the old always-retry behavior was noisy but visible; without this
      # warn a permanently-broken factory would sink silently into :failed.
      # Warns exactly once per budget cycle — re-registration resets the flag.
      def warn_retry_budget_exhausted(fiber, book)
        return if book[:warned]

        book[:warned] = true
        last = fiber.last_error
        warn "[Runtime] fiber '#{fiber.name}' retry budget exhausted " \
             "(#{book[:attempts]} attempts, MAX_FIBER_RETRIES=#{MAX_FIBER_RETRIES}) — " \
             "staying :failed; re-register to retry. Last error: #{last&.class}: #{last&.message}"
      end
    end
  end
end
