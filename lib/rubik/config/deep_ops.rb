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
          rescue
            obj
          end
        end
      end

      def deep_merge(target, source)
        return deep_dup(target) unless source.is_a?(Hash)

        result = deep_dup(target)
        source.each do |key, val|
          result[key] = if result[key].is_a?(Hash) && val.is_a?(Hash)
                          deep_merge(result[key], val)
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

      # Deletes the dot-path leaf from nested string-keyed hashes. Idempotent:
      # returns true only when a leaf was actually removed. Ancestors are left
      # in place even when they become empty.
      def deep_delete(obj, path)
        keys = path.to_s.split(".")
        return false unless obj.is_a?(Hash)

        node = keys[0...-1].reduce(obj) do |acc, k|
          return false unless acc.is_a?(Hash)

          acc[k]
        end
        return false unless node.is_a?(Hash)

        node.delete(keys.last) ? true : false
      end
    end
  end
end
