# frozen_string_literal: true

require_relative "../tool_call_id"
require_relative "../tool_history"
require_relative "../continuation_manager"

module Rubik
  module Orchestrator
    class TurnExecutor
      # The subagent-channel adapter: wraps the Subagent::Instance. Its
      # methods run on the worker thread only, between monitor sections —
      # the channel never holds @monitor and never emits on the bus under
      # it (the same discipline as the StepRunner methods it replaces).
      class SubagentChannel < Channel
        # Prefixed to results rebuilt from history after the model went silent.
        SALVAGE_NOTICE = "[Salvaged: the model returned no final report. This is the last assistant " \
                         "message from the run; see the transcript for the full work.]"

        # Output-cap growth bound for truncated turns (issue #610); the
        # operator's own llm.default_max_output_tokens still wins if higher.
        MAX_OUTPUT_TOKENS_CEILING = 16_384

        def initialize(instance)
          super()
          @inst = instance
        end

        attr_reader :inst

        # ── required state ──
        def history = @inst.history

        def tool_registry = @inst.tool_registry

        def limits
          reserved = if @inst.respond_to?(:tool_registry) && @inst.tool_registry&.schemas
                       Rubik::Prompt::TokenEstimator.estimate_tool_schemas(@inst.tool_registry.schemas)
                     else
                       0
                     end
          { context_limit: @inst.context_limit, max_output_tokens: @inst.max_output_tokens, config: @inst.config, reserved_tokens: reserved }
        end

        # Subagent policy (ToolCallId doctrine): deterministic
        # (subagent id, run, step, index). run_seq increments on every
        # start_async — spawn AND redeploy alike — so a redeployed run's
        # ids can never collide with the preserved history it re-sends to
        # the provider (issue #593). Greppable ids still beat
        # collision-proof ones here.
        def mint_call_id(idx)
          ToolCallId.mint(@inst.id, @inst.run_seq, @inst.current_step, idx + 1)
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

        # Stitches the continuation buffer (partial texts from earlier
        # finish_reason=length cycles) in front of the current text, so a
        # long final report cut off mid-way is delivered whole (issue #610).
        def final_text(res, text)
          return text if continuation_manager.continuation_buffer.empty?

          raw = res.respond_to?(:text) ? res.text : text
          continuation_manager.stitch_and_reset(Platform.safe_utf8(raw).to_s, history: @inst.history)
        end

        # Same truncation flow as the user channel (issue #610): reasoning
        # that spent the whole output budget gets a targeted continuation
        # nudge instead of the generic empty-response strike. When the
        # auto-continue ceiling is exhausted (or disabled) the partial text
        # already produced is salvaged as the result; with nothing to
        # salvage the turn fails with the actionable diagnostic.
        def handle_truncation(res, text_resp, tool_calls, finish_reason)
          cm = continuation_manager
          return nil unless cm.truncation?(finish_reason)

          raw_text = res.respond_to?(:text) ? res.text : text_resp
          safe_text = Platform.safe_utf8(raw_text).to_s
          action = cm.handle_truncation(
            finish_reason: finish_reason, text_resp: safe_text, tool_calls: tool_calls, res: res,
            max_tokens: @inst.max_output_tokens || 4096
          )
          return continue_truncated(action) if action[:continue]
          return nil unless action[:error]

          salvage_or_fail(cm, safe_text, action[:error])
        end

        # ── announce ──
        def announce_compaction(reason, layer)
          @inst.emit_compacted_event(reason, layer)
        end

        def announce_llm_thought(_text, **) = nil

        # ── terminals & dispatch ──
        # The shared two-strike nudge policy (Channel#empty_response_turn)
        # now governs empty, tool-less responses: one standard nudge row,
        # then the terminal below on the second consecutive strike. The
        # subagent can no longer "complete" with an empty result — the
        # declared Phase 4 delta.
        def continuation_manager
          @continuation_manager ||= ContinuationManager.new(config: @inst.config)
        end

        # Second consecutive empty strike: the run's work is already in
        # history, so deliver the last assistant text as a clearly marked
        # salvaged result instead of an empty failure (issue #610). With
        # nothing to salvage the turn still fails.
        def empty_response_failure
          salvaged = last_assistant_text
          if salvaged
            continuation_manager.reset!
            return final_text_result("#{SALVAGE_NOTICE}\n\n#{salvaged}")
          end

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

        # The assistant row carrying the finish tool_use was already
        # recorded; it needs a pairing tool-result row before
        # complete_turn! or the preserved history hands strict providers
        # an orphaned tool_use on the next request (issue #593 — mirrors
        # StepExecutor#handle_finish_tool and the user channel's deferred
        # finish path).
        def on_finish(args, fallback_text, call_id = nil)
          message = args["message"] || args[:message] || fallback_text || "Completed"
          @inst.auto_apply_buffer!(:finish) unless @inst.workspace == "branch"
          if call_id
            Rubik::Orchestrator::ToolHistory.write(
              @inst.history, tool_call_id: call_id, tool_name: "finish",
                             status: :ok, duration_ms: 0.0, content: message.to_s
            )
          end
          @inst.complete_turn!(message)
          { ok: true, completed: true }
        end

        def execute_tool_call(tool_call, text)
          return on_finish(tool_call["args"] || {}, text, tool_call["id"]) if TurnExecutor.finish_call?(@inst.tool_registry, tool_call)

          @inst.execute_subagent_tool_call(tool_call)
          nil
        end

        private

        def last_assistant_text
          row = @inst.history.reverse_each.find do |m|
            m.is_a?(Hash) && m[:role] == "assistant" && !m[:content].to_s.strip.empty?
          end
          row && row[:content].to_s.strip
        end

        def continue_truncated(action)
          nudge_policy.reset!
          if [:thinking_exhausted, :text_truncated].include?(action[:scenario]) && @inst.respond_to?(:raise_max_output_tokens!)
            @inst.raise_max_output_tokens!(MAX_OUTPUT_TOKENS_CEILING)
          end
          if action[:thought]
            @inst.history << { role: "assistant", content: nil, thought: Platform.safe_utf8(action[:thought]) }
          elsif action[:partial_text]
            @inst.history << { role: "assistant", content: action[:partial_text] }
          end
          @inst.history << { role: "user", content: action[:nudge] }
          :consumed
        end

        def salvage_or_fail(manager, current_text, error)
          accumulated = manager.continuation_buffer + current_text
          if accumulated.strip.empty?
            manager.reset!
            @inst.fail_turn!(error)
            return { ok: false, completed: false }
          end

          manager.absorb_partial_rows!(@inst.history)
          manager.reset!
          final_text_result(accumulated.strip)
        end
      end
    end
  end
end
