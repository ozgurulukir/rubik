# frozen_string_literal: true

module Rubik
  module Orchestrator
    # Provider-scoped configuration resolution for the orchestrator loop
    # (review Öneri 3; extracted from Loop's provider-config section).
    #
    # Owns two lookups:
    # - registry_key: registry-style key of the active provider — the
    #   explicit provider name (downcased, the way the registry stores
    #   them) when it carries one, else the class name derived the way
    #   builtin providers are registered (Rubik::LLM::OllamaProvider ->
    #   "ollama"). An empty name counts as unnamed, so instances built
    #   outside the registry keep falling back.
    # - llm_config: per-provider llm.* override — providers.<key>.<field>
    #   beats the global llm.<field>, so a provider-specific quirk (e.g. a
    #   broken SSE stack) can be tuned without flipping the knob for every
    #   provider. A scoped nil counts as unset — also the only way to
    #   clear an override back to the global value.
    #
    # The config object is held by reference and values are re-read on
    # every fetch, so !config set / !provider set still apply from the
    # very next turn (config reactivity, Plan 75).
    class ProviderResolver
      def initialize(provider:, config:)
        @provider = provider
        @config = config
      end

      # Registry-style key for the active provider: the explicit provider name
      # when it carries one (downcased, the way the registry stores them),
      # else the class name derived the way builtin providers are registered
      # (Rubik::LLM::OllamaProvider -> "ollama"). An empty name counts as
      # unnamed, so instances built outside the registry keep falling back.
      def registry_key
        explicit = @provider.respond_to?(:name) ? @provider.name.to_s.downcase : ""
        return explicit unless explicit.empty?

        klass_name = @provider.class.name
        base = klass_name&.split("::")&.last
        base&.delete_suffix("Provider")&.downcase
      end

      # Per-provider llm.* override: providers.<key>.<field> beats the global
      # llm.<field>, so a provider-specific quirk (e.g. a broken SSE stack)
      # can be tuned without flipping the knob for every provider. Re-read on
      # each request: !config set / !provider set apply from the very next
      # turn. A scoped nil counts as unset — also the only way to clear an
      # override back to the global value.
      def llm_config(key, default)
        prov_key = registry_key
        if prov_key.is_a?(String) && !prov_key.empty? && @config.respond_to?(:fetch)
          val = @config.fetch("providers.#{prov_key}.#{key}", nil)
          return val unless val.nil?
        end

        # Two-arg fetch, not safe_config: safe_config's `fetch(...) || default`
        # would coerce an explicit false (llm.stream=false) into the truthy
        # default, and a one-arg fetch on a plain-Hash config (tests) raises
        # KeyError instead of falling through.
        return default unless @config.respond_to?(:fetch)

        @config.fetch("llm.#{key}", default)
      rescue StandardError
        default
      end
    end
  end
end
