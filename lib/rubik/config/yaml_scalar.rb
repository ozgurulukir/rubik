# frozen_string_literal: true

require "yaml"

module Rubik
  class Config
    # Parses a scalar that looks like a YAML collection. Acyclic aliases are
    # legitimate YAML and stay typed; self-referential collections are refused
    # because Config's redaction walk recurses on every value before listeners
    # are notified. One home keeps that rule in sync with the write path.
    module YamlScalar
      module_function

      def parse_collection(text)
        parsed = YAML.safe_load(text, permitted_classes: [Symbol], aliases: true)
        return nil unless parsed.is_a?(Array) || parsed.is_a?(Hash)
        return nil if cyclic?(parsed)

        parsed
      rescue Psych::Exception
        nil
      end

      # Active-path cycle detection: a key is removed from +path+ after its
      # subtree is visited, so a value shared twice without a cycle survives.
      def cyclic?(object, path = {}.compare_by_identity)
        return false unless object.is_a?(Array) || object.is_a?(Hash)
        return true if path.key?(object)

        path[object] = true
        values = object.is_a?(Hash) ? object.keys + object.values : object
        found = values.any? { |value| cyclic?(value, path) }
        path.delete(object)
        found
      end
    end
  end
end
