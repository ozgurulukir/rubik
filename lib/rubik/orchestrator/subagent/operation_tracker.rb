# frozen_string_literal: true

require "monitor"
require "time"

module Rubik
  module Orchestrator
    module Subagent
      # Operation-level telemetry (issue #126): what an execution is doing
      # RIGHT NOW and how its time split between model waits and tool runs,
      # measured with a monotonic clock (injectable for tests). Pure state —
      # no IO, no notices, no locks shared with the instance; the status and
      # wait surfaces read snapshots from here instead of guessing whether an
      # execution is stalled.
      class OperationTracker
        MODEL = "model"
        TOOL = "tool"
        EMPTY_TIMINGS = { "model_seconds" => 0.0, "tool_seconds" => 0.0, "model_calls" => 0, "tool_calls" => 0 }.freeze

        def initialize(clock: nil)
          @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
          @monitor = Monitor.new
          @current = nil
          @timings = EMPTY_TIMINGS.dup
          @last_progress_at = nil
        end

        # Marks the start of an in-flight operation. detail is already
        # redacted/clipped by the caller (it is model-visible telemetry).
        def start(kind, name: nil, detail: nil)
          now = @clock.call
          @monitor.synchronize do
            @current = { kind: kind.to_s, name: name.to_s, detail: detail.to_s.empty? ? nil : detail.to_s,
                         started_at: Time.now.utc.iso8601(3), started_monotonic: now }
            @last_progress_at = now
          end
        end

        # Ends the tracked operation and accumulates its duration into the
        # matching model/tool bucket. Returns the elapsed seconds, or nil when
        # the operation is not the one being tracked (e.g. after a reset).
        def finish(kind)
          @monitor.synchronize do
            return nil unless @current && @current[:kind] == kind.to_s

            elapsed = [@clock.call - @current[:started_monotonic], 0.0].max
            bucket = kind.to_s == MODEL ? "model_seconds" : "tool_seconds"
            counter = kind.to_s == MODEL ? "model_calls" : "tool_calls"
            @timings[bucket] = (@timings[bucket] + elapsed).round(3)
            @timings[counter] += 1
            @current = nil
            # Completing an operation is observable progress too.
            @last_progress_at = @clock.call
            elapsed
          end
        end

        def progress!
          now = @clock.call
          @monitor.synchronize { @last_progress_at = now }
        end

        # A redeployed run is a new lineage: no stale operation, fresh buckets.
        def reset!
          @monitor.synchronize do
            @current = nil
            @timings = EMPTY_TIMINGS.dup
            @last_progress_at = nil
          end
        end

        # JSON-ready snapshot of the in-flight operation (nil when idle).
        def current
          @monitor.synchronize do
            return nil unless @current

            { kind: @current[:kind], name: @current[:name], detail: @current[:detail],
              started_at: @current[:started_at],
              elapsed_seconds: [@clock.call - @current[:started_monotonic], 0.0].max.round(3) }
          end
        end

        def timings = @monitor.synchronize { @timings.dup }

        def last_progress_seconds_ago
          @monitor.synchronize do
            @last_progress_at ? [@clock.call - @last_progress_at, 0.0].max.round(3) : nil
          end
        end
      end
    end
  end
end
