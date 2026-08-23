# frozen_string_literal: true

require_relative "ollama"
require_relative "openai"
require_relative "anthropic"

module Rubik
  module LLM
    class Registry
      def initialize
        @providers = {
          "ollama" => OllamaProvider.new,
          "openai" => OpenAIProvider.new,
          "anthropic" => AnthropicProvider.new
        }
      end

      def get(provider_name)
        @providers[provider_name.to_s.downcase]
      end

      def register(provider_name, provider_instance)
        @providers[provider_name.to_s.downcase] = provider_instance
      end

      def list
        @providers.keys
      end
    end
  end
end
