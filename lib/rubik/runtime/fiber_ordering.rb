# frozen_string_literal: true

# Pure fiber ordering for Runtime::Manager (G4 extraction): Kahn's algorithm
# over provides/injects/requires with legacy-alias canonicalization. Returns
# [sorted, cycled] — cycle failure REPORTING stays in the Manager (it touches
# the context's dmesg service); this module only computes the order.
module Rubik
  module Runtime
    module FiberOrdering
      module_function

      def sort(fibers)
        return [fibers, []] if fibers.size <= 1

        provider_map = {}
        fibers.each do |f|
          (f.respond_to?(:provides) ? f.provides : [f.name.downcase]).each do |k|
            (provider_map[k] ||= []) << f
            canon = Rubik::Coeffects.canonical(k)
            (provider_map[canon] ||= []) << f if canon && canon != k
          end
        end

        dependents = Hash.new { |h, k| h[k] = Set.new }
        in_degree = Hash.new(0)
        fibers.each do |consumer|
          needed = (Array(consumer.inject) + Array(consumer.requires)).map { |d| d.to_s.downcase }
          prereqs = Set.new
          needed.each do |k|
            providers = (provider_map[k] || []) + (provider_map[Rubik::Coeffects.canonical(k)] || [])
            providers.each { |p| prereqs << p if p != consumer && fibers.include?(p) }
          end
          in_degree[consumer] = prereqs.size
          prereqs.each { |p| dependents[p] << consumer }
        end

        queue = fibers.select { |f| in_degree[f].zero? }
        sorted = []
        until queue.empty?
          curr = queue.shift
          sorted << curr
          dependents[curr].each do |dep|
            in_degree[dep] -= 1
            queue << dep if in_degree[dep].zero?
          end
        end

        [sorted, fibers - sorted]
      end
    end
  end
end
