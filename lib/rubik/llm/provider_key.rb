# frozen_string_literal: true

module Rubik
  module LLM
    # Single source of truth for the registry-style provider key that scopes
    # per-provider knobs (`providers.<key>.*`): the explicit provider name
    # (downcased, the way the registry stores them) when it carries one, else
    # the class name derived the way builtin providers are registered
    # (Rubik::LLM::OllamaProvider -> "ollama"). An empty name counts as
    # unnamed, so instances built outside the registry keep falling back.
    #
    # ProviderResolver#registry_key and Router#stream_chat both delegate here.
    # The module lives in the LLM namespace on purpose: the Router must not
    # reach back into the orchestrator layer, which already depends on llm —
    # a back-reference would invert the layering.
    module ProviderKey
      module_function

      # Registry-style key of +provider+: the explicit `#name` (downcased)
      # when non-empty, else the class-name derivation. nil-safe end to end —
      # objects without `#name` and anonymous classes fall through cleanly.
      def derive(provider)
        explicit = provider.respond_to?(:name) ? provider.name.to_s.downcase : ""
        return explicit unless explicit.empty?

        klass_name = provider.class.name
        base = klass_name&.split("::")&.last
        base&.delete_suffix("Provider")&.downcase
      end
    end
  end
end
