# frozen_string_literal: true

module Rubik
  module Tools
    # A String tool output that carries an explicit error classification.
    #
    # Why a String subclass: the historical builtin-tool contract returns
    # plain Strings, and StepExecutor inferred success/failure by sniffing
    # ERROR_PREFIXES — real failures ("AST graph is not available", "LSP
    # manager is not connected", argument-validation messages) were silently
    # labeled status="ok" in the tool_result envelope. ToolOutput keeps every
    # existing string consumer (tests, Truncator, formatters) working while
    # letting StepExecutor's existing `respond_to?(:error?)` branch classify
    # the result correctly.
    class ToolOutput < String
      def self.ok(text)
        new(text.to_s, is_error: false)
      end

      def self.error(text)
        new(text.to_s, is_error: true)
      end

      # Display-output contract: the full text is meant for the USER'S
      # terminal, not for the model's context. StepExecutor emits it as a
      # :user_output event and feeds only the short stub back into history.
      def self.display(text, stub:)
        new(text.to_s, is_error: false, display_stub: stub)
      end

      def initialize(text = "", is_error: false, display_stub: nil)
        super(text)
        @is_error = is_error ? true : false
        @display_stub = display_stub
      end

      def error?
        @is_error
      end

      def ok?
        !@is_error
      end

      def user_display?
        !@display_stub.nil?
      end

      def display_stub
        @display_stub.to_s
      end
    end
  end
end
