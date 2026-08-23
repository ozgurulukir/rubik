# frozen_string_literal: true

require_relative "provider"
require_relative "client"

module Rubik
  module LLM
    class OllamaProvider < BaseProvider
      attr_reader :host, :model

      def initialize(host: "http://localhost:11434", model: "llama3")
        @host = host
        @model = model
      end

      def complete(messages, opts = {})
        target_model = opts[:model] || @model
        endpoint = "#{@host}/api/chat"

        payload = {
          model: target_model,
          messages: messages,
          stream: false
        }

        res_json = HTTPClient.post_json(endpoint, payload: payload)

        msg_content = res_json.dig("message", "content") || ""
        in_tokens = res_json["prompt_eval_count"] || estimate_tokens(messages.map { |m| m[:content] }.join)
        out_tokens = res_json["eval_count"] || estimate_tokens(msg_content)

        Response.new(
          text: msg_content,
          usage: { input_tokens: in_tokens, output_tokens: out_tokens },
          raw: res_json
        )
      end
    end
  end
end
