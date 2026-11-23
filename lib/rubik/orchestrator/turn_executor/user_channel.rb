# frozen_string_literal: true

require_relative "../shell_deps"
require_relative "../tool_call_id"
require_relative "../tool_history"

module Rubik
  module Orchestrator
    class TurnExecutor
      # The user-channel adapter: wraps the Loop through the ShellDeps
      # façade, so bare Class#allocate-built test loops keep working
      # (the StepExecutor/BudgetManager/StreamManager precedent). Owns the
      # user channel's response shaping: continuation stitching, the
      # truncation/auto-continue flow, thought-aware nudges, step events,
      # and the turn_result contract.
      class UserChannel < Channel
        def initialize(loop_or_deps)
          super()
          @deps = ShellDeps.wrap(loop_or_deps)
        end

        attr_reader :deps

        # ── required state ──
        def history = @deps.history

        def tool_registry = @deps.tool_registry

        # Observation projection directive (plan D): yalnız goal-mode user
        # kanalında çözülür; directive_for önkoşul matrisi (knob'lar,
        # coeffect, rev ≥ 1) sağlanmazsa nil döner → compaction byte-özdeş.
        def absorb_directive
          return nil unless @deps.goal_mode?

          Rubik::Orchestrator::GoalLedger::ObservationProjection.directive_for(deps: @deps)
        end

        def limits
          reserved = if @deps.respond_to?(:tool_registry) && @deps.tool_registry&.schemas
                       Rubik::Prompt::TokenEstimator.estimate_tool_schemas(@deps.tool_registry.schemas)
                     else
                       0
                     end
          { context_limit: @deps.context_limit, max_output_tokens: @deps.max_output_tokens, config: @deps.config, reserved_tokens: reserved }
        end

        # Loop policy (ToolCallId doctrine): unique-by-suffix ids — the
        # session history survives across turns while step_count restarts.
        def mint_call_id(idx)
          ToolCallId.mint(@deps.step_count, idx + 1, unique: true)
        end

        # ── response shaping ──
        # Moved stitch_response: a buffered continuation turn prepends the
        # accumulated partial text and resets the buffer.
        def final_text(res, text)
          cm = @deps.loop_instance.continuation_manager
          # `text` is the executor's already-sanitized (and stripped)
          # response. Use it as-is for a normal turn; the stitching branch
          # below sanitizes raw res.text separately (issue #547).
          safe_text = Platform.safe_utf8(text).to_s
          if cm.continuation_buffer.empty?
            # A response without a pending truncation closes the consecutive
            # truncation chain (issue #549). stitch_and_reset covers the other
            # branch; this keeps the buffer itself intact.
            cm.reset_strikes!
            return safe_text
          end

          # Stitch the RAW response (sanitized): `text` was already stripped
          # by TurnExecutor#call, which would eat the leading indentation of
          # the continuation chunk (issue #547). The history is handed in so
          # the prior partial assistant rows are absorbed — the stitched
          # full text must not duplicate them (issue #595-1).
          raw_text = res.respond_to?(:text) ? res.text : text
          cm.stitch_and_reset(Platform.safe_utf8(raw_text).to_s, history: @deps.history)
        end

        def track_usage(res) = @deps.budget_manager.track_token_usage!(res)

        # Moved truncation/auto-continue flow (Plan 90): classify the
        # truncation, append the partial thought/text rows plus the
        # targeted nudge, or return the diagnostic terminal when
        # auto-continue is disabled or the ceiling is exhausted.
        def handle_truncation(res, text_resp, tool_calls, finish_reason)
          cm = @deps.loop_instance.continuation_manager
          return nil unless cm.truncation?(finish_reason)

          # Sanitize the RAW response here rather than reusing the already
          # stripped `text_resp`: the continuation buffer must keep the exact
          # partial text (including its trailing newline) while invalid bytes
          # echoed with finish_reason=length must not raise in
          # ContinuationManager#classify_truncation (issue #547).
          raw_text = res.respond_to?(:text) ? res.text : text_resp
          safe_text = Platform.safe_utf8(raw_text).to_s
          trunc_action = cm.handle_truncation(
            finish_reason: finish_reason,
            text_resp: safe_text,
            tool_calls: tool_calls,
            res: res,
            max_tokens: @deps.max_output_tokens || @deps.safe_config("llm.default_max_output_tokens", 4096)
          )

          if trunc_action[:continue]
            nudge_policy.reset!
            if trunc_action[:thought]
              thought = Platform.safe_utf8(trunc_action[:thought])
              @deps.history << { role: "assistant", content: nil, thought: thought }
            elsif trunc_action[:partial_text]
              @deps.history << { role: "assistant", content: trunc_action[:partial_text] }
            end
            @deps.history << { role: "user", content: trunc_action[:nudge] }
            @deps.on_step&.call(trunc_action[:step_event].merge(step: @deps.step_count, max_steps: @deps.max_steps)) if trunc_action[:step_event]
            return :consumed
          end
          return nil unless trunc_action[:error]

          # Failure terminal (auto-continue disabled or ceiling exhausted):
          # the generated content must not be dropped from history (issue
          # #595-2). Persist buffer + current partial as ONE assistant row,
          # absorbing any prior partial rows so nothing is duplicated —
          # the same invariant as the stitch path.
          accumulated = cm.continuation_buffer + safe_text
          unless accumulated.strip.empty?
            cm.absorb_partial_rows!(@deps.history)
            @deps.history << { role: "assistant", content: accumulated }
          end
          # The buffered text now lives in history as one row. Flush the
          # manager so a resumed run neither duplicates it nor re-inherits an
          # exhausted strike count (issue #613: truncation is resumable).
          cm.reset!

          @deps.on_step&.call(type: :error, content: trunc_action[:error], step: @deps.step_count, max_steps: @deps.max_steps)
          @deps.loop_instance.turn_result(success: false, error: trunc_action[:error], reason: :output_truncated)
        end

        # ── nudge texts ──
        # Plan 61 D-11 thought-aware variant: reasoning spent the budget
        # without an action deserves a different sentence than a blank reply.
        def empty_nudge_message(res)
          if res.respond_to?(:thought) && res.thought && !res.thought.to_s.strip.empty?
            "Your reasoning was completed, but no action or final response was provided. Please call a tool or provide your final output."
          else
            super
          end
        end

        # ── announce ──
        def announce_compaction(reason, layer)
          manager = @deps.runtime_manager if @deps.respond_to?(:runtime_manager)
          Rubik::Storage::Vakanuvis::Orientation.inject_after_compaction!(@deps.history, manager, config: @deps.config)
          @deps.on_step&.call(type: :emergency_compact, reason: reason, step: @deps.step_count,
                              max_steps: @deps.max_steps, layer: layer)
        end

        def announce_llm_thought(text, streamed: false)
          @deps.on_step&.call(type: :llm_thought, content: text, streamed: streamed, step: @deps.step_count, max_steps: @deps.max_steps)
        end

        # ── terminals & dispatch ──
        def empty_response_failure
          @deps.loop_instance.turn_result(success: false, error: "Empty response from model")
        end

        def final_text_result(final_text)
          @deps.history << { role: "assistant", content: final_text }
          @deps.on_step&.call(type: :message, content: final_text, step: @deps.step_count, max_steps: @deps.max_steps)
          return goal_wait_yield(via: "text") if goal_guard_pending?

          @deps.loop_instance.turn_result(success: true, output: final_text)
        end

        def append_tool_call_row(final_text, tool_calls)
          @deps.history << { role: "assistant", content: final_text.empty? ? nil : final_text, tool_calls: tool_calls }
        end

        def on_finish(args, fallback_text)
          @deps.loop_instance.step_executor.handle_finish_tool(args, fallback_text)
        end

        def execute_tool_call(tool_call, text)
          # Guard BEFORE dispatch: a finish over live subagents must not
          # reach handle_finish_tool (its auto-apply and :finish event
          # would celebrate a completion the pipeline has not reached).
          # The deferred call still gets its canonical result row — the
          # loop continues, so the next provider request must see the
          # tool_use paired (strict providers 400 on orphaned ids).
          if TurnExecutor.finish_call?(@deps.tool_registry, tool_call) && goal_guard_pending?
            ToolHistory.write(@deps.history,
                              tool_call_id: tool_call["id"],
                              tool_name: "finish",
                              status: :ok,
                              duration_ms: 0.0,
                              content: "finish deferred: dispatched subagents still active — the goal stays open")
            return goal_wait_yield(via: "finish")
          end

          @deps.loop_instance.step_executor.execute_single_tool_call(tool_call, text)
        end

        private

        # Goal-mode premature-completion guard (GoalWait): in goal mode a
        # success terminal while dispatched subagents are still live is a
        # false "Goal Achieved" (field incident 2026-10-05) — route it
        # through the implicit yield-and-wait, which returns nil so the
        # step loop continues. Interactive/default mode never reaches it.
        def goal_guard_pending?
          @deps.goal_mode? && @deps.loop_instance.goal_wait.pending?
        end

        def goal_wait_yield(via:)
          @deps.loop_instance.goal_wait.premature_yield!(via: via)
        end
      end
    end
  end
end
