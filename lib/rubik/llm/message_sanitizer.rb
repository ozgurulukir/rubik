# frozen_string_literal: true

require_relative "../prompt/conversation_rows"

module Rubik
  module LLM
    # Normalizes internal message histories into provider-safe shapes
    # (Plan 61 D-6). Strict endpoints (Anthropic Messages API, some
    # OpenAI-compatible gateways) reject histories with consecutive
    # same-role turns — which this runtime can produce through compaction
    # summaries, notification messages and restored sessions.
    #
    # Rules:
    # * Consecutive plain same-role messages are folded together with a
    #   blank-line join (user+user, assistant+assistant, system+system).
    # * An assistant message carrying tool_calls always starts a new unit
    #   (it pairs with the following role:"tool" results).
    # * role:"tool" messages are never merged — each carries its own
    #   tool_call_id; strict providers coalesce them at format time.
    module MessageSanitizer
      module_function

      def normalize(messages)
        return [] if messages.nil?

        merged = []
        messages.each do |msg|
          unless Prompt::ConversationRows.row?(msg)
            Rubik::Platform.debug_warn("MessageSanitizer: dropping non-hash message #{msg.inspect}")
            next
          end

          role = Prompt::ConversationRows.role_of(msg)
          prev = merged.last
          if mergeable?(prev, role, msg)
            merge_into!(prev, msg)
          else
            merged << msg.dup
          end
        end
        merged
      end

      def mergeable?(prev, role, msg)
        return false if prev.nil? || prev.empty?
        return false if Prompt::ConversationRows.role_of(prev) != role
        return false if role == "tool" || role.empty?

        # An assistant message carrying tool_calls always opens a fresh
        # atomic unit — folding it into the previous turn would break the
        # tool_calls → tool results pairing.
        current_tcs = msg[:tool_calls] || msg["tool_calls"]
        return false if role == "assistant" && current_tcs.is_a?(Array) && !current_tcs.empty?

        true
      end

      def merge_into!(prev, msg)
        content_key = Prompt::ConversationRows.content_key_of(prev)
        prev[content_key] = join_content(prev[content_key], Prompt::ConversationRows.content_of(msg))

        tcs = msg[:tool_calls] || msg["tool_calls"]
        return if tcs.nil? || (tcs.is_a?(Array) && tcs.empty?)

        tc_key = Prompt::ConversationRows.resolve_key(prev, :tool_calls)
        prev[tc_key] = Array(prev[tc_key] || []) + Array(tcs)
      rescue StandardError => e
        # Warn once per process: normalize runs on every provider call, so an
        # unguarded warn would spam one line per message for a poisoned history.
        unless @merge_failure_warned
          @merge_failure_warned = true
          Rubik::Log.warn(:llm, "message merge failed (#{e.class}: #{e.message}); tool_calls/content may be dropped")
        end
        nil
      end

      def join_content(first, second)
        first_str = first.to_s
        second_str = second.to_s
        return second_str if first_str.strip.empty?
        return first_str if second_str.strip.empty?

        "#{first_str}\n\n#{second_str}"
      end
    end
  end
end
