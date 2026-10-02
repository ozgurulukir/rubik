# frozen_string_literal: true

require "json"
require_relative "tool_call_id"
require_relative "provider_recovery"

module Rubik
  module Orchestrator
    # THE shared response-processing spine for both agent channels (the
    # agent-turn-executor plan): Loop (user channel) and Subagent::StepRunner
    # (subagent channel) become thin parameterizations of this executor —
    # neither carries its own copy of "one provider response → history
    # mutations → (nudge | final text | tool dispatch) → turn decision".
    #
    # Stateless-per-call: one instance per channel, built lazily by its
    # owner (the provider_resolver precedent keeps Class#allocate-built
    # test doubles working). Channel policy lives in the adapters (Channel
    # base + UserChannel + SubagentChannel); request assembly stays
    # channel-native on purpose — stream vs batch and their recovery stacks
    # genuinely differ, so the channel hands the executor the raw response
    # and ProviderRecovery keeps wrapping the provider CALL at its three
    # sites. The compaction actuator it drives (emergency_compact!) has
    # exactly one home: here.
    class TurnExecutor
      class << self
        # JSON-text tool-call fallback (Plan 61): a non-tool-native model's
        # JSON reply parses to one tool call. Degenerate model text — a
        # bare "```json" fence, an empty fence, or a valid-JSON non-object
        # — degrades to nil (no tool call; the text is treated as output)
        # instead of raising into the step loop: fallback text is
        # model-controlled, so the same bounded policy as parse_json_args
        # applies.
        def parse_tool_call(text)
          cleaned = text.to_s.gsub("\\n", "\n")
          json_str = if cleaned.include?("```json")
                       cleaned.split("```json").last.to_s.split("```").first.to_s.strip
                     elsif cleaned.start_with?("{") && cleaned.end_with?("}")
                       cleaned
                     end
          return nil if json_str.nil? || json_str.empty?

          parsed = JSON.parse(json_str)
          parsed.is_a?(Hash) ? parsed : nil
        rescue JSON::ParserError
          nil
        end

        def extract_finish_reason(res)
          return nil unless res.respond_to?(:raw) && res.raw.is_a?(Hash)

          raw = res.raw
          raw["finish_reason"] || raw.dig("choices", 0, "finish_reason") ||
            raw["stop_reason"] || raw.dig("delta", "stop_reason") || raw["done_reason"]
        end

        # Registry-canonical finish detection: a call is the finish call when
        # the registry resolves it to the finish tool — an unregistered case
        # variant ("Finish") downcases to finish instead of dispatching an
        # unknown tool. A nil registry degrades to the downcase compare.
        def finish_call?(tool_registry, tool_call)
          t_name = tool_call["tool"] || tool_call[:tool]
          resolved = tool_registry.respond_to?(:get) ? tool_registry.get(t_name) : nil
          (resolved ? resolved.name : t_name.to_s.downcase) == "finish"
        end
      end

      def initialize(channel:)
        @channel = channel
      end

      attr_reader :channel

      # Channel-owned counter (Loop's public empty_response_count reader
      # delegates here).
      def nudge_policy = channel.nudge_policy

      # Per-run reset of channel-owned counters (empty-response strikes).
      def reset!
        channel.nudge_policy.reset!
      end

      # THE seam. Processes one provider response: normalize tool calls
      # (native + JSON fallback, channel-minted ids), truncation hook,
      # plan-mode branch, empty-nudge, assistant row, finish detection,
      # tool-dispatch loop.
      #
      # Returns nil to continue the step loop, or the terminal Hash (the
      # channel's own result contract) to stop it.
      def call(res, plan_only: false)
        channel.track_usage(res)

        text_resp = channel.response_text(res).to_s.strip
        tool_calls = normalize_tool_calls(res, text_resp)

        handled = channel.handle_truncation(res, text_resp, tool_calls, self.class.extract_finish_reason(res).to_s)
        return nil if handled == :consumed
        return handled if handled.is_a?(Hash)

        return plan_turn(res, text_resp) if plan_only
        return text_turn(res, text_resp) if tool_calls.empty?

        tool_turn(res, text_resp, tool_calls)
      end

      # Emergency compaction, ONE home for both channels: the compaction
      # math stays in Prompt::EmergencyCompactor.compact!, the announce is
      # channel-parameterized. Returns the layer that produced the final
      # history (the Loop seam's documented contract).
      def emergency_compact!(reason)
        limits = channel.limits
        layer = Rubik::Prompt::EmergencyCompactor.compact!(
          channel.history, context_limit: limits[:context_limit], max_output_tokens: limits[:max_output_tokens],
                           config: ProviderRecovery.compaction_config(limits[:config])
        )
        channel.announce_compaction(reason, layer)
        layer
      end

      private

      # One shared normalizer for both channels (wire-identical: every
      # provider path already emits string-keyed {"id","tool","args"} —
      # ChunkAssembler and the three batch providers). Builds fresh
      # normalized hashes with a channel-minted id per call; the JSON-text
      # fallback (Plan 61) parses a non-native model's JSON reply into one
      # call.
      def normalize_tool_calls(res, text_resp)
        raw_calls = channel.raw_tool_calls(res).to_a
        if raw_calls.empty?
          parsed = self.class.parse_tool_call(text_resp)
          raw_calls = parsed ? [parsed] : []
        end

        raw_calls.map.with_index do |tc, idx|
          id = tc["id"] || tc[:id] || channel.mint_call_id(idx)
          name = tc["tool"] || tc[:tool] || tc["name"] || tc[:name]
          args = tc["args"] || tc[:args] || tc["arguments"] || tc[:arguments] || {}
          args = parse_json_args(args) if args.is_a?(String)
          args = {} unless args.is_a?(Hash)
          { "id" => id, "tool" => name, "args" => args }
        end
      end

      # Fallback text is model-controlled: malformed JSON args degrade to {}
      # (dispatch then produces the unknown/invalid-tool row — bounded, one
      # wasted step) instead of crashing the turn; a valid-JSON non-object
      # degrades the same way. The provider-layer parses this mirrors
      # (chunk_assembler, ollama) additionally fire a :malformed_tool_args
      # diagnostics event on the streaming path — the executor-level path
      # intentionally omits that hook; the dispatch row is the only trace.
      def parse_json_args(raw)
        parsed = JSON.parse(raw)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      def plan_turn(res, text_resp)
        return channel.empty_response_turn(res, channel.plan_nudge_message) if text_resp.empty?

        final_text_turn(res, text_resp)
      end

      def text_turn(res, text_resp)
        return channel.empty_response_turn(res) if text_resp.empty?

        final_text_turn(res, text_resp)
      end

      def final_text_turn(res, text_resp)
        channel.nudge_policy.reset!
        channel.final_text_result(channel.final_text(res, text_resp))
      end

      def tool_turn(res, text_resp, tool_calls)
        channel.nudge_policy.reset!
        channel.append_tool_call_row(channel.final_text(res, text_resp), tool_calls)
        channel.announce_llm_thought(text_resp) if !text_resp.empty? && tool_calls.none? { |tc| self.class.finish_call?(channel.tool_registry, tc) }

        tool_calls.each do |tc|
          result = channel.execute_tool_call(tc, text_resp)
          return result if result
        end
        nil
      end

      # The per-channel policy adapter. Base class carries the shared
      # mechanics with no-op defaults where a channel legitimately has
      # nothing to do; channel-specific terminals raise
      # NotImplementedError — a missing terminal is a construction bug,
      # not a runtime condition (fail loud at the boundary).
      class Channel
        # ── nudge policy (channel-owned so the owner's accessor delegates) ──
        def nudge_policy
          @nudge_policy ||= NudgePolicy.new
        end

        # Default empty-response policy: the shared two-strike nudge. One
        # nudge row per empty, tool-less response; terminal failure on the
        # second consecutive strike.
        def empty_response_turn(res, nudge_message = empty_nudge_message(res))
          count = nudge_policy.register_empty!
          return empty_response_failure if nudge_policy.strike?(count)

          history << { role: "user", content: nudge_message }
          nil
        end

        # ── required state ──
        def history = raise NotImplementedError, "channel must expose the mutable conversation history"

        def tool_registry = nil

        def limits
          raise NotImplementedError, "channel must expose { context_limit:, max_output_tokens:, config: }"
        end

        def mint_call_id(_idx)
          raise NotImplementedError,
                "channel must mint ToolCallId ids (unique vs deterministic is per-channel doctrine)"
        end

        # ── response shaping ──
        # The channel's native tool-call source from a raw provider
        # response. Main: the Response#tool_calls? predicate gates access;
        # the subagent's Struct/duck mock providers expose the array
        # attribute directly, so that channel overrides this hook.
        def raw_tool_calls(res)
          res.respond_to?(:tool_calls?) && res.tool_calls? ? res.tool_calls : []
        end

        def response_text(res) = res.text.to_s

        def final_text(_res, text) = text

        def track_usage(_res) = nil

        # -> nil (not applicable) | :consumed (rows+nudge appended; executor
        # continues) | Hash (terminal error).
        def handle_truncation(_res, _text, _tool_calls, _finish_reason) = nil

        # ── nudge texts ──
        def empty_nudge_message(_res) = "Your last response was empty. Continue the task or call the finish tool."

        def plan_nudge_message
          "Plan mode: tool calls are disabled. Respond with the numbered implementation plan as plain text."
        end

        # ── announce ──
        def announce_compaction(_reason, _layer) = nil

        def announce_llm_thought(_text) = nil

        # ── terminals & dispatch ──
        def empty_response_failure
          raise NotImplementedError, "channel must build its terminal empty-response failure Hash"
        end

        def final_text_result(_final_text)
          raise NotImplementedError, "channel must build its text-completion terminal Hash"
        end

        def append_tool_call_row(_final_text, _tool_calls)
          raise NotImplementedError, "channel must append the assistant tool-call row"
        end

        def on_finish(_args, _fallback_text)
          raise NotImplementedError, "channel must implement its finish semantics"
        end

        def execute_tool_call(_tool_call, _text)
          raise NotImplementedError, "channel must dispatch tool calls"
        end
      end

      # Two-strike empty-response counter, channel-owned so the owner
      # object (Loop) can delegate its public reader.
      class NudgePolicy
        DEFAULT_STRIKE_LIMIT = 2

        attr_reader :strike_limit, :count

        def initialize(strike_limit = DEFAULT_STRIKE_LIMIT)
          @strike_limit = strike_limit
          @count = 0
        end

        # Registers one empty response and returns the running count.
        def register_empty!
          @count += 1
        end

        def reset!
          @count = 0
        end

        def strike?(count = @count)
          count >= @strike_limit
        end
      end
    end
  end
end
