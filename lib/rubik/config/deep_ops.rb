# frozen_string_literal: true

module Rubik
  class Config
    module DeepOps
      private

      def deep_dup(obj)
        case obj
        when Hash
          obj.transform_values { |v| deep_dup(v) }
        when Array
          obj.map { |v| deep_dup(v) }
        else
          begin
            obj.dup
          rescue TypeError
            # nil/true/false are undupable immediates; YAML-derived config
            # values raise nothing else here. A custom #dup raising anything
            # else must fail loud, not silently alias the value.
            obj
          end
        end
      end

      # Merges source over target.
      # Invariant (W6): Arrays are replaced as whole units by default so config overrides
      # can completely reset lists. If array_union: true, arrays are merged via union.
      def deep_merge(target, source, array_union: false)
        return deep_dup(target) unless source.is_a?(Hash)

        result = deep_dup(target)
        source.each do |key, val|
          result[key] = if result[key].is_a?(Hash) && val.is_a?(Hash)
                          deep_merge(result[key], val, array_union: array_union)
                        elsif array_union && result[key].is_a?(Array) && val.is_a?(Array)
                          (result[key] + val).uniq
                        else
                          deep_dup(val)
                        end
        end
        result
      end

      def deep_stringify_keys(obj)
        case obj
        when Hash
          obj.each_with_object({}) do |(k, v), result|
            result[k.to_s] = deep_stringify_keys(v)
          end
        when Array
          obj.map { |v| deep_stringify_keys(v) }
        else
          obj
        end
      end

      # Deletes the dot-path leaf from nested string-keyed hashes. Returns
      # :deleted when the leaf existed and was removed, :absent when any
      # segment of the path is missing (nothing to delete), :blocked when
      # the path traverses an existing non-Hash (nothing was changed).
      def deep_delete(obj, path)
        keys = path.to_s.split(".")
        return :blocked unless obj.is_a?(Hash)

        node = keys[0...-1].reduce(obj) do |acc, k|
          return :absent unless acc.is_a?(Hash) && acc.key?(k)

          child = acc[k]
          return :blocked unless child.is_a?(Hash)

          child
        end
        return :blocked unless node.is_a?(Hash)

        node.delete(keys.last) ? :deleted : :absent
      end
    end
  end
end
