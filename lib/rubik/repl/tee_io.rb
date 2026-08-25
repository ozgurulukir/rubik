# frozen_string_literal: true

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

      def puts(*args)
        @targets.each { |t| t.puts(*args) }
      end

      def print(*args)
        @targets.each { |t| t.print(*args) }
      end

      def printf(*args)
        @targets.each { |t| t.printf(*args) }
      end

      # Writes data to all underlying IO targets simultaneously.
      #
      # @param args [Array<String>] one or more strings to write
      # @return [void]
      def write(*args)
        @targets.each { |t| t.write(*args) }
      end

      def flush
        @targets.each(&:flush) rescue nil
      end

      def string
        target = @targets.find { |t| t.respond_to?(:string) }
        target&.string || ""
      end

      def reopen(*args)
        @targets.each { |t| t.reopen(*args) if t.respond_to?(:reopen) }
      end
    end
  end
end
