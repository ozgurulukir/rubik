# frozen_string_literal: true

require_relative "../shell_deps"
require_relative "../tool_call_id"

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

        def limits
          { context_limit: @deps.context_limit, max_output_tokens: @deps.max_output_tokens, config: @deps.config }
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
          return text if cm.continuation_buffer.empty?

          cm.stitch_and_reset(res.text.to_s)
        end

        def track_usage(res) = @deps.budget_manager.track_token_usage!(res)

        # Moved truncation/auto-continue flow (Plan 90): classify the
        # truncation, append the partial thought/text rows plus the
        # targeted nudge, or return the diagnostic terminal when
        # auto-continue is disabled or the ceiling is exhausted.
        def handle_truncation(res, _text_resp, tool_calls, finish_reason)
          cm = @deps.loop_instance.continuation_manager
          return nil unless cm.truncation?(finish_reason)

          trunc_action = cm.handle_truncation(
            finish_reason: finish_reason,
            text_resp: res.text.to_s,
            tool_calls: tool_calls,
            res: res,
            max_tokens: @deps.max_output_tokens || @deps.safe_config("llm.default_max_output_tokens", 4096)
          )

          if trunc_action[:continue]
            nudge_policy.reset!
            if trunc_action[:thought]
              @deps.history << { role: "assistant", content: nil, thought: trunc_action[:thought] }
            elsif trunc_action[:partial_text]
              @deps.history << { role: "assistant", content: trunc_action[:partial_text] }
            end
            @deps.history << { role: "user", content: trunc_action[:nudge] }
            @deps.on_step&.call(trunc_action[:step_event].merge(step: @deps.step_count, max_steps: @deps.max_steps)) if trunc_action[:step_event]
            return :consumed
          end
          return nil unless trunc_action[:error]

          @deps.on_step&.call(type: :error, content: trunc_action[:error], step: @deps.step_count, max_steps: @deps.max_steps)
          @deps.loop_instance.turn_result(success: false, error: trunc_action[:error])
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
          @deps.on_step&.call(type: :emergency_compact, reason: reason, step: @deps.step_count,
                              max_steps: @deps.max_steps, layer: layer)
        end

        def announce_llm_thought(text)
          @deps.on_step&.call(type: :llm_thought, content: text, step: @deps.step_count, max_steps: @deps.max_steps)
        end

        # ── terminals & dispatch ──
        def empty_response_failure
          @deps.loop_instance.turn_result(success: false, error: "Empty response from model")
        end

        def final_text_result(final_text)
          @deps.history << { role: "assistant", content: final_text }
          @deps.on_step&.call(type: :message, content: final_text, step: @deps.step_count, max_steps: @deps.max_steps)
          @deps.loop_instance.turn_result(success: true, output: final_text)
        end

        def append_tool_call_row(final_text, tool_calls)
          @deps.history << { role: "assistant", content: final_text.empty? ? nil : final_text, tool_calls: tool_calls }
        end

        def on_finish(args, fallback_text)
          @deps.loop_instance.step_executor.handle_finish_tool(args, fallback_text)
        end

        def execute_tool_call(tool_call, text)
          @deps.loop_instance.step_executor.execute_single_tool_call(tool_call, text)
        end
      end
    end
  end
end
