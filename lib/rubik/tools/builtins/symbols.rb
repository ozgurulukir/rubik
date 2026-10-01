# frozen_string_literal: true

require_relative "../base"
require_relative "../../coeffects"
require_relative "../output"
require_relative "../diagnostic_reporter"
require_relative "../fuzzy_matcher"

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
        query = (args["query"] || args[:query]).to_s.strip
        return ToolOutput.error("Query parameter is required.") if query.empty?

        graph = ast_graph
        return ToolOutput.error("AST graph is not available. Run '!context scan' to build the symbol index.") unless graph

        if args["smart_context"] || args[:smart_context]
          ctx = graph.smart_context_for(query)
          return ctx.empty? ? "No smart context found for '#{query}'." : ctx
        end

        matches = if graph.respond_to?(:search_symbols)
                    graph.search_symbols(query)
                  else
                    graph.symbols.values.select { |sym| sym.name.downcase.include?(query.downcase) }
                  end

        if matches.empty?
          all_sym_names = graph.respond_to?(:symbols) ? graph.symbols.keys : []
          candidates = FuzzyMatcher.best_matches(query, all_sym_names)
          DiagnosticReporter.render_symbol_not_found(query, candidate_symbols: candidates)
        else
          matches.map do |sym|
            "• #{sym.kind.to_s.upcase} #{sym.name} (#{sym.file}:#{sym.line_start}-#{sym.line_end})\n  " \
              "Signature: #{sym.signature}\n  Calls: #{sym.calls.join(', ')}"
          end.join("\n\n")
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
        path = (args["file_path"] || args[:file_path] || args["path"] || args[:path]).to_s.strip
        return ToolOutput.error("File path is required.") if path.empty?

        graph = ast_graph
        return ToolOutput.error("AST graph is not available. Run '!context scan' to build the symbol index.") unless graph

        graph.outline_for(path)
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
        sym_name = (args["symbol_name"] || args[:symbol_name] || args["symbol"] || args[:symbol]).to_s.strip
        return ToolOutput.error("Symbol name is required.") if sym_name.empty?

        graph = ast_graph
        return ToolOutput.error("AST graph is not available. Run '!context scan' to build the symbol index.") unless graph

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
        sym_name = (args["symbol_name"] || args[:symbol_name] || args["symbol"] || args[:symbol]).to_s.strip
        return ToolOutput.error("Symbol name is required.") if sym_name.empty?

        graph = ast_graph
        return ToolOutput.error("AST graph is not available. Run '!context scan' to build the symbol index.") unless graph

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
