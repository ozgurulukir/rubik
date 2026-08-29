# frozen_string_literal: true

require_relative "../ui/capability"

module Rubik
  module REPL
    class TeeIO
      attr_reader :targets

      def initialize(*targets)
        @targets = targets.compact
      end

      def string_io?
        @targets.any? { |t| t.is_a?(StringIO) }
      end

      # Public predicate for test capture detection. Returns true when
      # the TeeIO is being used to capture output into a StringIO
      # buffer (typically in tests). The Shell and agent commands
      # use this to short-circuit interactive yes/no prompts to
      # "no" without inspecting the implementation details.
      def test_capture?
        string_io? || @targets.empty?
      end

      def puts(*args)
        dispatch(:puts, args)
      end

      def print(*args)
        dispatch(:print, args)
      end

      def printf(*args)
        dispatch(:printf, args)
      end

      # Writes data to all underlying IO targets simultaneously.
      # StringIO targets (session capture, conversation recording) receive
      # ANSI-stripped content so recordings and LLM context stay clean.
      #
      # @param args [Array<String>] one or more strings to write
      # @return [void]
      def write(*args)
        dispatch(:write, args)
      end

      def flush
        @targets.each(&:flush)
      rescue
        nil
      end

      def string
        target = @targets.find { |t| t.respond_to?(:string) }
        target&.string || ""
      end

      def reopen(*args)
        @targets.each { |t| t.reopen(*args) if t.respond_to?(:reopen) }
      end

      private

      def dispatch(method, args)
        @targets.each do |target|
          if target.is_a?(StringIO)
            target.public_send(method, *strip_args(args))
          else
            target.public_send(method, *args)
          end
        end
      end

      def strip_args(args)
        args.map { |a| a.is_a?(String) ? Rubik::UI::Capability.strip_ansi(a) : a }
      end
    end
  end
end
