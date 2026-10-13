# frozen_string_literal: true

require_relative "notices"
require_relative "../provider_recovery"

module Rubik
  module Orchestrator
    module Subagent
      # The subagent's context-recovery plane, extracted from StepRunner
      # (module hygiene): routine compaction evaluation, the emergency
      # compaction actuator, and the bus announcement. One vertical slice —
      # history pruning and its observable event.
      module ContextCompaction
        def evaluate_subagent_context_compaction!
          return unless @context_limit&.positive?

          context_cfg = ProviderRecovery.compaction_config(@config)
          needs = Rubik::Prompt::ContextCompactor.needs_compaction?(
            @history, context_limit: @context_limit, max_output_tokens: @max_output_tokens, config: context_cfg
          )
          return unless needs

          compacted = Rubik::Prompt::ContextCompactor.compact_history(
            @history, context_limit: @context_limit, max_output_tokens: @max_output_tokens, config: context_cfg
          )
          before = @history.size
          @history.replace(compacted)
          # Journaled BEFORE the next step can prune further (issue #124): the
          # pre-compaction event sequence stays reconstructible.
          @journal&.record_compaction(run: @run_seq, layer: "context_compactor", before: before, after: @history.size)
        end

        # Compaction actuator for the subagent path (mirrors Loop's seam): the
        # body lives in TurnExecutor#emergency_compact! (one home for both
        # channels); this delegates and the channel announces on the bus. Never
        # call it while holding @monitor (the emit stays lock-free).
        def emergency_compact_and_notify!(reason)
          turn_executor.emergency_compact!(reason)
        end

        # The object that owns the fact emits it — outside the monitor, so
        # subscribers never run under the instance lock.
        def emit_compacted_event(reason, layer)
          @journal&.record_compaction(run: @run_seq, layer: layer, reason: reason)
          Notices.emit(@event_bus, Notices::COMPACTED_EVENT, { id: @id, role: @role, state: @state, reason: reason.to_s, layer: layer })
        end
      end
    end
  end
end
