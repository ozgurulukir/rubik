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
        @targets.any?(StringIO)
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
        ordered_targets.each do |target|
          target.flush if target.respond_to?(:flush)
        rescue StandardError => e
          drop_failed_target(target, :flush, e)
        end
        nil
      end

      # Returns "" by design when every recorder has been detached by the
      # failure policy — a degraded transcript, never a raise.
      def string
        target = @targets.find { |t| t.respond_to?(:string) }
        target&.string || ""
      end

      def reopen(*args)
        @targets.each { |t| t.reopen(*args) if t.respond_to?(:reopen) }
      end

      private

      # User-facing streams first, recorders (StringIO captures) last: the
      # recorder must survive a dead user stream and keep its copy of the
      # transcript. Ordering only affects failure isolation — tee semantics
      # deliver identical bytes to every target either way.
      def ordered_targets
        recorders, users = @targets.partition { |t| t.is_a?(StringIO) }
        users + recorders
      end

      def dispatch(method, args)
        ordered_targets.each do |target|
          if target.is_a?(StringIO)
            target.public_send(method, *strip_args(args))
          else
            target.public_send(method, *args)
          end
        rescue StandardError => e
          # One broken target (closed pipe, EPIPE) must never kill the tee:
          # warn once, detach it, keep the remaining targets — the recorder
          # keeps its copy even when the user stream dies.
          drop_failed_target(target, method, e)
        end
      end

      def drop_failed_target(target, method, exception)
        @targets.delete(target)
        warn "[rubik] tee target failed during ##{method} (#{exception.class}: #{exception.message}); detached from output"
      end

      def strip_args(args)
        args.map { |a| a.is_a?(String) ? Rubik::UI::Capability.strip_ansi(a) : a }
      end
    end
  end
end
