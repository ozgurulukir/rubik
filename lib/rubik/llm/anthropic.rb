# frozen_string_literal: true

require_relative "provider"
require_relative "client"
require_relative "formatter"

module Rubik
  module LLM
    class AnthropicProvider < BaseProvider
      attr_reader :model, :formatter

      def initialize(model: "claude-3-7-sonnet-20250219", formatter: AnthropicFormatter.new)
        @model = model
        @formatter = formatter || AnthropicFormatter.new
      end

      def complete(messages, opts = {})
        api_key = ENV["ANTHROPIC_API_KEY"]
        raise ClientError, "ANTHROPIC_API_KEY environment variable is not set" if api_key.nil? || api_key.empty?

        target_model = opts[:model] || @model
        endpoint = "https://api.anthropic.com/v1/messages"

        headers = {
          "x-api-key" => api_key,
          "anthropic-version" => "2023-06-01"
        }

        # Anthropic requires system prompt to be at top level payload, not in messages array
        system_msgs = messages.select { |m| m[:role] == "system" || m["role"] == "system" }
        user_msgs = messages.reject { |m| m[:role] == "system" || m["role"] == "system" }

        system_text = system_msgs.map { |m| m[:content] || m["content"] }.join("\n\n")

        payload = {
          model: target_model,
          messages: format_messages(user_msgs),
          max_tokens: opts[:max_tokens] || 1024
        }
        payload[:system] = system_text unless system_text.empty?

        if opts[:tools] && !opts[:tools].empty?
          payload[:tools] = format_tools(opts[:tools])
        end

        res_json = HTTPClient.post_json(endpoint, headers: headers, payload: payload)

        content_blocks = res_json["content"] || []
        text_blocks = content_blocks.select { |b| b["type"] == "text" }.map { |b| b["text"] }
        text = text_blocks.join("\n")

        tool_blocks = content_blocks.select { |b| b["type"] == "tool_use" }
        parsed_tool_calls = tool_blocks.map do |b|
          {
            "id" => b["id"] || "call_#{rand(1000..9999)}",
            "tool" => b["name"],
            "args" => b["input"] || {}
          }
        end

        usage = res_json["usage"] || {}

        Response.new(
          text: text,
          usage: {
            input_tokens: usage["input_tokens"] || 0,
            output_tokens: usage["output_tokens"] || 0
          },
          raw: res_json,
          tool_calls: parsed_tool_calls
        )
      end

      private

      def format_messages(messages)
        @formatter.format_messages(messages)
      end

      def format_tools(tools)
        @formatter.format_tools(tools)
      end
    end
  end
end
