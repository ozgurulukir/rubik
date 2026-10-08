# frozen_string_literal: true

require_relative "token_estimator"
require_relative "conversation_rows"
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
        return history.map { |m| ConversationRows.row?(m) ? m.dup : m } if strategy == "off"

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
          return history.map { |m| ConversationRows.row?(m) ? m.dup : m }
        end

        compacted = history.map { |m| ConversationRows.row?(m) ? m.dup : m }

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
          next unless ConversationRows.row?(msg)

          role = ConversationRows.role_of(msg)
          next unless ["tool", "tool_result"].include?(role)

          # A loaded skill body is the task's standing instruction payload
          # (progressive disclosure), not intermediate output — pruning it to
          # max_chars mid-task would silently amputate the agent's orders.
          # The sliding-window phase may still drop it under genuine token
          # emergency; the <skills> index lets the agent re-invoke `skill`.
          next if (msg[:tool_name] || msg["tool_name"]) == Rubik::Tools::SkillTool::NAME

          content_key = ConversationRows.content_key_of(msg)
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
          role = ConversationRows.role_of(msg)
          tool_calls = msg[:tool_calls] || msg["tool_calls"]

          if role == "assistant" && tool_calls && !tool_calls.empty?
            unit = [msg]
            j = i + 1
            while j < history.size
              next_msg = history[j]
              next_role = ConversationRows.role_of(next_msg)
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

      # Hedef mesajı mı? <user_task> sarmalayıcısını yalnızca
      # ContextBuilder.format_user_task üretir — goal/plan döngülerinin görev
      # bildirgesi. Açılış+kapanış etiketi birlikte aranır: kullanıcı
      # mesajına alıntılanmış yalnızca açılış etiketi yapıştırmak mesajı
      # kalıcı olarak sabitleyip düşürülemez/devrilinemez hale getirirdi.
      # String/symbol anahtar farkı umursanmaz.
      def goal_message?(msg)
        return false unless ConversationRows.row?(msg)

        role = ConversationRows.role_of(msg)
        content = ConversationRows.content_of(msg).to_s
        role == "user" && content.include?("<user_task>") && content.include?("</user_task>")
      end

      def unit_pins_goal?(unit)
        unit.any? { |msg| goal_message?(msg) }
      end

      def apply_sliding_window(history, threshold:, preserve_first_n:, preserve_last_n:, force: false) # rubocop:disable Lint/UnusedMethodArgument -- arayüz uyumluluğu için force korunuyor
        units = group_atomic_units(history)
        return history if units.size <= 2

        # Hedef sabitleme: <user_task> taşıyan birimler ARA birim olsa bile
        # asla düşürülemez ve trim edilemez — model hedefini koşu ortasında
        # kaybetmesin. Normal ve emergency yolların ikisi de compact_history
        # üzerinden buraya akar. Birden çok <user_task> (run yeniden girişi)
        # özgün sırasıyla sabitlenir.
        pinned = units.map { |unit| unit_pins_goal?(unit) }

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

        intermediate_indexes = (head_idx..tail_idx).to_a
        return history if intermediate_indexes.empty?

        # Sabitlenmiş birimler düşürülemeyeceğinden droppable kuyruğundan
        # çıkarılır; yalnızca kalanlar (en eskiden yeniye) düşürülür.
        droppable = intermediate_indexes.reject { |idx| pinned[idx] }
        return history if droppable.empty?

        dropped_indexes = []
        remaining = droppable.dup
        # Plan 61 D-9: drop first, THEN measure — the previous loop measured
        # the candidate before shifting, so it could drop one unit too many.
        until remaining.empty?
          dropped_indexes << remaining.shift
          break if TokenEstimator.estimate_history(assemble_window(units, dropped_indexes)) <= threshold
        end

        result = assemble_window(units, dropped_indexes)

        # Unit dropping cannot shrink a single oversized user turn —
        # hard-trim the largest remaining plain messages if still over.
        # Sabitlenmiş hedef mesajları bu katmandan muaf tut.
        if TokenEstimator.estimate_history(result) > threshold
          pinned_indexes = result.each_index.select { |i| goal_message?(result[i]) }
          result = trim_oversized_messages(result, threshold: threshold, pinned_indexes: pinned_indexes)
        end
        result
      end

      # Birimleri özgün sıralarında (düşürülenler hariç) birleştirir ve
      # <compacted_summary>'yi İLK düşürülen birimin konumuna yerleştirir.
      # Sabitleme yoksa ilk düşürme her zaman ilk ara birimdir → yerleşim,
      # eski "head + summary + rest" düzeniyle bire bir aynıdır.
      def assemble_window(units, dropped_indexes)
        first_drop = dropped_indexes.min
        result = []
        summary_slot = nil
        units.each_with_index do |unit, idx|
          summary_slot = result.size if idx == first_drop
          result.concat(unit) unless dropped_indexes.include?(idx)
        end
        dropped_msg_count = dropped_indexes.sum { |i| units[i].size }
        result.insert(summary_slot || result.size, summary_message(dropped_msg_count))
        result
      end

      # Plan 61 D-9: last-resort in-place shortening of the largest
      # user/assistant messages when structural dropping is not enough.
      # pinned_indexes (hedef <user_task> mesajları) bu katmandan muaftır.
      def trim_oversized_messages(history, threshold:, min_len: 2000, max_passes: 10, pinned_indexes: [])
        max_passes.times do
          break if TokenEstimator.estimate_history(history) <= threshold

          candidates = history.each_index.select { |i| ConversationRows.row?(history[i]) && !pinned_indexes.include?(i) }
          eligible = candidates.select do |i|
            role = ConversationRows.role_of(history[i])
            content = ConversationRows.content_of(history[i])
            ["user", "assistant"].include?(role) && content.to_s.length > min_len
          end
          idx = eligible.max_by { |i| ConversationRows.content_of(history[i]).to_s.length }
          break if idx.nil?

          content_key = ConversationRows.content_key_of(history[idx])
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

        trimmed = trimmed.last(trimmed.size - 1) while trimmed.size > 1 && ConversationRows.role_of(trimmed.first) != "user"
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
