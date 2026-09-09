# frozen_string_literal: true

module Rubik
  # Canonical runtime-context coeffect keys (AGENTS.md §1.B — explicit
  # dependency contracts). Single source of truth for service key names
  # shared between providers (Runtime::*Service) and consumers (tools,
  # registry). Legacy alias keys remain readable for backward compatibility
  # but must not be referenced by name outside this module.
  module Coeffects
    CONTEXT_INDEX  = "context_index"
    AST_GRAPH      = "ast_graph"
    BUFFER         = "buffer"
    BUFFER_MANAGER = "buffer_manager"

    LEGACY_ALIASES = {
      CONTEXT_INDEX => ["index"],
      AST_GRAPH => ["ast"]
    }.freeze

    class << self
      # Read a coeffect by canonical key, falling back to legacy aliases.
      # Returns nil when the dependency is unsatisfied anywhere on the
      # context chain.
      def get(ctx, key)
        return nil unless ctx.respond_to?(:get)

        [key, *LEGACY_ALIASES.fetch(key, [])].each do |k|
          value = ctx.get(k)
          return value if value
        end
        nil
      end

      # Tool-side resolution order: runtime context first, then the
      # constructor-injected instance.
      def resolve(ctx, key, injected = nil)
        get(ctx, key) || injected
      end
    end
  end
end
