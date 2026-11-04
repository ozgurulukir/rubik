# frozen_string_literal: true

require_relative "defaults"

module Rubik
  class Config
    # Automated redundancy pruner (AGENTS.md Spatiotemporal Remedy).
    # Deeply prunes keys from `target` that are identical to `reference`.
    # Preserves explicit non-default overrides and custom unmanaged keys.
    # Drops redundant inherited defaults, shrinking disk files to true deltas.
    module Pruner
      module_function

      def prune(target, reference = Defaults::DEFAULT_CONFIG)
        return target unless target.is_a?(Hash) && reference.is_a?(Hash)

        pruned = {}
        target.each do |k, v|
          k_str = k.to_s
          has_key = reference.key?(k_str)
          ref_val = reference[k_str]

          if v.is_a?(Hash) && ref_val.is_a?(Hash)
            nested = prune(v, ref_val)
            pruned[k_str] = nested unless nested.empty?
          elsif !has_key || v != ref_val
            pruned[k_str] = v
          end
        end
        pruned
      end
    end
  end
end
