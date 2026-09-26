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
    BUFFER_MANAGER = "buffer_manager"
    SNAPSHOT_STORE = "snapshot_store"
    LSP_MANAGER    = "lsp_manager"
    MCP_MANAGER    = "mcp_manager"
    SKILL_MANAGER  = "skill_manager"
    # REPL composition root, published by wire_runtime_context (repl/lifecycle.rb).
    # The sanctioned access path; the ambient root accessor pair in lib/rubik.rb
    # is deprecated (sunset — review Öneri 4).
    SHELL          = "shell"
    ADAPTER_REGISTRY = "adapter_registry"
    LLM_CLIENT     = "llm_client"
    TOOL_REGISTRY  = "tool_registry"
    TASK_MANAGER   = "task_manager"
    SUBAGENT_SUPERVISOR = "subagent_supervisor"
    # Shared security guard (operator policy carrier), published by
    # wire_runtime_context and consumed via the Registry build_default
    # triple chain.
    GUARD          = "guard"
    # Layered config object, published by wire_runtime_context for consumers
    # that need config-derived values outside constructor injection.
    CONFIG         = "config"
    # Keys wire_runtime_context historically published as literals; surfaced
    # as constants by Candidate 05's ServiceCatalog so every provided entry
    # references this module (key names stay the SSOT here).
    EVENTS         = "events"
    SANDBOX_RUNNER = "sandbox"
    ROUTER         = "router"
    PLUGIN_MANAGER = "plugin_manager"
    PLUGIN_STORAGE = "plugin_storage"
    DMESG          = "dmesg"
    DISPATCHER     = "dispatcher"
    INIT           = "init"

    # Read-side bridge: third-party providers may still register services
    # under these legacy alias keys; canonical keys are always tried first.
    LEGACY_ALIASES = {
      CONTEXT_INDEX => ["index"],
      AST_GRAPH => ["ast"],
      BUFFER_MANAGER => ["buffer"],
      SNAPSHOT_STORE => ["snapshot"],
      LSP_MANAGER => ["lsp"],
      MCP_MANAGER => ["mcp"],
      ADAPTER_REGISTRY => ["adapters"],
      LLM_CLIENT => ["llm"],
      TOOL_REGISTRY => ["tools"],
      TASK_MANAGER => ["tasks"],
      SUBAGENT_SUPERVISOR => ["subagents", "subagent_pool"]
    }.freeze

    # Reverse map: legacy alias -> canonical key, derived from LEGACY_ALIASES.
    # Powers the read-side bridge and reactive matching (Manager#reconcile_fiber),
    # so alias-injected fibers react to canonical re-provides.
    ALIAS_TO_CANONICAL = LEGACY_ALIASES.each_with_object({}) do |(canonical, aliases), map|
      aliases.each { |alias_key| map[alias_key] = canonical }
    end.freeze

    class << self
      # Canonical key for any request: identity for canonical or unknown keys,
      # the mapped canonical for legacy alias names.
      def canonical(key)
        ALIAS_TO_CANONICAL.fetch(key.to_s.downcase, key.to_s.downcase)
      end

      # Read a coeffect by canonical key, falling back to legacy aliases.
      # Returns nil when the dependency is unsatisfied anywhere on the
      # context chain.
      def get(ctx, key)
        return nil unless ctx.respond_to?(:get)

        [key, *LEGACY_ALIASES.fetch(key, [])].each do |k|
          value = ctx.get(k)
          return value unless value.nil?
        end
        nil
      end

      # Tool-side resolution order: runtime context first, then the
      # constructor-injected instance.
      def resolve(ctx, key, injected = nil)
        val = get(ctx, key)
        val.nil? ? injected : val
      end
    end
  end
end
