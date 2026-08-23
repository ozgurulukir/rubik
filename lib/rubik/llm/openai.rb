# frozen_string_literal: true

require_relative "provider"
require_relative "client"

module Rubik
  module LLM
    class OpenAIProvider < BaseProvider
      attr_reader :model

      def initialize(model: "gpt-4o")
        @model = model
      end

      def complete(messages, opts = {})
        api_key = ENV["OPENAI_API_KEY"]
        raise ClientError, "OPENAI_API_KEY environment variable is not set" if api_key.nil? || api_key.empty?

        target_model = opts[:model] || @model
        endpoint = "https://api.openai.com/v1/chat/completions"

        headers = { "Authorization" => "Bearer #{api_key}" }
        payload = {
          model: target_model,
          messages: messages
        }

        res_json = HTTPClient.post_json(endpoint, headers: headers, payload: payload)

        text = res_json.dig("choices", 0, "message", "content") || ""
        usage = res_json["usage"] || {}

        Response.new(
          text: text,
          usage: {
            input_tokens: usage["prompt_tokens"] || 0,
            output_tokens: usage["completion_tokens"] || 0
          },
          raw: res_json
        )
      end
    end
  end
end
