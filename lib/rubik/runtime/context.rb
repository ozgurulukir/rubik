# frozen_string_literal: true

require "monitor"
require_relative "../coeffects"

module Rubik
  module Runtime
    class CoeffectMissingError < StandardError; end

    # Raised when a disposed context is asked to create new scope. Unlike a
    # late inverse (which can run now), there is no meaningful fallback for
    # extend, so it fails fast (AGENTS.md Fail Fast template).
    class ContextDisposedError < StandardError; end

    class Context
      attr_reader :parent, :disposed

      # Legacy alias -> canonical key, derived from the Rubik::Coeffects SSOT
      # (AGENTS.md §1.B). Providers publish canonical keys only; consumers may
      # still ask with documented legacy names (e.g. plugin DSL inject: [:tools]).
      CANONICAL_OF = Rubik::Coeffects::ALIAS_TO_CANONICAL

      def initialize(parent: nil)
        @parent = parent
        @monitor = Monitor.new
        @services = {}
        # Delete-inverse handles keyed by service / child, so explicit
        # removals (unprovide, child prune) can also retract the inverse
        # from the Omega accumulator instead of leaving dead no-ops behind.
        @service_inverses = {}
        @child_inverses = {}
        @disposables = []
        @children = []
        @disposed = false
        @last_dispose_errors = []
      end

      def register_disposable(cleanup_fn = nil, &block)
        inverse = cleanup_fn || block
        return unless inverse

        @monitor.synchronize do
          if @disposed
            # Ω is sealed: the context is already torn down, so there is no
            # later drain that would run this inverse. Execute it now instead
            # of silently storing it in a dead accumulator (leaked cleanup).
            run_inverse(inverse)
          else
            @disposables << inverse
          end
        end
        inverse
      end
      alias on_dispose register_disposable

      # Number of pending inverse operations in the Omega accumulator.
      # Exposed for runtime visualization (!agents panel, !runtime).
      def disposable_count
        @monitor.synchronize { @disposables.size }
      end

      def services
        @monitor.synchronize { @services.dup.freeze }
      end

      def service_names
        @monitor.synchronize { @services.keys }
      end

      def last_dispose_errors
        @monitor.synchronize { @last_dispose_errors.dup }
      end

      def provide(name, service)
        key = name.to_s.downcase
        @monitor.synchronize do
          already_provided = @services.key?(key)
          @services[key] = service
          return if already_provided

          # Exactly one delete-inverse per key for the context's lifetime:
          # re-providing a service swaps the value but never stacks a second
          # inverse into the Omega accumulator (AGENTS.md zero-restart rule).
          # The handle is kept so unprovide can retract it symmetrically.
          @service_inverses[key] = register_disposable { @services.delete(key) }
        end
      end

      # Removes a service AND its delete-inverse from the accumulator, the
      # symmetric counterpart of provide. Callers own the reactive surface:
      # unlike Runtime::Manager#provide, removal triggers no reconciliation.
      # Re-providing the key afterwards registers a fresh inverse, so
      # provide/unprovide cycles return Ω to its baseline (zero-restart).
      def unprovide(name)
        key = name.to_s.downcase
        @monitor.synchronize do
          return unless @services.key?(key)

          @services.delete(key)
          inverse = @service_inverses.delete(key)
          @disposables.delete(inverse) if inverse
        end
      end

      def require(name)
        value = resolve_with_alias(name.to_s.downcase)
        return value if value

        raise CoeffectMissingError, "Required coeffect '#{name}' is not satisfied in the context."
      end

      def get(name, default = nil)
        resolve_with_alias(name.to_s.downcase) || default
      end

      # Walk the context chain for a literal key. Returns nil when the key is
      # absent (services are always live objects, never nil, in this runtime).
      # Per-hop locking: each context holds only its own monitor during the
      # local lookup and releases it before recursing to the parent, so
      # chained reads never nest child→parent locks (disposal nests only
      # parent→child; the reverse order would risk deadlock).
      def resolve(key)
        local = nil
        @monitor.synchronize { local = @services[key] if @services.key?(key) }
        return local if local

        @parent&.resolve(key)
      end

      def satisfied?(dependencies)
        Array(dependencies).all? { |dep| has?(dep) }
      end

      def has?(name)
        !resolve_with_alias(name.to_s.downcase).nil?
      end

      # Literal key first (a third party may have provided the alias itself),
      # then the canonical key when the request used a legacy alias name.
      #
      # The LOCAL context's literal-vs-canonical check is now atomic under one
      # monitor hold so the same-hop race the reviewer flagged (a service
      # disappearing between two separate lock acquisitions) can no longer lose
      # it. Falls back to the parent-chain resolve otherwise; the per-hop
      # locking and parent→child lock order documented on `resolve` are
      # preserved, so this introduces no deadlock.
      def resolve_with_alias(key)
        @monitor.synchronize do
          return @services[key] if @services.key?(key)

          canonical = CANONICAL_OF[key]
          return @services[canonical] if canonical && @services.key?(canonical)
        end

        resolve(key) || begin
          canonical = CANONICAL_OF[key]
          resolve(canonical) if canonical
        end
      end

      def extend
        child = nil
        @monitor.synchronize do
          if @disposed
            raise ContextDisposedError,
                  "Cannot extend a disposed context. To fix, check `disposed?` before extending or create a fresh context."
          end

          child = Context.new(parent: self)
          @children << child
          # Keep the cascade-inverse handle so a child disposed before its
          # parent (epoch close, per-turn loop context, MCP reconnect) can
          # prune both itself and the dead inverse out of this context.
          @child_inverses[child] = register_disposable { child.dispose unless child.disposed? }
        end
        child
      end

      def disposed?
        @disposed
      end

      # Internal counterpart of extend: a disposed child removes itself and
      # its dead cascade inverse from this context. Extension contexts open
      # and close constantly (per-turn loop contexts, MCP reconnects, tool
      # epochs, fiber reactivations) — without the prune every cycle would
      # leave a dead child and a no-op inverse in the accumulator forever
      # (AGENTS.md zero-restart rule). Protected: only Context itself may
      # strip a child's bookkeeping, so external code cannot unhook a live
      # child (leak footgun). Must be called AFTER the child released its
      # own monitor, so child disposal never nests child→parent locks
      # against the parent→child order used by dispose. No-op on a disposed
      # parent (its own drain owns the bookkeeping by then).
      def prune_child(child)
        @monitor.synchronize do
          return if @disposed

          @children.delete(child)
          inverse = @child_inverses.delete(child)
          @disposables.delete(inverse) if inverse
        end
      end
      protected :prune_child

      def dispose
        parent = nil
        deferred_interrupt = nil
        @monitor.synchronize do
          return if @disposed

          @disposed = true
          parent = @parent
          # Reset BEFORE the child cascade so signals adopted from children
          # (record_deferred_signal below) survive into the final
          # last_dispose_errors instead of being wiped by this reset.
          @last_dispose_errors = []

          # 1. Dispose child contexts first (parent→child lock order; children
          #    never hold their lock while reaching back to the parent).
          #    Each child's own prune is a no-op here (@disposed has sealed
          #    the bookkeeping), so the descending iteration never observes
          #    mutation. A child's deferred Interrupt/SystemExit is adopted
          #    as (possibly) the FIRST deferred signal of this cascade — it
          #    must not abort this context's own drain.
          @children.reverse_each do |child|
            begin
              child.dispose unless child.disposed?
            rescue Interrupt, SystemExit => e
              record_deferred_signal(e)
              deferred_interrupt ||= e
            end
          end
          @children.clear

          # 2. Execute accumulated inverses in strict reverse order (LIFO - Omega accumulator).
          #    A failing inverse must never abort the unwind (AGENTS.md §5):
          #    record it, report to stderr, keep draining the accumulator.
          #    Interrupt/SystemExit get the same complete-drain policy: the
          #    signal is recorded and deferred, the drain ALWAYS finishes,
          #    and the FIRST signal is re-raised once bookkeeping and the
          #    parent prune complete (never rescue Exception).
          #    Registration racing the drain is serialized by the monitor, so a
          #    late inverse is either picked up by the pop loop or — after the
          #    context is sealed — executed immediately by register_disposable.
          begin
            while (inverse = @disposables.pop)
              begin
                run_inverse(inverse)
              rescue Interrupt, SystemExit => e
                record_deferred_signal(e)
                deferred_interrupt ||= e
              end
            end
          ensure
            @services.clear
            @service_inverses.clear
            @child_inverses.clear
          end
        end
        # 3. Release the child's monitor before reaching the parent (lock
        #    order), then prune the parent's record of this child.
        parent&.prune_child(self)
        # 4. Re-surface the FIRST deferred signal only after the unwind is
        #    fully complete — Ctrl+C during teardown still reaches the
        #    caller (repo convention: Interrupt is never swallowed), never
        #    at the cost of a half-drained accumulator.
        raise deferred_interrupt if deferred_interrupt
      end
      alias dispose! dispose

      private

      def record_deferred_signal(exception)
        @last_dispose_errors << exception
        warn "[rubik] dispose inverse raised #{exception.class} (deferred until drain completes): #{exception.message}"
      end

      # Runs one inverse, never letting a failure abort the unwind (AGENTS.md §5):
      # record it, report to stderr, keep going. Interrupt/SystemExit are NOT
      # rescued here: the drain loop in dispose defers them so the unwind
      # completes first (complete-drain-then-re-raise policy), while the
      # sealed immediate-run path in register_disposable lets them propagate
      # as-is — there is no accumulator left to protect there.
      def run_inverse(inverse)
        inverse.call
      rescue StandardError => e
        @last_dispose_errors << e
        warn "[rubik] dispose inverse failed: #{e.class}: #{e.message}"
      end
    end
  end
end
