# frozen_string_literal: true

module Rubik
  module AST
    class Symbol
      attr_reader :name, :kind, :file, :line_start, :line_end, :signature, :calls, :body, :docstring

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

      def to_h
        {
          name: @name,
          kind: @kind,
          file: @file,
          line_start: @line_start,
          line_end: @line_end,
          line_range: [@line_start, @line_end],
          signature: @signature,
          calls: @calls,
          body: @body,
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
