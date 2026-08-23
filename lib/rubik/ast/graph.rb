# frozen_string_literal: true

require_relative "symbol"
require_relative "ruby_extractor"

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

        extracted = RubyExtractor.extract(file_path, content)
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
          result << sym if sym.calls.include?(symbol_name)
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
    end
  end
end
