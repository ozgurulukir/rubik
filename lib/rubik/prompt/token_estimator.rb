# frozen_string_literal: true

require "json"
require_relative "../platform"
require_relative "conversation_rows"

module Rubik
  module Prompt
    module TokenEstimator
      CHARS_PER_TOKEN = 3.8

      module_function

      # PERF: Integer math (len * 10 + 37) / 38 avoids Float allocation and division,
      # bit-for-bit identical to (len / 3.8).ceil; direct length avoids .to_s on Strings.
      def estimate_text(text)
        return 0 if text.nil?

        len = text.is_a?(String) ? text.length : text.to_s.length
        return 0 if len.zero?

        ((len * 10) + 37) / 38
      end

      # PERF: Fast-path message token estimator respecting ConversationRows abstraction.
      def estimate_message(msg)
        return 0 unless ConversationRows.row?(msg)

        tokens = 4 # Base message overhead (role delimiter, headers)

        if (role = ConversationRows.value_of(msg, :role))
          tokens += estimate_text(role)
        end

        if (content = ConversationRows.value_of(msg, :content))
          tokens += estimate_text(content)
        end

        if (tool_calls = ConversationRows.value_of(msg, :tool_calls)) && !tool_calls.empty?
          tokens += estimate_text(serialize_for_estimation(tool_calls))
        end

        if (tool_call_id = ConversationRows.value_of(msg, :tool_call_id))
          tokens += estimate_text(tool_call_id)
        end

        if (tool_name = ConversationRows.value_of(msg, :tool_name))
          tokens += estimate_text(tool_name)
        end

        tokens
      end

      def estimate_history(messages)
        return 0 unless messages.is_a?(Array)

        messages.sum { |msg| estimate_message(msg) }
      end

      def estimate_tool_schemas(schemas)
        return 0 if schemas.nil?
        return 0 if schemas.respond_to?(:empty?) && schemas.empty?

        estimate_text(serialize_for_estimation(schemas))
      end

      # PERF: Fast-path JSON generation for tool_calls and tool_schemas estimation.
      # Uses direct JSON.generate to avoid deep clean_utf8 traversal, falling back
      # to Rubik::Platform.safe_json_generate only when malformed UTF-8 raises.
      def serialize_for_estimation(obj)
        return Rubik::Platform.clean_utf8(obj) if obj.is_a?(String)

        begin
          JSON.generate(obj)
        rescue StandardError
          Rubik::Platform.safe_json_generate(obj)
        end
      end
    end
  end
end
