# frozen_string_literal: true

module Rubik
  module REPL
    class TeeIO
      def initialize(*targets)
        @targets = targets.compact
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
