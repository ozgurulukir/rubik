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
    # Live !goal run snapshot (Rubik::Orchestrator::GoalState), provided by the goal command and rendered to agents via read_file rubik://goal/state.
    GOAL_STATE     = "goal_state"
    # Structured goal ledger (GoalLedger::Ledger), provided by !goal when goal.ledger.enabled; unsatisfied outside a running !goal.
    GOAL_LEDGER    = "goal_ledger"
    GOAL_REGISTRY  = "goal_registry" # suspended-goal registry (GoalRegistry, issue #106)
    # Central rubik://storage store (Rubik::Storage::Store), provided by
    # Storage::Service at shell boot and resolved by the storage tool /
    # read_file rubik://storage routes / supervisor transcript indexing.
    STORAGE_STORE  = "storage_store"
    # The ask-maestro bridge (Subagent::Instance's Questioner): provided into
    # each instance's child ctx so ask_question resolves it, never on the root.
    SUBAGENT_QUESTION_ASKER = "subagent_question_asker"
    # The send_message attribution bridge: provided into each subagent's child
    # ctx so a message routes to the maestro under its REAL sender id
    # (unsatisfied on the root: Supervisor#send_message keeps "agent-0").
    SUBAGENT_SENDER_ID = "subagent_sender_id"
    # The Vakanüvis chronicler harness (Storage::Vakanuvis::Harness), provided
    # by Vakanuvis::Service at boot and resolved by the vakanuvis tool;
    # unsatisfied when the chronicler is disabled (the tool hides).
    VAKANUIS = "vakanuvis"
    # The ROOT conversation-window pruner harness (REPL::Pruner::Harness),
    # provided by Pruner::Service at shell boot (Phase 4; default ON via
    # subagents.pruner.enabled — opt-out: false) and resolved by the
    # prune_context tool and the !prune command. Unsatisfied when
    # the pruner is disabled.
    PRUNER = "pruner"
    # Foreground task cancellation token (Orchestrator::TaskCancellation, #125):
    # provided per turn and inherited by spawned subagent contexts — spawn tools
    # resolve the OWNING task; detached subtrees carry a never-cancelled token.
    TASK_CANCELLATION = "task_cancellation"

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
      SUBAGENT_SUPERVISOR => ["subagents", "subagent_pool"],
      STORAGE_STORE => ["storage"]
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
      # Resolution itself (literal -> canonical -> alias, parent-chain walk)
      # is owned by the context: Rubik::Runtime::Context resolves all three
      # spellings per hop under one monitor hold. A duck-typed ctx — the only
      # contract here is respond_to?(:get) — resolves by exact key; the
      # alias loop that used to live below is gone with it.
      # Returns nil when the dependency is unsatisfied anywhere on the
      # context chain.
      def get(ctx, key)
        return nil unless ctx.respond_to?(:get)

        ctx.get(key)
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
