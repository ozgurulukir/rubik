# frozen_string_literal: true

module Rubik
  module AST
    class Symbol
      attr_reader :name, :kind, :file, :line_start, :line_end, :signature, :calls, :docstring

      def initialize(name:, kind:, file:, line_start:, line_end:, signature: nil, calls: [], body: nil, docstring: nil)
        @name = name
        @kind = kind.to_sym
        @file = file
        @line_start = line_start
        @line_end = line_end
        @signature = signature || name
        @calls = calls || []
        @body = body
        @docstring = docstring
      end

      # In-memory symbols carry the extracted body; cache-loaded symbols do
      # not (bodies are excluded from the persistent index to keep it small).
      # For the latter, read the recorded line range from source on demand.
      def body
        return @body unless @body.nil?

        @body = self.class.read_source_range(@file, @line_start, @line_end)
      end

      def self.read_source_range(file, l_start, l_end)
        return nil unless file && l_start && File.exist?(file)

        lines = File.readlines(file)
        selected = lines[(l_start - 1)..(l_end - 1)] if l_start >= 1
        selected&.join
      rescue StandardError
        nil
      end

      # `include_body: false` skips the lazy source read — used by the cache
      # writer, which never persists bodies (reading every indexed file just
      # to drop the result would be pure waste).
      def to_h(include_body: true)
        {
          name: @name,
          kind: @kind,
          file: @file,
          line_start: @line_start,
          line_end: @line_end,
          line_range: [@line_start, @line_end],
          signature: @signature,
          calls: @calls,
          body: include_body ? body : nil,
          docstring: @docstring
        }
      end

      def self.from_h(hash, default_file = nil)
        l_start = hash["line_start"] || hash[:line_start] || (hash["line_range"] || hash[:line_range])&.first || 1
        l_end = hash["line_end"] || hash[:line_end] || (hash["line_range"] || hash[:line_range])&.last || l_start
        new(
          name: hash["name"] || hash[:name],
          kind: (hash["kind"] || hash[:kind] || :function).to_sym,
          file: hash["file"] || hash[:file] || default_file,
          line_start: l_start,
          line_end: l_end,
          signature: hash["signature"] || hash[:signature],
          calls: hash["calls"] || hash[:calls] || [],
          body: hash["body"] || hash[:body],
          docstring: hash["docstring"] || hash[:docstring]
        )
      end
    end
  end
end
