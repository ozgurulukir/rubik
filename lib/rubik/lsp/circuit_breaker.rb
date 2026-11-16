# frozen_string_literal: true

require "monitor"

module Rubik
  module LSP
    # Per-language circuit breaker for LSP server processes (extracted from
    # Manager, issue #497). After `MAX_CONSECUTIVE_CRASHES` consecutive
    # crashes the circuit opens and automatic restarts are refused for
    # `CIRCUIT_COOLDOWN_SECONDS`; sustained healthy operation
    # (`CIRCUIT_STABILITY_SECONDS` without a crash) retires the crash
    # history. Modeled on Orchestrator::ToolCircuitBreaker.
    #
    # Thread-safety: self-contained behind its own Monitor (a leaf object —
    # callers may hold their own locks around these calls without deadlock).
    class CircuitBreaker
      MAX_CONSECUTIVE_CRASHES = 3
      CIRCUIT_COOLDOWN_SECONDS = 300
      CIRCUIT_STABILITY_SECONDS = 60

      # `clock` overrides the monotonic time source (test seam); the Manager
      # wires it to its own `monotonic_now` so existing clock stubs keep
      # working.
      def initialize(clock: nil)
        @monitor = Monitor.new
        @clock = clock
        @crash_stats = {}
        @healthy_since = {}
      end

      # Live per-language crash-history hash ({ count:, last_crash_at:,
      # circuit_open: }); exposed for status reporting and test observability.
      attr_reader :crash_stats

      def open?(lang)
        lang_str = lang.to_s.downcase
        @monitor.synchronize do
          retire_if_stable!(lang_str)

          stat = @crash_stats[lang_str]
          return false unless stat && stat[:circuit_open]

          if stat[:last_crash_at] && (monotonic_now - stat[:last_crash_at] > CIRCUIT_COOLDOWN_SECONDS)
            stat[:circuit_open] = false
            stat[:count] = 0
            false
          else
            true
          end
        end
      end

      def record_crash(lang)
        lang_str = lang.to_s.downcase
        @monitor.synchronize do
          healthy_since = @healthy_since.delete(lang_str)
          @crash_stats.delete(lang_str) if healthy_since && monotonic_now - healthy_since >= CIRCUIT_STABILITY_SECONDS
          stat = (@crash_stats[lang_str] ||= { count: 0, last_crash_at: nil, circuit_open: false })
          stat[:count] += 1
          stat[:last_crash_at] = monotonic_now
          stat[:circuit_open] = true if stat[:count] >= MAX_CONSECUTIVE_CRASHES
        end
      end

      def note_healthy_start(lang)
        lang_str = lang.to_s.downcase
        @monitor.synchronize { @healthy_since[lang_str] = monotonic_now }
      end

      def reset!(lang)
        lang_str = lang.to_s.downcase
        @monitor.synchronize do
          @crash_stats.delete(lang_str)
          @healthy_since[lang_str] = monotonic_now
        end
      end

      # Drop crash history for a language that has run stably for
      # CIRCUIT_STABILITY_SECONDS. `open?` folds this in automatically.
      def retire_if_stable!(lang)
        lang_str = lang.to_s.downcase
        @monitor.synchronize do
          healthy_since = @healthy_since[lang_str]
          return unless healthy_since && monotonic_now - healthy_since >= CIRCUIT_STABILITY_SECONDS

          @crash_stats.delete(lang_str)
          @healthy_since.delete(lang_str)
        end
      end

      private

      def monotonic_now
        @clock ? @clock.call : Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
