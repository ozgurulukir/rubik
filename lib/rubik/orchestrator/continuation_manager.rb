# frozen_string_literal: true

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

      attr_reader :auto_continue_count, :continuation_buffer, :max_auto_continues

      def initialize(config: nil, max_auto_continues: nil)
        @config = config
        @max_auto_continues = (max_auto_continues || safe_config("llm.max_auto_continues", 3)).to_i
        @auto_continue_count = 0
        @continuation_buffer = +""
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
          diag = "⚠️ Model çıktısı maksimum token sınırına (max_output_tokens: #{max_tokens}) ulaştığı için tamamlanamadan kesildi.\n" \
                 "Çözüm: Çıktı token bütçesini artırmak için şu komutu çalıştırabilirsiniz:\n  !config set llm.default_max_output_tokens #{rec}"
          return { continue: false, error: diag }
        end

        if ceiling_reached?
          rec = (max_tokens.to_i * 2).positive? ? max_tokens.to_i * 2 : 8192
          diag = "⚠️ Model çıktısı maksimum token sınırına (max_output_tokens: #{max_tokens}) ulaştığı için " \
                 "ve #{@max_auto_continues} otomatik devam denemesi tükendiği için durduruldu.\n" \
                 "Çözüm: Çıktı token bütçesini artırmak için şu komutu çalıştırabilirsiniz:\n  !config set llm.default_max_output_tokens #{rec}"
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
      # text and resets the continuation state.
      def stitch_and_reset(final_text)
        stitched = if @continuation_buffer.empty?
                     final_text.to_s
                   else
                     @continuation_buffer + final_text.to_s
                   end
        reset!
        stitched
      end

      def reset!
        @auto_continue_count = 0
        @continuation_buffer = +""
      end

      private

      def safe_config(key, default)
        return default unless @config

        if @config.respond_to?(:fetch)
          begin
            val = @config.fetch(key)
            return val unless val.nil?
          rescue KeyError, ArgumentError
            nil
          end
        end

        if key.include?(".") && @config.respond_to?(:dig)
          val = @config.dig(*key.split("."))
          return val unless val.nil?
        end

        if @config.respond_to?(:[])
          val = @config[key]
          return val unless val.nil?
        end

        default
      rescue KeyError, TypeError, NoMethodError
        default
      end
    end
  end
end
