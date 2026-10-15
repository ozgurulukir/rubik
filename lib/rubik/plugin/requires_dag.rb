# frozen_string_literal: true

module Rubik
  module Plugin
    # Cycle detection for the `requires:` DAG (Plan 86 D-3), extracted from
    # Manager so the coordinator stays a coordinator (issue #144). Only
    # edges where both endpoints are known plugins are considered —
    # coeffect requirements that name external services are ignored.
    module RequiresDag
      module_function

      # `requires_map` is plugin_name -> array of required names.
      def cyclic?(requires_map)
        known = requires_map.keys.to_set
        adjacency = requires_map.transform_values { |reqs| reqs.select { |r| known.include?(r) } }

        visited = Set.new
        stack = Set.new

        dfs = lambda do |node|
          return true if stack.include?(node)
          return false if visited.include?(node)

          stack.add(node)
          (adjacency[node] || []).each do |neighbor|
            return true if dfs.call(neighbor)
          end
          stack.delete(node)
          visited.add(node)
          false
        end

        adjacency.each_key do |node|
          return true if dfs.call(node)
        end
        false
      end
    end
  end
end
