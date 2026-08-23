# frozen_string_literal: true

require_relative "provider"
require_relative "client"

module Rubik
  module LLM
    class AnthropicProvider < BaseProvider
      attr_reader :model

      def initialize(model: "claude-3-5-sonnet-20240620")
        @model = model
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

        payload = {
          model: target_model,
          messages: user_msgs,
          max_tokens: opts[:max_tokens] || 1024
        }

        unless system_msgs.empty?
          payload[:system] = system_msgs.map { |m| m[:content] || m["content"] }.join("\n\n")
        end

        res_json = HTTPClient.post_json(endpoint, headers: headers, payload: payload)

        text = res_json.dig("content", 0, "text") || ""
        usage = res_json["usage"] || {}

        Response.new(
          text: text,
          usage: {
            input_tokens: usage["input_tokens"] || 0,
            output_tokens: usage["output_tokens"] || 0
          },
          raw: res_json
        )
      end
    end
  end
end
