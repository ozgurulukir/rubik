# frozen_string_literal: true

require_relative "../tool_call_id"

module Rubik
  module Orchestrator
    class TurnExecutor
      # The subagent-channel adapter: wraps the Subagent::Instance. Its
      # methods run on the worker thread only, between monitor sections —
      # the channel never holds @monitor and never emits on the bus under
      # it (the same discipline as the StepRunner methods it replaces).
      class SubagentChannel < Channel
        def initialize(instance)
          super()
          @inst = instance
        end

        attr_reader :inst

        # ── required state ──
        def history = @inst.history

        def tool_registry = @inst.tool_registry

        def limits
          { context_limit: @inst.context_limit, max_output_tokens: @inst.max_output_tokens, config: @inst.config }
        end

        # Subagent policy (ToolCallId doctrine): deterministic
        # (subagent id, step, index) — the history lives and dies with the
        # run, and greppable ids beat collision-proof ones here.
        def mint_call_id(idx)
          ToolCallId.mint(@inst.id, @inst.current_step, idx + 1)
        end

        # ── response shaping ──
        # Moved verbatim from StepRunner#extract_response_content: Struct
        # mock providers expose #content, real responses expose #text.
        def response_text(res)
          return res.text.to_s if res.respond_to?(:text)
          return res.content.to_s if res.respond_to?(:content)

          res.to_s
        end

        # Struct/duck mock providers expose the array attribute without the
        # Response predicate — read the attribute directly.
        def raw_tool_calls(res)
          res.respond_to?(:tool_calls) ? res.tool_calls : []
        end

        def track_usage(res)
          usage = res.respond_to?(:usage) ? res.usage : nil
          @inst.journal&.record_token_usage(run: @inst.run_seq, usage: usage)
        end

        # Deferred: subagent continuation is future work.
        def handle_truncation(_res, _text, _tool_calls, _finish_reason) = nil

        # ── announce ──
        def announce_compaction(reason, layer)
          @inst.emit_compacted_event(reason, layer)
        end

        def announce_llm_thought(_text, streamed: false) = nil

        # ── terminals & dispatch ──
        # The shared two-strike nudge policy (Channel#empty_response_turn)
        # now governs empty, tool-less responses: one standard nudge row,
        # then the terminal below on the second consecutive strike. The
        # subagent can no longer "complete" with an empty result — the
        # declared Phase 4 delta.
        def empty_response_failure
          @inst.fail_turn!("Empty response from model (2 consecutive)")
          { ok: false, completed: false }
        end

        def final_text_result(final_text)
          @inst.history << { role: "assistant", content: final_text.empty? ? nil : final_text, tool_calls: nil }
          @inst.complete_turn!(final_text)
          { ok: true, completed: true }
        end

        def append_tool_call_row(final_text, tool_calls)
          @inst.history << { role: "assistant", content: final_text.empty? ? nil : final_text, tool_calls: tool_calls }
        end

        def on_finish(args, fallback_text)
          message = args["message"] || args[:message] || fallback_text || "Completed"
          @inst.auto_apply_buffer!(:finish) unless @inst.workspace == "branch"
          @inst.complete_turn!(message)
          { ok: true, completed: true }
        end

        def execute_tool_call(tool_call, text)
          return on_finish(tool_call["args"] || {}, text) if TurnExecutor.finish_call?(@inst.tool_registry, tool_call)

          @inst.execute_subagent_tool_call(tool_call)
          nil
        end
      end
    end
  end
end
