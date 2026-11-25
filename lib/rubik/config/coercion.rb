# frozen_string_literal: true

module Rubik
  class Config
    # Single home for the typed-value pipeline shared by dotted-key writes and
    # scoped overrides: parse scalars, coerce, validate, then handle whole
    # sections. Included into Config so Scoped inherits the same interface.
    module Coercion
      private

      def normalize_value(key, value)
        typed = Schema.coerce(key, parse_scalar_value(value))
        Schema.validate_value!(key, typed, strict: true)
        return typed unless typed.is_a?(Hash)

        typed = deep_dup(typed)
        Schema.coerce_nested!(typed, key.to_s)
        # Only spec'd sections validate their leaves — open sections
        # (providers, adapter) accept arbitrary child keys silently.
        section = DEFAULT_CONFIG[key.to_s]
        validate_schema(typed, section, key.to_s) if section.is_a?(Hash) && !section.empty?
        typed
      end
    end
  end
end
