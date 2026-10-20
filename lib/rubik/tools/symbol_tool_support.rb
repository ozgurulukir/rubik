# frozen_string_literal: true

require_relative "output"
require_relative "diagnostic_reporter"
require_relative "fuzzy_matcher"
require_relative "truncator"

module Rubik
  module Tools
    module SymbolToolSupport
      def self.string_argument(args, primary, aliases: [], label: primary)
        return [nil, ToolOutput.error("Tool arguments must be an object.")] unless args.is_a?(Hash)

        values = [primary, *aliases].flat_map do |key|
          [key.to_s, key.to_sym].uniq.filter_map { |actual| args[actual] if args.key?(actual) }
        end
        values.compact!
        return [nil, nil] if values.empty?
        return [nil, ToolOutput.error("#{label} must be a string.")] unless values.all?(String)

        [values.first, nil]
      end

      def self.boolean_argument(args, key, label: key)
        return [nil, ToolOutput.error("Tool arguments must be an object.")] unless args.is_a?(Hash)

        values = [key.to_s, key.to_sym].uniq.filter_map { |actual| args[actual] if args.key?(actual) }
        values.compact!
        return [false, nil] if values.empty?
        return [nil, ToolOutput.error("#{label} must be a boolean.")] unless values.all? { |value| [true, false].include?(value) }

        [values.first, nil]
      end

      def self.warmup_output(graph)
        return nil unless graph.respond_to?(:warmup_status)

        status = graph.warmup_status
        return nil unless status

        state = status[:state] || status["state"]
        if [:warming, "warming"].include?(state)
          indexed = status[:indexed] || status["indexed"]
          total = status[:total] || status["total"]
          progress = if indexed.is_a?(Numeric) && total.is_a?(Numeric)
                       " (#{indexed}/#{total} files indexed)"
                     else
                       ""
                     end
          ToolOutput.error("AST index warming; retry this request shortly#{progress}.")
        elsif [:failed, "failed"].include?(state)
          ToolOutput.error("AST index warmup failed; retry after running '!context scan'.")
        end
      end

      def self.rank_matches(matches, query, graph)
        symbol_map = graph.respond_to?(:symbols) ? graph.symbols : nil
        qualified = symbol_map.respond_to?(:qualified_symbols) ? symbol_map.qualified_symbols : {}
        keys_by_id = {}.compare_by_identity
        qualified.sort_by { |key, _symbol| key }.each do |(key, symbol)|
          keys_by_id[symbol] ||= key
        end

        matches.each_with_index.sort_by do |symbol, index|
          name = symbol.name.to_s.downcase
          lowered_query = query.downcase
          rank = if name == lowered_query
                   0
                 elsif name.start_with?(lowered_query)
                   1
                 else
                   2
                 end
          key = keys_by_id[symbol] || "#{symbol.file}##{symbol.name}"
          [rank, key, index]
        end.map(&:first)
      end

      def self.render_search(query, matches)
        shown_count = [matches.length, 50].min
        loop do
          omitted = matches.length - shown_count
          lines = ["Found #{matches.length} matching symbol(s) for '#{query}':"]
          matches.first(shown_count).each do |sym|
            lines << "• #{sym.kind.to_s.upcase} #{sym.name} (#{sym.file}:#{sym.line_start}-#{sym.line_end})"
            lines << "  Signature: #{sym.signature}"
            lines << "  Calls: #{sym.calls.join(', ')}"
          end
          lines << "... #{omitted} additional matches omitted." if omitted.positive?

          truncated = Truncator.truncate(lines.join("\n"))
          return truncated[:text] if !truncated[:truncated] || shown_count <= 1

          shown_count -= 1
        end
      end

      def self.fuzzy_candidate_names(graph)
        symbols = graph.respond_to?(:symbols) ? graph.symbols : nil
        return [] unless symbols

        names = if symbols.respond_to?(:values)
                  symbols.values.filter_map { |sym| sym.name if sym.respond_to?(:name) }.uniq
                else
                  []
                end
        return names unless names.empty?

        symbols.respond_to?(:keys) ? symbols.keys : []
      end
    end
  end
end
