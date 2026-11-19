# frozen_string_literal: true

require_relative "../storage/layout"

module Rubik
  module Orchestrator
    # Manages auto-continuation when an LLM response is truncated due to
    # reaching max_output_tokens (finish_reason == "length" or "max_tokens").
    #
    # Responsible for:
    # 1. Distinguishing between reasoning/thinking exhaustion (empty text)
    #    and content truncation (mid-sentence cut-off).
    # 2. Buffering and stitching partial text across continuation turns.
    # 3. Generating targeted, non-repetitive continuation prompts.
    # 4. Enforcing the max_auto_continues safety ceiling to prevent runaways.
    class ContinuationManager
      TRUNCATION_REASONS = ["length", "max_tokens"].freeze

      # The continuation nudges handle_truncation appends right after each
      # partial row; they anchor absorb_partial_rows! to the genuine partial
      # positions (issue #595-1 follow-up). Keep in sync with the nudge
      # strings inside handle_truncation.
      NUDGE_PREFIXES = [
        "Your thinking process reached the output token limit",
        "Your previous response was cut off",
        "Your tool call was cut off"
      ].freeze

      attr_reader :auto_continue_count, :continuation_buffer, :max_auto_continues

      def initialize(config: nil, max_auto_continues: nil)
        @config = config
        @max_auto_continues = (max_auto_continues || safe_config("llm.max_auto_continues", 3)).to_i
        @auto_continue_count = 0
        @continuation_buffer = +""
        # The exact partial texts appended to history per text-truncation
        # cycle (issue #595-1): the stitch/failure paths absorb their
        # assistant rows so the history carries the full text ONCE.
        @partial_texts = []
      end

      def enabled?
        return true if @config.nil?

        safe_config("llm.auto_continue_on_length", true) == true
      end

      def truncation?(finish_reason)
        TRUNCATION_REASONS.include?(finish_reason.to_s.downcase)
      end

      def ceiling_reached?
        @auto_continue_count >= @max_auto_continues
      end

      # Classifies the truncation scenario:
      # - :thinking_exhausted when text and tools are empty (budget spent on thought)
      # - :text_truncated when partial text was produced
      # - :tool_truncated when partial tool call was being assembled
      def classify_truncation(text_resp, tool_calls, _res = nil)
        if tool_calls.empty?
          if text_resp.to_s.strip.empty?
            :thinking_exhausted
          else
            :text_truncated
          end
        else
          # Tool call was partially assembled or arguments broken due to cut-off
          :tool_truncated
        end
      end

      # Handles a truncation event.
      # Returns a Hash:
      #   { continue: true, nudge: "...", step_event: {...} }
      # or
      #   { continue: false, error: "..." } if ceiling reached or disabled.
      def handle_truncation(finish_reason:, text_resp:, tool_calls:, res: nil, max_tokens: 4096)
        return { continue: false } unless truncation?(finish_reason)

        unless enabled?
          rec = (max_tokens.to_i * 2).positive? ? max_tokens.to_i * 2 : 8192
          diag = "⚠️ Model output reached the maximum token limit (max_output_tokens: #{max_tokens}) and was cut off before completion.\n" \
                 "Solution: To increase the output token budget, you can run the following command:\n  !config set llm.default_max_output_tokens #{rec}"
          return { continue: false, error: diag }
        end

        if ceiling_reached?
          rec = (max_tokens.to_i * 2).positive? ? max_tokens.to_i * 2 : 8192
          diag = "⚠️ Model output reached the maximum token limit (max_output_tokens: #{max_tokens}) and " \
                 "the #{@max_auto_continues} automatic continue attempts were exhausted, so it was stopped.\n" \
                 "Solution: To increase the output token budget, you can run the following command:\n  !config set llm.default_max_output_tokens #{rec}"
          return { continue: false, error: diag }
        end

        scenario = classify_truncation(text_resp, tool_calls, res)
        @auto_continue_count += 1

        case scenario
        when :thinking_exhausted
          {
            continue: true,
            scenario: :thinking_exhausted,
            nudge: "Your thinking process reached the output token limit before producing a response or tool call. " \
                   "Do not repeat your reasoning; immediately provide your final response or invoke the necessary tool call concisely.",
            thought: res.respond_to?(:thought) ? res.thought : nil,
            step_event: { type: :auto_continue, reason: :thinking_exhausted, count: @auto_continue_count, max: @max_auto_continues }
          }
        when :text_truncated
          @continuation_buffer << text_resp.to_s
          @partial_texts << text_resp.to_s
          {
            continue: true,
            scenario: :text_truncated,
            partial_text: text_resp.to_s,
            nudge: "Your previous response was cut off because it reached the output token limit. " \
                   "Continue directly and seamlessly from the exact character/code line where you stopped. " \
                   "Do not repeat previous text or restart.",
            step_event: { type: :auto_continue, reason: :text_truncated, count: @auto_continue_count, max: @max_auto_continues }
          }
        when :tool_truncated
          {
            continue: true,
            scenario: :tool_truncated,
            nudge: "Your tool call was cut off due to the output token limit. Please re-invoke the tool call directly with concise arguments.",
            step_event: { type: :auto_continue, reason: :tool_truncated, count: @auto_continue_count, max: @max_auto_continues }
          }
        end
      end

      # Stitches any accumulated continuation buffer with the final response
      # text and resets the continuation state. When `history` is given, the
      # partial assistant rows appended per continuation cycle are absorbed
      # FIRST (issue #595-1): the stitched full text replaces them instead
      # of duplicating every partial.
      def stitch_and_reset(final_text, history: nil)
        absorb_partial_rows!(history) if history
        stitched = if @continuation_buffer.empty?
                     final_text.to_s
                   else
                     @continuation_buffer + final_text.to_s
                   end
        reset!
        stitched
      end

      # Absorbs the partial assistant rows recorded across continuation
      # cycles out of the given history (issue #595-1/#595-2). Anchoring
      # (#595-1 follow-up): a partial row is always the assistant row
      # immediately preceding its own continuation nudge, so matching is
      # restricted to that position — content equality alone would also
      # delete an unrelated earlier assistant row that coincidentally
      # repeats a partial verbatim.
      def absorb_partial_rows!(history)
        @partial_texts.each do |partial|
          history.each_index do |i|
            row = history[i]
            next unless row.is_a?(Hash)
            next unless continuation_nudge_row?(history[i + 1])

            role = row[:role] || row["role"]
            tool_calls = row[:tool_calls] || row["tool_calls"]
            content = row[:content] || row["content"]
            history[i] = nil if role == "assistant" && tool_calls.nil? && content == partial
          end
          history.compact!
        end
      end

      # The continuation nudges appended right after each partial row are
      # the anchor markers (handle_truncation is the only writer).
      def continuation_nudge_row?(row)
        return false unless row.is_a?(Hash)

        content = (row[:content] || row["content"]).to_s
        (row[:role] || row["role"]) == "user" && NUDGE_PREFIXES.any? { |prefix| content.start_with?(prefix) }
      end

      def reset!
        @auto_continue_count = 0
        @continuation_buffer = +""
        @partial_texts = []
      end

      # A successful turn closes the *consecutive* truncation chain, so the
      # ceiling must start over (issue #549). The partial text buffer is NOT
      # cleared here: stitch_and_reset owns that, and dropping it on a tool
      # turn would lose the already-generated answer. Only the strike count
      # is reset.
      def reset_strikes!
        @auto_continue_count = 0
      end

      private

      def safe_config(key, default)
        Rubik::Storage::Layout.config_get(@config, key, default)
      rescue KeyError, TypeError, NoMethodError
        default
      end
    end
  end
end
