# frozen_string_literal: true

require_relative "symbol"
require_relative "extractor"
require_relative "cache_store"

module Rubik
  module AST
    class SymbolMap < Hash
      attr_reader :qualified_symbols

      def initialize(plain = {}, qualified = {})
        super()
        @qualified_symbols = qualified
        replace(plain)
      end

      def [](key)
        super(key) || @qualified_symbols[key]
      end

      def key?(key)
        super(key) || @qualified_symbols.key?(key)
      end

      def has_key?(key)
        super(key) || @qualified_symbols.has_key?(key)
      end
    end

    class Graph
      def initialize
        @symbols = {}
        @qualified_symbols = {}
        @file_symbols = Hash.new { |h, k| h[k] = [] }
        @mutex = Mutex.new
      end

      def symbols
        @mutex.synchronize do
          SymbolMap.new(@symbols.dup, @qualified_symbols.dup)
        end
      end

      def file_symbols
        @mutex.synchronize { @file_symbols.dup }
      end

      def index_file(file_path, content = nil)
        @mutex.synchronize do
          _index_file_unlocked(file_path, content)
        end
      end

      def remove_file(file_path)
        @mutex.synchronize do
          _remove_file_unlocked(file_path)
        end
      end

      def load_from_cache(cache_store)
        return 0 unless cache_store

        loaded_files = cache_store.load
        return 0 if loaded_files.nil? || loaded_files.empty?

        @mutex.synchronize do
          total_symbols = 0
          loaded_files.each do |file_path, syms|
            _remove_file_unlocked(file_path)
            ext = File.extname(file_path).downcase
            lang = CacheStore::LANGUAGE_MAP[ext] || "code"

            syms.each do |sym|
              @symbols[sym.name] = sym
              q_key = "#{lang}:#{file_path}##{sym.name}"
              @qualified_symbols[q_key] = sym
              @file_symbols[file_path] << sym
              total_symbols += 1
            end
          end
          total_symbols
        end
      end

      def save_to_cache(cache_store)
        return false unless cache_store

        snapshot = @mutex.synchronize { @file_symbols.dup }
        cache_store.save(snapshot)
      end

      def callers_of(symbol_name)
        @mutex.synchronize do
          result = []
          @symbols.values.uniq.each do |sym|
            if sym.calls.include?(symbol_name) ||
               sym.calls.any? { |c| c.end_with?("##{symbol_name}") || c.end_with?(".#{symbol_name}") || symbol_name.end_with?("##{c}") || symbol_name.end_with?(".#{c}") }
              result << sym
            end
          end
          result
        end
      end

      def smart_context_for(symbol_name)
        @mutex.synchronize do
          target = @symbols[symbol_name] ||
                   @qualified_symbols[symbol_name] ||
                   @symbols.values.find { |s| s.name == symbol_name || s.name.end_with?("##{symbol_name}") }
          return "" unless target

          context_blocks = []
          context_blocks << "# Target symbol: #{target.name} (#{target.file}:#{target.line_start}-#{target.line_end})"
          context_blocks << target.body if target.body

          target.calls.each do |called_name|
            matching = @symbols[called_name] ||
                       @qualified_symbols[called_name] ||
                       @symbols.values.find { |s| s.name == called_name || s.name.end_with?("##{called_name}") }
            if matching
              context_blocks << "# Dependency signature: #{matching.name}"
              context_blocks << matching.signature
            end
          end

          context_blocks.join("\n\n")
        end
      end

      def outline_for(file_path)
        @mutex.synchronize do
          syms = _get_file_symbols_unlocked(file_path)
          if syms.empty? && File.exist?(file_path)
            syms = _index_file_unlocked(file_path)
          end

          return "No symbols found in '#{file_path}'." if syms.empty?

          lines = ["=== Outline for #{file_path} (#{syms.size} symbols) ==="]
          syms.sort_by(&:line_start).each do |sym|
            indent = %i[class struct module interface type].include?(sym.kind) ? "" : "  "
            lines << "#{indent}• [#{sym.kind.to_s.upcase}] #{sym.name} (lines #{sym.line_start}-#{sym.line_end}) -> #{sym.signature}"
          end
          lines.join("\n")
        end
      end

      def symbol_definition(symbol_name)
        @mutex.synchronize do
          target = @symbols[symbol_name] ||
                   @qualified_symbols[symbol_name] ||
                   @symbols.values.find do |s|
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

      private

      def _index_file_unlocked(file_path, content = nil)
        _remove_file_unlocked(file_path)

        extracted = Extractor.extract(file_path, content)
        ext = File.extname(file_path).downcase
        lang = CacheStore::LANGUAGE_MAP[ext] || "code"

        extracted.each do |sym|
          @symbols[sym.name] = sym
          q_key = "#{lang}:#{file_path}##{sym.name}"
          @qualified_symbols[q_key] = sym
          @file_symbols[file_path] << sym
        end
        extracted
      end

      def _remove_file_unlocked(file_path)
        existing = @file_symbols.delete(file_path) || []
        if existing.empty?
          matching_key = @file_symbols.keys.find { |k| k == file_path || k.end_with?("/#{file_path}") || file_path.end_with?("/#{k}") }
          existing = @file_symbols.delete(matching_key) || [] if matching_key
        end

        existing.each do |sym|
          @symbols.delete(sym.name) if @symbols[sym.name] == sym
          @qualified_symbols.delete_if { |_k, v| v == sym }
        end
      end

      def _get_file_symbols_unlocked(file_path)
        syms = @file_symbols[file_path] || []
        if syms.empty?
          matching_key = @file_symbols.keys.find { |k| k == file_path || k.end_with?("/#{file_path}") || file_path.end_with?("/#{k}") }
          syms = @file_symbols[matching_key] if matching_key
        end
        syms
      end
    end
  end
end
