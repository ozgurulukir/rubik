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
        super || @qualified_symbols[key]
      end

      # Checks whether a symbol key exists in either the plain or qualified symbol maps.
      #
      # @param key [String] the symbol name or qualified key to look up
      # @return [Boolean] true if the key is present in either map
      def key?(key)
        super || @qualified_symbols.key?(key)
      end

      # deprecated: use #key?; kept for callers using the legacy Hash#has_key? spelling.
      alias has_key? key?
    end

    class Graph
      def initialize
        @symbols = {}
        @qualified_symbols = {}
        @file_symbols = Hash.new { |h, k| h[k] = [] }
        @extraction_status = {}
        @mutex = Mutex.new
        @warmup_generation = 0
        @warmup_status = { state: :ready, indexed: 0, total: nil, generation: 0 }
      end

      # Last extraction status recorded for a file (issue #147): :ok,
      # :partial, :failed, or :unavailable. Lets callers tell "no symbols"
      # apart from "extraction failed" without re-running the extractor.
      def extraction_status(file_path)
        @mutex.synchronize { @extraction_status[file_path] }
      end

      def symbols
        @mutex.synchronize do
          SymbolMap.new(@symbols.dup, @qualified_symbols.dup)
        end
      end

      def file_symbols
        @mutex.synchronize do
          @file_symbols.each_with_object(Hash.new { |hash, path| hash[path] = [] }) do |(file_path, symbols), snapshot|
            snapshot[file_path] = symbols.dup
          end
        end
      end

      def clear
        @mutex.synchronize do
          @symbols.clear
          @qualified_symbols.clear
          @file_symbols.clear
          @extraction_status.clear
          @warmup_generation += 1
          @warmup_status = { state: :ready, indexed: 0, total: nil, generation: @warmup_generation }
        end
      end

      def index_file(file_path, content = nil)
        @mutex.synchronize do
          _index_file_unlocked(file_path, content)
        end
      end

      def remove_file(file_path)
        @mutex.synchronize do
          _remove_file_unlocked(file_path)
          @extraction_status.delete(file_path)
        end
      end

      def load_from_cache(cache_store)
        return 0 unless cache_store

        loaded_files = cache_store.load
        return 0 if loaded_files.nil? || loaded_files.empty?

        @mutex.synchronize do
          total_symbols = 0
          loaded_files.each do |file_path, syms|
            ext = File.extname(file_path).downcase
            lang = CacheStore::LANGUAGE_MAP[ext] || "code"

            @file_symbols[file_path] = syms.dup
            syms.each do |sym|
              @symbols[sym.name] = sym
              q_key = "#{lang}:#{file_path}##{sym.name}"
              @qualified_symbols[q_key] = sym
              total_symbols += 1
            end
          end
          total_symbols
        end
      end

      def save_to_cache(cache_store)
        return false unless cache_store

        snapshot = @mutex.synchronize do
          @file_symbols.each_with_object({}) do |(file_path, symbols), copy|
            copy[file_path] = symbols.dup
          end
        end
        cache_store.save(snapshot)
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
          syms = _index_file_unlocked(file_path) if syms.empty? && File.exist?(file_path)

          return "No symbols found in '#{file_path}'." if syms.empty?

          lines = ["=== Outline for #{file_path} (#{syms.size} symbols) ==="]
          syms.sort_by(&:line_start).each do |sym|
            indent = [:class, :struct, :module, :interface, :type].include?(sym.kind) ? "" : "  "
            lines << "#{indent}• [#{sym.kind.to_s.upcase}] #{sym.name} (lines #{sym.line_start}-#{sym.line_end}) -> #{sym.signature}"
          end
          lines.join("\n")
        end
      end

      private

      def _index_file_unlocked(file_path, content = nil)
        result = Extractor.extract_result(file_path, content)
        @extraction_status[file_path] = result.status

        # A failed extraction must not silently DELETE the file's previously
        # indexed symbols (issue #147): stale-but-known beats unknown, and
        # the log line makes the downgrade visible. The best-effort symbols
        # are only indexed when there is nothing to protect.
        if result.status == :failed
          existing = _get_file_symbols_unlocked(file_path)
          unless existing.empty?
            Rubik::Log.warn(:ast, "extraction failed for #{file_path} (#{result.detail}); keeping previously indexed symbols")
            return existing
          end
          Rubik::Log.warn(:ast, "extraction failed for #{file_path} (#{result.detail}); no symbols indexed")
        end

        _remove_file_unlocked(file_path)

        ext = File.extname(file_path).downcase
        lang = CacheStore::LANGUAGE_MAP[ext] || "code"

        extracted = result.symbols
        extracted.each do |sym|
          @symbols[sym.name] = sym
          q_key = "#{lang}:#{file_path}##{sym.name}"
          @qualified_symbols[q_key] = sym
          @file_symbols[file_path] << sym
        end
        extracted
      end

      def _remove_file_unlocked(file_path)
        existing = @file_symbols.delete(file_path)
        if existing.nil? || existing.empty?
          canonical_target = Rubik::Platform.normalize_path(File.expand_path(file_path))
          matching_key = @file_symbols.keys.find do |k|
            Rubik::Platform.path_equal?(k, file_path) ||
              Rubik::Platform.normalize_path(File.expand_path(k)) == canonical_target
          end
          existing = @file_symbols.delete(matching_key) if matching_key
        end

        return unless existing && !existing.empty?

        ext = File.extname(file_path).downcase
        lang = CacheStore::LANGUAGE_MAP[ext] || "code"

        existing.each do |sym|
          @symbols.delete(sym.name) if @symbols[sym.name] == sym
          @qualified_symbols.delete("#{lang}:#{file_path}##{sym.name}")
          @qualified_symbols.delete("#{lang}:#{sym.file}##{sym.name}") if sym.file
        end
      end

      def _get_file_symbols_unlocked(file_path)
        syms = @file_symbols[file_path]
        return syms if syms && !syms.empty?

        canonical_target = Rubik::Platform.normalize_path(File.expand_path(file_path))
        matching_key = @file_symbols.keys.find do |k|
          Rubik::Platform.path_equal?(k, file_path) ||
            Rubik::Platform.normalize_path(File.expand_path(k)) == canonical_target
        end
        (matching_key && @file_symbols[matching_key]) || []
      end
    end
  end
end

require_relative "graph_extensions"
