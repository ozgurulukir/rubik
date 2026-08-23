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

      def get_for(spec)
        return nil unless spec.is_a?(Hash)

        provider_name = spec["provider"].to_s.downcase
        model_name = spec["name"]
        host = spec["host"]

        custom = get(provider_name)
        if custom && custom.class != OllamaProvider && custom.class != OpenAIProvider && custom.class != AnthropicProvider
          return custom
        end

        case provider_name
        when "ollama"
          OllamaProvider.new(host: host || "http://localhost:11434", model: model_name || "llama3")
        when "openai"
          OpenAIProvider.new(model: model_name || "gpt-4o")
        when "anthropic"
          AnthropicProvider.new(model: model_name || "claude-3-5-sonnet-20240620")
        else
          custom
        end
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
