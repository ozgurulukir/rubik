# frozen_string_literal: true

module Rubik
  module AST
    class SymbolMap
      def values
        qualified_values = @qualified_symbols.sort_by { |key, _symbol| key }.map(&:last)
        qualified_ids = qualified_values.each_with_object({}) { |symbol, ids| ids[symbol.object_id] = true }
        super().reject { |symbol| qualified_ids.key?(symbol.object_id) } + qualified_values
      end
    end

    class Graph
      class AmbiguousSymbolError < StandardError
        attr_reader :query, :candidates

        def initialize(query, candidates)
          @query = query
          @candidates = candidates
          super("Ambiguous symbol '#{query}'. Use a qualified key. Candidates:\n- #{candidates.join("\n- ")}")
        end
      end

      def begin_warmup(total: nil)
        @mutex.synchronize do
          @warmup_generation += 1
          @warmup_status = { state: :warming, indexed: 0, total: total, generation: @warmup_generation }
          @warmup_generation
        end
      end

      def update_warmup(generation, indexed: nil, total: nil)
        @mutex.synchronize do
          return false unless generation == @warmup_status[:generation] && @warmup_status[:state] == :warming

          @warmup_status[:indexed] = [indexed, 0].max unless indexed.nil?
          @warmup_status[:total] = [total, 0].max unless total.nil?
          true
        end
      end

      def finish_warmup(generation, state: :ready)
        @mutex.synchronize do
          return false unless generation == @warmup_status[:generation]

          @warmup_status[:state] = state
          true
        end
      end

      def warmup_status
        @mutex.synchronize { @warmup_status.dup }
      end

      # Search each qualified definition once and return deterministic relevance order.
      def search_symbols(query)
        q = query.to_s.downcase
        return [] if q.empty?

        @mutex.synchronize do
          entries = @qualified_symbols.sort_by { |key, _symbol| key }
          entries = @symbols.map { |name, sym| ["#{sym.file}##{name}", sym] }.sort_by(&:first) if entries.empty?
          entries.select { |_key, sym| sym.name.downcase.include?(q) }
                 .sort_by { |key, sym| [_search_rank(sym.name.downcase, q), key] }
                 .map(&:last)
        end
      end

      def symbol_candidates(symbol_name)
        @mutex.synchronize { _symbol_candidate_pairs_unlocked(symbol_name).map(&:first) }
      end

      # A bare query with multiple definitions is ambiguous; unresolved receiver
      # dispatches remain in the call list without being assigned to a symbol.
      def callers_of(symbol_name)
        @mutex.synchronize do
          candidates = _symbol_candidate_pairs_unlocked(symbol_name)
          return [] if candidates.empty?
          raise AmbiguousSymbolError.new(symbol_name, candidates.map(&:first)) if candidates.length > 1

          target_key, target = candidates.first
          target_names = caller_targets(symbol_name)
          target_name_count = _symbol_candidate_pairs_unlocked(_symbol_leaf(target.name)).length
          known_symbols = @qualified_symbols.values.uniq
          known_symbols = @symbols.values.uniq if known_symbols.empty?
          known_symbols.select do |caller|
            caller.calls.any? do |call|
              _call_matches_symbol?(call, caller, target, target_key, target_names, target_name_count)
            end
          end
        end
      end

      def symbol_definition(symbol_name)
        @mutex.synchronize do
          candidates = _symbol_candidate_pairs_unlocked(symbol_name)
          return nil unless candidates.length == 1

          target = candidates.first.last
          {
            name: target.name,
            kind: target.kind,
            file: target.file,
            line_start: target.line_start,
            line_end: target.line_end,
            signature: target.signature,
            body: target.body,
            docstring: target.docstring,
            calls: target.calls
          }
        end
      end

      private

      def _search_rank(name, query)
        return 0 if name == query
        return 1 if name.start_with?(query)

        2
      end

      def caller_targets(symbol_name)
        candidates = _symbol_candidate_pairs_unlocked(symbol_name)
        return [] unless candidates.length == 1

        key, symbol = candidates.first
        [key, symbol.name].uniq
      end

      def _symbol_candidate_pairs_unlocked(symbol_name)
        query = symbol_name.to_s
        return [] if query.empty?

        exact = @qualified_symbols[query]
        return [[query, exact]] if exact

        pairs = @qualified_symbols.to_a
        pairs = @symbols.map { |name, sym| ["#{sym.file}##{name}", sym] } if pairs.empty?
        folded = query.downcase
        pairs.select do |_key, symbol|
          name = symbol.name.to_s
          leaf = _symbol_leaf(name)
          name.downcase == folded || leaf.downcase == folded || name.downcase.end_with?("##{folded}", ".#{folded}")
        end.sort_by(&:first).uniq { |key, _symbol| key }
      end

      def _symbol_leaf(name)
        name.to_s.split(/[#.:]/).last.to_s
      end

      def _symbol_scope(name)
        value = name.to_s
        separator = [value.rindex("#"), value.rindex("."), value.rindex("::")].compact.max
        separator ? value[0...separator] : nil
      end

      def _normalized_call_name(name)
        name.to_s.gsub("::", "#").gsub(".", "#").sub(/!\z/, "")
      end

      def _call_matches_symbol?(call, caller, target, target_key, target_names, target_name_count)
        value = call.to_s.strip.sub(/!\z/, "")
        normalized = _normalized_call_name(value)
        target_name = _normalized_call_name(target.name)
        return true if value == target_key
        return true if normalized == target_name && (target_name.include?("#") || target_name_count == 1)

        leaf = _symbol_leaf(value)
        return false unless leaf == _symbol_leaf(target.name)
        return true if target_name_count == 1 && !value.match?(/[.#:]|->/)

        call_scope = _symbol_scope(value)
        target_scope = _symbol_scope(target.name)
        caller_scope = _symbol_scope(caller.name)
        same_file = caller.file && target.file && caller.file == target.file
        return true if call_scope == target_scope && call_scope && same_file
        return true if ["self", "this"].include?(call_scope) && caller_scope == target_scope && same_file

        # Bare calls are local to one lexical scope; unknown receiver calls stay unresolved.
        lexical_scope_matches = target_scope ? caller_scope == target_scope : caller_scope.nil?
        !value.match?(/[.#:]|->/) && target_names.include?(target.name) && same_file && lexical_scope_matches
      end
    end
  end
end
