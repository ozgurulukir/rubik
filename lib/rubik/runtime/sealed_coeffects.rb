# frozen_string_literal: true

require_relative "../coeffects"
require_relative "../log"

module Rubik
  module Runtime
    # Shared capability gate for sealed execution contexts (synthesized tools
    # and commands). The Guard vets the synthesized code itself; this
    # deny-list is the gate on what that code may resolve through the sealed
    # context's coeffect/require path.
    module SealedCoeffects
      # Coeffects that must NEVER be leaked to synthesized code. Canonical
      # keys (Rubik::Coeffects); legacy alias spellings canonicalize to their
      # canonical form before the check, so aliases of a blocked service are
      # denied without being restated here. App-domain coeffects (e.g.
      # storage) stay reachable by design.
      BLOCKED_COEFFECTS = [
        "guard",
        "config",
        "sandbox",
        "sandbox_runner",
        "shell",
        "buffer_manager",
        "runtime_manager",
        "task_manager",
        "subagent_supervisor",
        "init",
        "dispatcher",
        "commands",
        "tool_registry",
        "adapter_registry",
        "mcp_manager",
        "llm_client",
        "router",
        "plugin_manager",
        "plugin_storage",
        "lsp_manager",
        "skill_manager"
      ].freeze

      private

      # A legacy alias of a blocked service (e.g. "tools" for
      # "tool_registry") must not slip through under its unblocked spelling.
      def blocked?(key)
        canonical = Rubik::Coeffects.canonical(key)
        blocked = BLOCKED_COEFFECTS.include?(key) || BLOCKED_COEFFECTS.include?(canonical)
        Rubik::Log.debug(:runtime, "sealed context denied coeffect '#{key}'") if blocked
        blocked
      end
    end
  end
end
