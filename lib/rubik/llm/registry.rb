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
        "deepseek" => 64_000,
        "openrouter" => 128_000,
        "cline" => 64_000,
        "groq" => 128_000,
        "gemini" => 1_000_000,
        "ollama" => 32_768,
        "default" => 32_768
      }.freeze

      DEFAULT_MAX_OUTPUT_TOKENS = {
        "anthropic" => 8_192,
        "openai" => 16_384,
        "deepseek" => 8_192,
        "gemini" => 8_192,
        "ollama" => 4_096,
        "default" => 4_096
      }.freeze

      attr_reader :providers, :models_catalog, :config

      def initialize(config = nil)
        @config = config
        global_headers = extract_global_headers(config)
        @providers = {
          "ollama" => OllamaProvider.new(model: "qwen2.5-coder:7b", headers: global_headers),
          "openai" => OpenAIProvider.new(model: "gpt-4o", headers: global_headers),
          "anthropic" => AnthropicProvider.new(model: "claude-3-7-sonnet-20250219", headers: global_headers)
        }
        @models_catalog = {}
        load_from_config(config) if config
      end

      def extract_global_headers(cfg)
        return {} unless cfg

        if cfg.respond_to?(:fetch)
          begin
            h = cfg.fetch("llm.headers", nil)
            return h if h.is_a?(Hash)
          rescue
            nil
          end
        end
        if cfg.respond_to?(:[])
          llm_conf = cfg["llm"]
          return llm_conf["headers"] if llm_conf.is_a?(Hash) && llm_conf["headers"].is_a?(Hash)
        end
        {}
      end

      def load_from_config(config)
        @config = config
        return unless config

        global_headers = extract_global_headers(config)
        if @providers["ollama"].instance_of?(OllamaProvider)
          @providers["ollama"] = OllamaProvider.new(
            model: @providers["ollama"]&.model || "qwen2.5-coder:7b",
            num_ctx: @providers["ollama"]&.num_ctx,
            headers: global_headers
          )
        end
        if @providers["openai"].instance_of?(OpenAIProvider)
          @providers["openai"] = OpenAIProvider.new(
            model: @providers["openai"]&.model || "gpt-4o",
            headers: global_headers
          )
        end
        if @providers["anthropic"].instance_of?(AnthropicProvider)
          @providers["anthropic"] = AnthropicProvider.new(
            model: @providers["anthropic"]&.model || "claude-3-7-sonnet-20250219",
            headers: global_headers
          )
        end

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
        global_headers = extract_global_headers(@config)
        spec_headers = p_spec["headers"] || {}
        headers = global_headers.merge(spec_headers)
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
                                model: default_model || "gpt-4o",
                                default_context_limit: spec_limit(p_spec, :context),
                                default_max_output_tokens: spec_limit(p_spec, :output)
                              )
                            when "ollama"
                              OllamaProvider.new(
                                endpoint: endpoint || "http://localhost:11434",
                                model: default_model || "qwen2.5-coder:7b",
                                num_ctx: p_spec["num_ctx"],
                                headers: headers
                              )
                            when "anthropic"
                              AnthropicProvider.new(
                                model: default_model || "claude-3-7-sonnet-20250219",
                                headers: headers
                              )
                            else
                              # Default fallback to openai_compatible
                              OpenAICompatibleProvider.new(
                                name: p_name,
                                endpoint: endpoint || "http://localhost:8000/v1/chat/completions",
                                api_key: api_key,
                                api_key_env: api_key_env,
                                headers: headers,
                                model: default_model || "default",
                                default_context_limit: spec_limit(p_spec, :context),
                                default_max_output_tokens: spec_limit(p_spec, :output)
                              )
                            end

        @providers[p_name] = provider_instance

        # Register models in catalog
        return unless models.is_a?(Array)

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

      def register(provider_name, provider_instance)
        @providers[provider_name.to_s.downcase] = provider_instance
      end

      def get(provider_name)
        @providers[provider_name.to_s.downcase]
      end

      # Plan 61 D-5: role specs may carry per-role limits (context_limit /
      # max_output_tokens / num_ctx); provider-level spec values are the
      # fallback so custom providers no longer silently run with the 32k
      # constructor default.
      def spec_limit(p_spec, kind)
        key = kind == :context ? "context_limit" : "max_output_tokens"
        alt_key = kind == :context ? "context_window" : nil
        value = p_spec[key] || (alt_key && p_spec[alt_key])
        value&.to_i
      end

      def get_for(spec)
        return nil unless spec.is_a?(Hash)

        provider_name = spec["provider"].to_s.downcase
        model_name = spec["name"]
        endpoint = spec["endpoint"] || spec["host"] || spec["url"]

        global_headers = extract_global_headers(@config)

        # Check for registered custom provider
        custom = get(provider_name)
        if custom && custom.class != OllamaProvider && custom.class != OpenAIProvider && custom.class != AnthropicProvider
          return custom unless custom.instance_of?(OpenAICompatibleProvider)

          merged_headers = global_headers.merge(custom.headers || {})
          return OpenAICompatibleProvider.new(
            name: custom.name,
            endpoint: endpoint || custom.endpoint,
            api_key: custom.api_key,
            api_key_env: custom.api_key_env,
            headers: merged_headers,
            model: model_name || custom.model,
            default_context_limit: custom.default_context_limit,
            default_max_output_tokens: custom.default_max_output_tokens
          )
        end

        case provider_name
        when "ollama"
          ollama_headers = (custom.respond_to?(:headers) ? custom.headers : nil) || global_headers
          OllamaProvider.new(
            endpoint: endpoint || "http://localhost:11434",
            model: model_name || "llama3",
            num_ctx: spec["num_ctx"] || (custom.is_a?(OllamaProvider) ? custom.num_ctx : nil),
            headers: ollama_headers
          )
        when "openai"
          openai_headers = (custom.respond_to?(:headers) ? custom.headers : nil) || global_headers
          OpenAIProvider.new(model: model_name || "gpt-4o", headers: openai_headers)
        when "anthropic"
          anthropic_headers = (custom.respond_to?(:headers) ? custom.headers : nil) || global_headers
          AnthropicProvider.new(model: model_name || "claude-3-7-sonnet-20250219", headers: anthropic_headers)
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
        return provider.default_context_limit if provider.is_a?(OpenAICompatibleProvider) && provider.default_context_limit&.positive?

        DEFAULT_CONTEXT_LIMITS[p_str] || DEFAULT_CONTEXT_LIMITS["default"]
      end

      def max_output_tokens_for(provider_name, model_name = nil)
        p_str = provider_name.to_s.downcase
        m_str = model_name.to_s

        catalog_entry = @models_catalog["#{p_str}/#{m_str}"]
        return catalog_entry[:max_output_tokens] if catalog_entry && catalog_entry[:max_output_tokens]

        provider = get(p_str)
        return provider.default_max_output_tokens if provider.is_a?(OpenAICompatibleProvider) && provider.default_max_output_tokens&.positive?

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
            endpoint: if instance.respond_to?(:endpoint)
                        instance.endpoint
                      else
                        (instance.respond_to?(:host) ? instance.host : "cloud")
                      end,
            models: models_for_p.map { |m| { name: m[:name], context_limit: m[:context_limit] } }
          }
        end
        result
      end
    end
  end
end
