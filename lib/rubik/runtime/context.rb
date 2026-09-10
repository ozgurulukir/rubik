# frozen_string_literal: true

require "monitor"
require_relative "../coeffects"

module Rubik
  module Runtime
    class CoeffectMissingError < StandardError; end

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
          # Exactly one delete-inverse per key for the context's lifetime:
          # re-providing a service swaps the value but never stacks a second
          # inverse into the Omega accumulator (AGENTS.md zero-restart rule).
          register_disposable { @services.delete(key) } unless already_provided
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
      def resolve_with_alias(key)
        resolve(key) || begin
          canonical = CANONICAL_OF[key]
          resolve(canonical) if canonical
        end
      end

      def extend
        child = nil
        @monitor.synchronize do
          child = Context.new(parent: self)
          @children << child
          register_disposable { child.dispose unless child.disposed? }
        end
        child
      end

      def disposed?
        @disposed
      end

      def dispose
        @monitor.synchronize do
          return if @disposed

          @disposed = true

          # 1. Dispose child contexts first (parent→child lock order; children
          #    never hold their lock while reaching back to the parent).
          @children.reverse_each do |child|
            child.dispose unless child.disposed?
          end
          @children.clear

          # 2. Execute accumulated inverses in strict reverse order (LIFO - Omega accumulator).
          #    A failing inverse must never abort the unwind (AGENTS.md §5):
          #    record it, report to stderr, keep draining the accumulator.
          #    Registration racing the drain is serialized by the monitor, so a
          #    late inverse is either picked up by the pop loop or — after the
          #    context is sealed — executed immediately by register_disposable.
          @last_dispose_errors = []
          begin
            while (inverse = @disposables.pop)
              run_inverse(inverse)
            end
          ensure
            @services.clear
          end
        end
      end
      alias dispose! dispose

      private

      # Runs one inverse, never letting a failure abort the unwind (AGENTS.md §5):
      # record it, report to stderr, keep going.
      def run_inverse(inverse)
        inverse.call
      rescue StandardError => e
        @last_dispose_errors << e
        warn "[rubik] dispose inverse failed: #{e.class}: #{e.message}"
      end
    end
  end
end
