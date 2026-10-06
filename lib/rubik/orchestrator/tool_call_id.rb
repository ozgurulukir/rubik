# frozen_string_literal: true

module Rubik
  module Orchestrator
    # THE single vocabulary home for the orchestrator family's tool-call
    # id spellings (previously three independent interpolations: Loop's
    # response normalizer, Subagent::StepRunner, StepExecutor's defensive
    # fallback). One prefix and joining convention; TWO deliberate
    # uniqueness policies — the sites' collision realities differ:
    #
    # - Loop (unique: true): production builds a fresh Loop per turn while
    #   the session history persists, so step_count restarts every turn
    #   and a deterministic "call_3_1" WILL recur inside one history —
    #   duplicate tool_use ids break strict providers' tool_result
    #   pairing. The 4-digit random suffix is load-bearing, not decor.
    # - Subagent StepRunner (deterministic): a subagent's history lives
    #   and dies with its own run — never restored, never continued — so
    #   (subagent id, step, index) is unique by construction, and
    #   determinism keeps ids greppable across subagents in transcripts.
    # - StepExecutor (unique: true): dead on the production path (the
    #   TurnExecutor normalizes ids before dispatch) but live on the
    #   executor's own seam — test doubles call it with bare, id-less tool
    #   calls, and no turn-local index exists there.
    #
    # mint is spelling-only by design: the id PRECEDENCE chain
    # (tc["id"] || tc[:id] || mint) lives in one place now — the shared
    # TurnExecutor normalizer — while the mint policy per channel is
    # supplied through Channel#mint_call_id. Both channels receive fresh
    # normalized {"id","tool","args"} hashes; the llm/ layer's dumb
    # call_#{rand} fallbacks stay there: llm must never require
    # orchestrator (layering).
    module ToolCallId
      module_function

      # mint(3, 2)                        -> "call_3_2"
      # mint("subagent-2", 5, 3)          -> "call_subagent-2_5_3"
      # mint(4, unique: true)             -> "call_4_4821"
      # mint(3, 2, unique: true)          -> "call_3_2_4821"
      # Byte-compatible with every pre-extraction spelling.
      def mint(*parts, unique: false)
        id = "call_#{parts.join('_')}"
        id = "#{id}_#{rand(1000..9999)}" if unique
        id
      end
    end
  end
end
