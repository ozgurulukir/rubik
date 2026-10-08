# frozen_string_literal: true

require "json"
require_relative "../platform"
require_relative "conversation_rows"

module Rubik
  module Prompt
    module TokenEstimator
      CHARS_PER_TOKEN = 3.8

      module_function

      def estimate_text(text)
        return 0 if text.nil?

        str = text.to_s
        return 0 if str.empty?

        (str.length / CHARS_PER_TOKEN).ceil
      end

      def estimate_message(msg)
        return 0 unless ConversationRows.row?(msg)

        tokens = 4 # Base message overhead (role delimiter, headers)
        role = ConversationRows.value_of(msg, :role)
        tokens += estimate_text(role) if role

        content = ConversationRows.value_of(msg, :content)
        tokens += estimate_text(content) if content

        tool_calls = msg[:tool_calls] || msg["tool_calls"]
        if tool_calls && !tool_calls.empty?
          tool_calls_str = tool_calls.is_a?(String) ? Rubik::Platform.clean_utf8(tool_calls) : Rubik::Platform.safe_json_generate(tool_calls)
          tokens += estimate_text(tool_calls_str)
        end

        tool_call_id = msg[:tool_call_id] || msg["tool_call_id"]
        tokens += estimate_text(tool_call_id) if tool_call_id

        tool_name = msg[:tool_name] || msg["tool_name"]
        tokens += estimate_text(tool_name) if tool_name

        tokens
      end

      def estimate_history(messages)
        return 0 unless messages.is_a?(Array)

        messages.sum { |msg| estimate_message(msg) }
      end

      def estimate_tool_schemas(schemas)
        return 0 if schemas.nil?
        return 0 if schemas.respond_to?(:empty?) && schemas.empty?

        json_str = schemas.is_a?(String) ? Rubik::Platform.clean_utf8(schemas) : Rubik::Platform.safe_json_generate(schemas)
        estimate_text(json_str)
      end
    end
  end
end
