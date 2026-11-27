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

      # Active-path cycle detection with a closed set: a key is removed from
      # +path+ after its subtree is verified acyclic and recorded in +visited+,
      # so shared acyclic DAGs survive in linear time instead of exploding
      # exponentially across alias fan-outs.
      def cyclic?(object, path = {}.compare_by_identity, visited = {}.compare_by_identity)
        return false unless object.is_a?(Array) || object.is_a?(Hash)
        return true if path.key?(object)
        return false if visited.key?(object)

        path[object] = true
        found = if object.is_a?(Hash)
                  object.any? { |key, value| cyclic?(key, path, visited) || cyclic?(value, path, visited) }
                else
                  object.any? { |value| cyclic?(value, path, visited) }
                end
        path.delete(object)
        visited[object] = true unless found
        found
      end
    end
  end
end
