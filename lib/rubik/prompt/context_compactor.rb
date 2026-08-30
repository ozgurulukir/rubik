# frozen_string_literal: true

require_relative "token_estimator"
require_relative "../tools/truncator"

module Rubik
  module Prompt
    module ContextCompactor
      # Plan 61 D-12: single source of truth for the live conversation
      # window cap (TurnRecorder and Session::Manager both use it).
      DEFAULT_MAX_CONVERSATION_ENTRIES = 40

      module_function

      def effective_input_ceiling(context_limit:, max_output_tokens: 4096, safety_margin: 1024)
        [1024, context_limit.to_i - max_output_tokens.to_i - safety_margin.to_i].max
      end

      def needs_compaction?(history, context_limit:, max_output_tokens: 4096, safety_margin: 1024, max_tokens_ratio: 0.85, config: {})
        return false if history.nil? || history.empty?

        ratio = (config["max_tokens_ratio"] || config[:max_tokens_ratio] || max_tokens_ratio || 0.85).to_f
        margin = (config["safety_margin_tokens"] || config[:safety_margin_tokens] || safety_margin || 1024).to_i
        max_out = (config["max_output_tokens"] || config[:max_output_tokens] || max_output_tokens || 4096).to_i

        ceiling = effective_input_ceiling(
          context_limit: context_limit,
          max_output_tokens: max_out,
          safety_margin: margin
        )
        threshold = (ceiling * ratio).to_i
        total_tokens = TokenEstimator.estimate_history(history)
        total_tokens > threshold
      end

      def compact_history(history, context_limit:, max_output_tokens: 4096, safety_margin: 1024, config: {}, force: false)
        return [] if history.nil? || history.empty?

        strategy = (config["compaction_strategy"] || config[:compaction_strategy] || "hybrid").to_s
        return history.map { |m| m.is_a?(Hash) ? m.dup : m } if strategy == "off"

        max_tokens_ratio = (config["max_tokens_ratio"] || config[:max_tokens_ratio] || 0.85).to_f
        tool_result_prune_chars = (config["tool_result_prune_chars"] || config[:tool_result_prune_chars] || 1500).to_i
        preserve_first_n = (config["preserve_first_n"] || config[:preserve_first_n] || 2).to_i
        preserve_last_n = (config["preserve_last_n"] || config[:preserve_last_n] || 6).to_i
        safety_margin = (config["safety_margin_tokens"] || config[:safety_margin_tokens] || safety_margin || 1024).to_i

        ceiling = effective_input_ceiling(
          context_limit: context_limit,
          max_output_tokens: max_output_tokens,
          safety_margin: safety_margin
        )
        threshold = (ceiling * max_tokens_ratio).to_i

        # Return duplicate if under threshold and not forced
        if !force && TokenEstimator.estimate_history(history) <= threshold
          return history.map { |m| m.is_a?(Hash) ? m.dup : m }
        end

        compacted = history.map { |m| m.is_a?(Hash) ? m.dup : m }

        # Strategy: prune_tool_results or hybrid (Phase 1: Pruning intermediate tool results)
        if ["hybrid", "prune_tool_results"].include?(strategy)
          compacted = prune_intermediate_tool_results(
            compacted,
            preserve_first_n: preserve_first_n,
            preserve_last_n: preserve_last_n,
            max_chars: tool_result_prune_chars
          )

          return compacted if strategy == "prune_tool_results" || (!force && TokenEstimator.estimate_history(compacted) <= threshold)
        end

        # Strategy: sliding_window or hybrid (Phase 2: Collapsing intermediate atomic units)
        if ["hybrid", "sliding_window"].include?(strategy)
          compacted = apply_sliding_window(
            compacted,
            threshold: threshold,
            preserve_first_n: preserve_first_n,
            preserve_last_n: preserve_last_n,
            force: force
          )
        end

        compacted
      end

      def prune_intermediate_tool_results(history, preserve_first_n:, preserve_last_n:, max_chars:)
        return history if history.size <= preserve_first_n + preserve_last_n

        first_end_idx = preserve_first_n
        last_start_idx = [history.size - preserve_last_n, first_end_idx].max

        history.each_with_index do |msg, idx|
          next unless idx >= first_end_idx && idx < last_start_idx
          next unless msg.is_a?(Hash)

          role = (msg[:role] || msg["role"]).to_s
          next unless ["tool", "tool_result"].include?(role)

          content_key = msg.key?(:content) ? :content : "content"
          content = msg[content_key].to_s
          if content.length > max_chars
            trunc = Rubik::Tools::Truncator.truncate(content, max_chars: max_chars, strategy: :head_tail)
            msg[content_key] = trunc[:text]
          end
        end

        history
      end

      def group_atomic_units(history)
        units = []
        i = 0
        while i < history.size
          msg = history[i]
          role = (msg[:role] || msg["role"]).to_s
          tool_calls = msg[:tool_calls] || msg["tool_calls"]

          if role == "assistant" && tool_calls && !tool_calls.empty?
            unit = [msg]
            j = i + 1
            while j < history.size
              next_msg = history[j]
              next_role = (next_msg[:role] || next_msg["role"]).to_s
              break unless ["tool", "tool_result"].include?(next_role)

              unit << next_msg
              j += 1

            end
            units << unit
            i = j
          else
            units << [msg]
            i += 1
          end
        end
        units
      end

      def apply_sliding_window(history, threshold:, preserve_first_n:, preserve_last_n:, force: false) # rubocop:disable Lint/UnusedMethodArgument -- arayüz uyumluluğu için force korunuyor
        units = group_atomic_units(history)
        return history if units.size <= 2

        # Determine head units (covering at least preserve_first_n messages)
        head_units = []
        head_msg_count = 0
        head_idx = 0
        while head_idx < units.size && head_msg_count < preserve_first_n
          head_units << units[head_idx]
          head_msg_count += units[head_idx].size
          head_idx += 1
        end

        # Determine tail units (covering at least preserve_last_n messages)
        tail_units = []
        tail_msg_count = 0
        tail_idx = units.size - 1
        while tail_idx >= head_idx && tail_msg_count < preserve_last_n
          tail_units.unshift(units[tail_idx])
          tail_msg_count += units[tail_idx].size
          tail_idx -= 1
        end

        intermediate_units = (head_idx..tail_idx).map { |idx| units[idx] }
        return history if intermediate_units.empty?

        dropped_units = []
        remaining_intermediates = intermediate_units.dup

        # Plan 61 D-9: drop first, THEN measure — the previous loop measured
        # the candidate before shifting, so it could drop one unit too many.
        until remaining_intermediates.empty?
          dropped_units << remaining_intermediates.shift
          candidate = head_units.flatten + [summary_message(dropped_units.flatten.size)] + remaining_intermediates.flatten + tail_units.flatten
          break if TokenEstimator.estimate_history(candidate) <= threshold
        end

        result = if dropped_units.empty?
                   history
                 else
                   head_units.flatten + [summary_message(dropped_units.flatten.size)] + remaining_intermediates.flatten + tail_units.flatten
                 end

        # Unit dropping cannot shrink a single oversized user turn —
        # hard-trim the largest remaining plain messages if still over.
        result = trim_oversized_messages(result, threshold: threshold) if TokenEstimator.estimate_history(result) > threshold
        result
      end

      # Plan 61 D-9: last-resort in-place shortening of the largest
      # user/assistant messages when structural dropping is not enough.
      def trim_oversized_messages(history, threshold:, min_len: 2000, max_passes: 10)
        max_passes.times do
          break if TokenEstimator.estimate_history(history) <= threshold

          candidates = history.each_index.select { |i| history[i].is_a?(Hash) }
          eligible = candidates.select do |i|
            role = (history[i][:role] || history[i]["role"]).to_s
            content = history[i][:content] || history[i]["content"]
            ["user", "assistant"].include?(role) && content.to_s.length > min_len
          end
          idx = eligible.max_by { |i| (history[i][:content] || history[i]["content"]).to_s.length }
          break if idx.nil?

          content_key = history[idx].key?(:content) ? :content : "content"
          str = history[idx][content_key].to_s
          trunc = Rubik::Tools::Truncator.truncate(str, max_chars: str.length / 2, max_lines: 10_000, strategy: :head_tail)
          history[idx][content_key] = trunc[:text]
        end
        history
      end

      # Plan 61 D-12: token-aware rolling window for the long-lived REPL
      # conversation history. Drops the oldest entries until the estimate
      # fits the ceiling; max_entries is an absolute cap; the most recent
      # min_entries messages always survive. The window is guaranteed to
      # open with a user turn — strict providers (Anthropic) require it.
      def trim_history_to_budget(history, ceiling:, max_entries: nil, min_entries: 4)
        return history if history.nil? || history.empty?

        trimmed = history
        trimmed = trimmed.last(max_entries) if max_entries&.positive? && trimmed.size > max_entries

        limit = ceiling&.positive? ? ceiling : nil
        trimmed = trimmed.last(trimmed.size - 1) while limit && trimmed.size > min_entries && TokenEstimator.estimate_history(trimmed) > limit

        trimmed = trimmed.last(trimmed.size - 1) while trimmed.size > 1 && (trimmed.first[:role] || trimmed.first["role"]).to_s != "user"
        trimmed
      end

      # Plan 61 D-9: role is "user" (not "system") — strict providers reject
      # or relocate mid-conversation system messages; the tag text is kept
      # stable for downstream recognition.
      def summary_message(dropped_count)
        {
          role: "user",
          content: "<compacted_summary count=\"#{dropped_count}\" " \
                   "message=\"#{dropped_count} intermediate conversation messages and tool execution steps were collapsed to stay within token limits.\" />"
        }
      end
    end
  end
end
