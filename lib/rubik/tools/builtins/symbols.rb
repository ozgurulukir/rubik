# frozen_string_literal: true

require_relative "../base"
require_relative "../../coeffects"
require_relative "../output"
require_relative "../diagnostic_reporter"
require_relative "../fuzzy_matcher"
require_relative "../truncator"

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
        return [nil, ToolOutput.error("#{label} must be a string.")] unless values.all? { |value| value.is_a?(String) }

        [values.first, nil]
      end

      def self.boolean_argument(args, key, label: key)
        return [nil, ToolOutput.error("Tool arguments must be an object.")] unless args.is_a?(Hash)

        values = [key.to_s, key.to_sym].uniq.filter_map { |actual| args[actual] if args.key?(actual) }
        return [false, nil] if values.empty?
        return [nil, ToolOutput.error("#{label} must be a boolean.")] unless values.all? { |value| value == true || value == false }

        [values.first, nil]
      end

      def self.warmup_output(graph)
        return nil unless graph.respond_to?(:warmup_status)

        status = graph.warmup_status
        return nil unless status

        state = status[:state] || status["state"]
        if state == :warming || state == "warming"
          indexed = status[:indexed] || status["indexed"]
          total = status[:total] || status["total"]
          progress = if indexed.is_a?(Numeric) && total.is_a?(Numeric)
                       " (#{indexed}/#{total} files indexed)"
                     else
                       ""
                     end
          ToolOutput.error("AST index warming; retry this request shortly#{progress}.")
        elsif state == :failed || state == "failed"
          ToolOutput.error("AST index warmup failed; retry after running '!context scan'.")
        end
      end

      def self.rank_matches(matches, query, graph)
        symbol_map = graph.respond_to?(:symbols) ? graph.symbols : nil
        qualified = symbol_map.respond_to?(:qualified_symbols) ? symbol_map.qualified_symbols : {}
        keys_by_id = qualified.sort_by { |key, _symbol| key }.each_with_object({}) do |(key, symbol), keys|
          keys[symbol.object_id] ||= key
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
          key = keys_by_id[symbol.object_id] || "#{symbol.file}##{symbol.name}"
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
          return truncated[:text] unless truncated[:truncated] || shown_count.zero?

          shown_count -= 1
        end
      end
    end

    class SearchSymbolsTool < BaseTool
      # Declared coeffects: hidden from schemas (PENDING) until satisfied (AGENTS.md §2).
      REQUIRES = [Rubik::Coeffects::AST_GRAPH].freeze

      DECLARATION = Declaration.new(
        name: "search_symbols", aliases: ["find_symbols", "symbols"],
        description: "Search function, class, struct definitions and call hierarchies in the AST symbol graph",
        risk: :read, archetypes: [:research],
        params_schema: {
          type: "object",
          properties: {
            query: { type: "string", description: "Symbol name or partial name to search" },
            smart_context: { type: "boolean", description: "Return full smart context with dependencies (optional)" }
          },
          required: ["query"]
        }
      )
      def initialize(ast_graph = nil, runtime_context: nil, context: nil)
        super(DECLARATION)
        @ast_graph = ast_graph
        @runtime_context = runtime_context || context
      end

      def ast_graph
        Rubik::Coeffects.resolve(@runtime_context, Rubik::Coeffects::AST_GRAPH, @ast_graph)
      end

      def execute(args = {})
        query, error = SymbolToolSupport.string_argument(args, "query", label: "query")
        return error if error
        return ToolOutput.error("Query parameter is required.") if query.nil? || query.strip.empty?
        query = query.strip

        smart_context, error = SymbolToolSupport.boolean_argument(args, "smart_context", label: "smart_context")
        return error if error

        graph = ast_graph
        return ToolOutput.error("AST graph is not available. Run '!context scan' to build the symbol index.") unless graph
        warming = SymbolToolSupport.warmup_output(graph)
        return warming if warming

        if smart_context
          ctx = graph.smart_context_for(query)
          return ctx.empty? ? "No smart context found for '#{query}'." : ctx
        end

        matches = if graph.respond_to?(:search_symbols)
                    graph.search_symbols(query)
                  else
                    graph.symbols.values.select { |sym| sym.name.downcase.include?(query.downcase) }
                  end

        if matches.empty?
          symbols = graph.respond_to?(:symbols) ? graph.symbols : nil
          all_sym_names = if symbols.respond_to?(:qualified_symbols)
                            symbols.qualified_symbols.keys.sort
                          elsif symbols.respond_to?(:keys)
                            symbols.keys
                          else
                            []
                          end
          candidates = FuzzyMatcher.best_matches(query, all_sym_names)
          ToolOutput.error(DiagnosticReporter.render_symbol_not_found(query, candidate_symbols: candidates))
        else
          ranked = SymbolToolSupport.rank_matches(matches, query, graph)
          SymbolToolSupport.render_search(query, ranked)
        end
      end
    end

    class GetOutlineTool < BaseTool
      # Declared coeffects: hidden from schemas (PENDING) until satisfied (AGENTS.md §2).
      REQUIRES = [Rubik::Coeffects::AST_GRAPH].freeze

      DECLARATION = Declaration.new(
        name: "get_outline", aliases: ["file_outline", "outline"],
        description: "Get high-level semantic outline (classes, methods, functions, and line ranges) " \
                     "of a source file from the AST without reading entire file content. " \
                     "Accepts 'file_path' (or 'path').",
        risk: :read, archetypes: [:research],
        params_schema: {
          type: "object",
          properties: {
            file_path: { type: "string", description: "Path to source file to inspect" }
          },
          required: ["file_path"]
        }
      )
      def initialize(ast_graph = nil, runtime_context: nil, context: nil)
        super(DECLARATION)
        @ast_graph = ast_graph
        @runtime_context = runtime_context || context
      end

      def ast_graph
        Rubik::Coeffects.resolve(@runtime_context, Rubik::Coeffects::AST_GRAPH, @ast_graph)
      end

      def execute(args = {})
        path, error = SymbolToolSupport.string_argument(args, "file_path", aliases: ["path"], label: "file_path")
        return error if error
        return ToolOutput.error("File path is required.") if path.nil? || path.strip.empty?
        path = path.strip

        graph = ast_graph
        return ToolOutput.error("AST graph is not available. Run '!context scan' to build the symbol index.") unless graph
        warming = SymbolToolSupport.warmup_output(graph)
        return warming if warming

        outline = graph.outline_for(path)
        status = graph.extraction_status(path) if graph.respond_to?(:extraction_status)
        return ToolOutput.error("Outline extraction failed for '#{path}'.") if status == :failed
        return "#{outline}\n[Partial extraction: some symbols may be missing.]" if status == :partial

        outline
      end
    end

    class FindReferencesTool < BaseTool
      # Declared coeffects: hidden from schemas (PENDING) until satisfied (AGENTS.md §2).
      REQUIRES = [Rubik::Coeffects::AST_GRAPH].freeze

      DECLARATION = Declaration.new(
        name: "find_references", aliases: ["references", "get_callers"],
        description: "Find all call sites, callers, and references of a symbol/function/class across the workspace for safe refactoring. " \
                     "This is based on the AST symbol graph; for a catch-all text search matching names, use grep_search. " \
                     "Accepts 'symbol_name' (or 'symbol').",
        risk: :read, archetypes: [:research],
        params_schema: {
          type: "object",
          properties: {
            symbol_name: { type: "string", description: "Symbol name to find callers/references for" }
          },
          required: ["symbol_name"]
        }
      )
      def initialize(ast_graph = nil, runtime_context: nil, context: nil)
        super(DECLARATION)
        @ast_graph = ast_graph
        @runtime_context = runtime_context || context
      end

      def ast_graph
        Rubik::Coeffects.resolve(@runtime_context, Rubik::Coeffects::AST_GRAPH, @ast_graph)
      end

      def execute(args = {})
        sym_name, error = SymbolToolSupport.string_argument(args, "symbol_name", aliases: ["symbol"], label: "symbol_name")
        return error if error
        return ToolOutput.error("Symbol name is required.") if sym_name.nil? || sym_name.strip.empty?
        sym_name = sym_name.strip

        graph = ast_graph
        return ToolOutput.error("AST graph is not available. Run '!context scan' to build the symbol index.") unless graph
        warming = SymbolToolSupport.warmup_output(graph)
        return warming if warming

        callers = graph.callers_of(sym_name)
        if callers.empty?
          "No references or callers found for '#{sym_name}' in AST graph."
        else
          lines = ["Found #{callers.size} reference(s) for '#{sym_name}':"]
          callers.each do |c|
            lines << "  • #{c.name} (#{c.file}:#{c.line_start}-#{c.line_end}) -> #{c.signature}"
          end
          lines.join("\n")
        end
      rescue Rubik::AST::Graph::AmbiguousSymbolError => e
        ToolOutput.error(e.message)
      end
    end

    class GetSymbolTool < BaseTool
      # Declared coeffects: hidden from schemas (PENDING) until satisfied (AGENTS.md §2).
      REQUIRES = [Rubik::Coeffects::AST_GRAPH].freeze

      DECLARATION = Declaration.new(
        name: "get_symbol", aliases: ["get_definition", "symbol_info"],
        description: "Get isolated definition, signature, docstring, and body of a specific class or method from the AST. " \
                     "Accepts 'symbol_name' (or 'symbol').",
        risk: :read, archetypes: [:research],
        params_schema: {
          type: "object",
          properties: {
            symbol_name: { type: "string", description: "Symbol name to retrieve definition for" }
          },
          required: ["symbol_name"]
        }
      )
      def initialize(ast_graph = nil, runtime_context: nil, context: nil)
        super(DECLARATION)
        @ast_graph = ast_graph
        @runtime_context = runtime_context || context
      end

      def ast_graph
        Rubik::Coeffects.resolve(@runtime_context, Rubik::Coeffects::AST_GRAPH, @ast_graph)
      end

      def execute(args = {})
        sym_name, error = SymbolToolSupport.string_argument(args, "symbol_name", aliases: ["symbol"], label: "symbol_name")
        return error if error
        return ToolOutput.error("Symbol name is required.") if sym_name.nil? || sym_name.strip.empty?
        sym_name = sym_name.strip

        graph = ast_graph
        return ToolOutput.error("AST graph is not available. Run '!context scan' to build the symbol index.") unless graph
        warming = SymbolToolSupport.warmup_output(graph)
        return warming if warming

        candidates = graph.symbol_candidates(sym_name) if graph.respond_to?(:symbol_candidates)
        if candidates && candidates.length > 1
          message = "Ambiguous symbol '#{sym_name}'. Use a qualified key. Candidates:\n- #{candidates.join("\n- ")}"
          return ToolOutput.error(message)
        end

        info = graph.symbol_definition(sym_name)
        unless info
          all_sym_names = graph.respond_to?(:symbols) ? graph.symbols.keys : []
          candidates = FuzzyMatcher.best_matches(sym_name, all_sym_names)
          return ToolOutput.error(DiagnosticReporter.render_symbol_not_found(sym_name, candidate_symbols: candidates))
        end

        lines = [
          "Symbol: #{info[:name]} [#{info[:kind].to_s.upcase}]",
          "File: #{info[:file]} (lines #{info[:line_start]}-#{info[:line_end]})",
          "Signature: #{info[:signature]}"
        ]
        lines << "Docstring: #{info[:docstring]}" if info[:docstring] && !info[:docstring].empty?
        lines << "Calls: #{info[:calls].join(', ')}" unless info[:calls].empty?
        lines << "\n--- Body ---\n#{info[:body]}" if info[:body] && !info[:body].empty?
        lines.join("\n")
      end
    end
  end
end
