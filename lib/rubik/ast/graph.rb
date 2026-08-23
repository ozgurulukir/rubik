# frozen_string_literal: true

require_relative "symbol"
require_relative "extractor"

module Rubik
  module AST
    class Graph
      attr_reader :symbols, :file_symbols

      def initialize
        @symbols = {}
        @file_symbols = Hash.new { |h, k| h[k] = [] }
      end

      def index_file(file_path, content = nil)
        remove_file(file_path)

        extracted = Extractor.extract(file_path, content)
        extracted.each do |sym|
          @symbols[sym.name] = sym
          @file_symbols[file_path] << sym
        end
        extracted
      end

      def remove_file(file_path)
        existing = @file_symbols.delete(file_path) || []
        existing.each do |sym|
          @symbols.delete(sym.name)
        end
      end

      def callers_of(symbol_name)
        result = []
        @symbols.each_value do |sym|
          if sym.calls.include?(symbol_name) ||
             sym.calls.any? { |c| c.end_with?("##{symbol_name}") || c.end_with?(".#{symbol_name}") || symbol_name.end_with?("##{c}") || symbol_name.end_with?(".#{c}") }
            result << sym
          end
        end
        result
      end

      def smart_context_for(symbol_name)
        target = @symbols[symbol_name]
        return "" unless target

        context_blocks = []
        context_blocks << "# Target symbol: #{target.name} (#{target.file}:#{target.line_start}-#{target.line_end})"
        context_blocks << target.body if target.body

        target.calls.each do |called_name|
          matching = @symbols.values.find { |s| s.name == called_name || s.name.end_with?("##{called_name}") }
          if matching
            context_blocks << "# Dependency signature: #{matching.name}"
            context_blocks << matching.signature
          end
        end

        context_blocks.join("\n\n")
      end

      def outline_for(file_path)
        syms = @file_symbols[file_path] || []
        if syms.empty?
          matching_key = @file_symbols.keys.find { |k| k == file_path || k.end_with?("/#{file_path}") || file_path.end_with?("/#{k}") }
          syms = @file_symbols[matching_key] if matching_key
        end
        if syms.empty? && File.exist?(file_path)
          syms = index_file(file_path)
        end

        return "No symbols found in '#{file_path}'." if syms.empty?

        lines = ["=== Outline for #{file_path} (#{syms.size} symbols) ==="]
        syms.sort_by(&:line_start).each do |sym|
          indent = %i[class struct module].include?(sym.kind) ? "" : "  "
          lines << "#{indent}• [#{sym.kind.to_s.upcase}] #{sym.name} (lines #{sym.line_start}-#{sym.line_end}) -> #{sym.signature}"
        end
        lines.join("\n")
      end

      def symbol_definition(symbol_name)
        target = @symbols[symbol_name] || @symbols.values.find do |s|
          s.name.downcase == symbol_name.downcase ||
            s.name.end_with?("##{symbol_name}") ||
            s.name.end_with?(".#{symbol_name}")
        end
        return nil unless target

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
  end
end
