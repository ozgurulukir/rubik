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
          line_range: [@line_start, @line_end],
          signature: @signature,
          calls: @calls
        }
      end
    end
  end
end
