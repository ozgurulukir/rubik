# frozen_string_literal: true

require_relative "../coeffects"

module Rubik
  module Runtime
    class CoeffectMissingError < StandardError; end

    class Context
      attr_reader :parent, :disposed, :last_dispose_errors

      # Legacy alias -> canonical key, derived from the Rubik::Coeffects SSOT
      # (AGENTS.md §1.B). Providers publish canonical keys only; consumers may
      # still ask with documented legacy names (e.g. plugin DSL inject: [:tools]).
      CANONICAL_OF = Rubik::Coeffects::LEGACY_ALIASES.each_with_object({}) do |(canonical, aliases), map|
        aliases.each { |alias_key| map[alias_key] = canonical }
      end.freeze

      def initialize(parent: nil)
        @parent = parent
        @services = {}
        @disposables = []
        @children = []
        @disposed = false
        @last_dispose_errors = []
      end

      def register_disposable(cleanup_fn = nil, &block)
        fn = cleanup_fn || block
        return unless fn

        @disposables << fn
      end
      alias on_dispose register_disposable

      # Number of pending inverse operations in the Omega accumulator.
      # Exposed for runtime visualization (!agents panel, !runtime).
      def disposable_count
        @disposables.size
      end

      def services
        @services.dup.freeze
      end

      def service_names
        @services.keys
      end

      def provide(name, service)
        key = name.to_s.downcase
        already_provided = @services.key?(key)
        @services[key] = service
        # Exactly one delete-inverse per key for the context's lifetime:
        # re-providing a service swaps the value but never stacks a second
        # inverse into the Omega accumulator (AGENTS.md zero-restart rule).
        register_disposable { @services.delete(key) } unless already_provided
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
      def resolve(key)
        return @services[key] if @services.key?(key)

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
        child = Context.new(parent: self)
        @children << child
        register_disposable { child.dispose unless child.disposed? }
        child
      end

      def disposed?
        @disposed
      end

      def dispose
        return if @disposed

        @disposed = true

        # 1. Dispose child contexts first
        @children.reverse_each do |child|
          child.dispose unless child.disposed?
        end
        @children.clear

        # 2. Execute accumulated inverses in strict reverse order (LIFO - Omega accumulator).
        #    A failing inverse must never abort the unwind (AGENTS.md §5):
        #    record it, report to stderr, keep draining the accumulator.
        @last_dispose_errors = []
        begin
          while (fn = @disposables.pop)
            begin
              fn.call
            rescue StandardError => e
              @last_dispose_errors << e
              warn "[rubik] dispose inverse failed: #{e.class}: #{e.message}"
            end
          end
        ensure
          @services.clear
        end
      end
      alias dispose! dispose
    end
  end
end
