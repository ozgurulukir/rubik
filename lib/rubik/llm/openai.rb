# frozen_string_literal: true

require_relative "openai_compatible"

module Rubik
  module LLM
    class OpenAIProvider < OpenAICompatibleProvider
      def initialize(model: "gpt-4o", api_key: nil, api_key_env: "OPENAI_API_KEY", endpoint: "https://api.openai.com/v1/chat/completions", headers: {})
        super(
          name: "openai",
          endpoint: endpoint,
          api_key: api_key,
          api_key_env: api_key_env,
          headers: headers,
          model: model,
          default_context_limit: 128_000
        )
      end
    end
  end
end
