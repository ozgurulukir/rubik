# frozen_string_literal: true

require_relative "../base"
require_relative "../../coeffects"
require_relative "../symbol_tool_support"

module Rubik
  module Tools
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
          all_sym_names = SymbolToolSupport.fuzzy_candidate_names(graph)
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
          all_sym_names = SymbolToolSupport.fuzzy_candidate_names(graph)
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
