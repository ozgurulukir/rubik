# frozen_string_literal: true

require_relative "openai_compatible"
require_relative "ollama"
require_relative "openai"
require_relative "anthropic"
require_relative "../prompt/context_compactor"

module Rubik
  module LLM
    class Registry
      DEFAULT_CONTEXT_LIMITS = {
        "anthropic" => 200_000,
        "openai" => 128_000,
        "ollama" => 32_768,
        "default" => 32_768
      }.freeze

      DEFAULT_MAX_OUTPUT_TOKENS = {
        "anthropic" => 8_192,
        "openai" => 4_096,
        "ollama" => 4_096,
        "default" => 4_096
      }.freeze

      attr_reader :providers, :models_catalog, :config

      def initialize(config = nil)
        @config = config
        @providers = {
          "ollama" => OllamaProvider.new,
          "openai" => OpenAIProvider.new,
          "anthropic" => AnthropicProvider.new
        }
        @models_catalog = {}
        load_from_config(config) if config
      end

      def load_from_config(config)
        @config = config
        return unless config

        custom_providers = config.fetch("providers", {})
        return unless custom_providers.is_a?(Hash)

        custom_providers.each do |p_name, p_spec|
          next unless p_spec.is_a?(Hash)

          register_provider_spec(p_name.to_s.downcase, p_spec)
        end
      end

      def register_provider_spec(p_name, p_spec)
        type = p_spec["type"].to_s.downcase
        endpoint = p_spec["endpoint"] || p_spec["host"] || p_spec["url"]
        api_key_env = p_spec["api_key_env"]
        api_key = p_spec["api_key"]
        headers = p_spec["headers"] || {}
        models = p_spec["models"] || []
        default_model = p_spec["default_model"] || (models.is_a?(Array) && models.first.is_a?(Hash) ? models.first["name"] : models.first)

        provider_instance = case type
                            when "openai_compatible", "openai"
                              OpenAICompatibleProvider.new(
                                name: p_name,
                                endpoint: endpoint || "https://api.openai.com/v1/chat/completions",
                                api_key: api_key,
                                api_key_env: api_key_env,
                                headers: headers,
                                model: default_model || "gpt-4o"
                              )
                            when "ollama"
                              OllamaProvider.new(
                                host: endpoint || "http://localhost:11434",
                                model: default_model || "llama3"
                              )
                            when "anthropic"
                              AnthropicProvider.new(
                                model: default_model || "claude-3-5-sonnet-20240620"
                              )
                            else
                              # Default fallback to openai_compatible
                              OpenAICompatibleProvider.new(
                                name: p_name,
                                endpoint: endpoint || "http://localhost:8000/v1/chat/completions",
                                api_key: api_key,
                                api_key_env: api_key_env,
                                headers: headers,
                                model: default_model || "default"
                              )
                            end

        @providers[p_name] = provider_instance

        # Register models in catalog
        if models.is_a?(Array)
          models.each do |m_entry|
            if m_entry.is_a?(Hash)
              m_name = m_entry["name"]
              c_limit = m_entry["context_limit"] || m_entry["context_window"] || 32_768
              @models_catalog["#{p_name}/#{m_name}"] = {
                provider: p_name,
                name: m_name,
                context_limit: c_limit.to_i,
                endpoint: endpoint
              }
            elsif m_entry.is_a?(String)
              @models_catalog["#{p_name}/#{m_entry}"] = {
                provider: p_name,
                name: m_entry,
                context_limit: 32_768,
                endpoint: endpoint
              }
            end
          end
        end
      end

      def register(provider_name, provider_instance)
        @providers[provider_name.to_s.downcase] = provider_instance
      end

      def get(provider_name)
        @providers[provider_name.to_s.downcase]
      end

      def get_for(spec)
        return nil unless spec.is_a?(Hash)

        provider_name = spec["provider"].to_s.downcase
        model_name = spec["name"]
        endpoint = spec["endpoint"] || spec["host"] || spec["url"]

        # Check for registered custom provider
        custom = get(provider_name)
        if custom && custom.class != OllamaProvider && custom.class != OpenAIProvider && custom.class != AnthropicProvider
          if custom.class == OpenAICompatibleProvider
            return OpenAICompatibleProvider.new(
              name: custom.name,
              endpoint: endpoint || custom.endpoint,
              api_key: custom.api_key,
              api_key_env: custom.api_key_env,
              headers: custom.headers,
              model: model_name || custom.model,
              default_context_limit: custom.default_context_limit
            )
          else
            return custom
          end
        end

        case provider_name
        when "ollama"
          OllamaProvider.new(endpoint: endpoint || "http://localhost:11434", model: model_name || "llama3")
        when "openai"
          OpenAIProvider.new(model: model_name || "gpt-4o")
        when "anthropic"
          AnthropicProvider.new(model: model_name || "claude-3-5-sonnet-20240620")
        else
          custom
        end
      end

      def context_limit_for(provider_name, model_name)
        p_str = provider_name.to_s.downcase
        m_str = model_name.to_s

        catalog_entry = @models_catalog["#{p_str}/#{m_str}"]
        return catalog_entry[:context_limit] if catalog_entry && catalog_entry[:context_limit]

        provider = get(p_str)
        if provider.is_a?(OpenAICompatibleProvider)
          provider.default_context_limit
        else
          DEFAULT_CONTEXT_LIMITS[p_str] || DEFAULT_CONTEXT_LIMITS["default"]
        end
      end

      def max_output_tokens_for(provider_name, model_name = nil)
        p_str = provider_name.to_s.downcase
        m_str = model_name.to_s

        catalog_entry = @models_catalog["#{p_str}/#{m_str}"]
        return catalog_entry[:max_output_tokens] if catalog_entry && catalog_entry[:max_output_tokens]

        DEFAULT_MAX_OUTPUT_TOKENS[p_str] || DEFAULT_MAX_OUTPUT_TOKENS["default"]
      end

      def effective_input_limit_for(provider_name, model_name = nil, safety_margin: 1024)
        c_limit = context_limit_for(provider_name, model_name)
        max_out = max_output_tokens_for(provider_name, model_name)
        Rubik::Prompt::ContextCompactor.effective_input_ceiling(
          context_limit: c_limit,
          max_output_tokens: max_out,
          safety_margin: safety_margin
        )
      end

      def list
        @providers.keys
      end

      def catalog
        result = {}
        @providers.each do |p_name, instance|
          models_for_p = @models_catalog.values.select { |m| m[:provider] == p_name }
          result[p_name] = {
            type: instance.class.name.split("::").last,
            endpoint: instance.respond_to?(:endpoint) ? instance.endpoint : (instance.respond_to?(:host) ? instance.host : "cloud"),
            models: models_for_p.map { |m| { name: m[:name], context_limit: m[:context_limit] } }
          }
        end
        result
      end
    end
  end
end
