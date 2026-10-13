# frozen_string_literal: true

require "monitor"

module Rubik
  module Orchestrator
    # Foreground task cancellation token (issue #125).
    #
    # A foreground turn (or any explicit task scope) owns the subagents it
    # spawns: the token is provided into the runtime context for the turn's
    # duration and inherited — transitively — by the child contexts of the
    # spawned subagents, so nested spawns remain owned by the same task. The
    # interrupt handler cancels the token and the supervisor stops every
    # execution still carrying it; work that was explicitly detached (no
    # owner) or spawned under a different token is untouched by construction.
    #
    # The token is a leaf: no dependencies, no callbacks, no IO — cancellation
    # REQUEST state only. The supervisor owns the stop choreography and the
    # outcome report (cancellation-requested → complete / remaining), keeping
    # this object honest about what it knows.
    class TaskCancellation
      attr_reader :id, :reason, :cancelled_at

      # The owner of explicitly detached work: a token that can never be
      # cancelled, provided into a detached subagent's child context so its
      # own descendants inherit the detachment instead of the turn's token.
      def self.detached
        new(id: "task-detached-#{Process.pid}-#{rand(1000..9999)}", detached: true)
      end

      def initialize(id: nil, detached: false)
        @id = id || "task-#{Process.pid}-#{Time.now.to_i}-#{rand(1000..9999)}"
        @detached = detached
        @monitor = Monitor.new
        @cancelled = false
        @reason = nil
        @cancelled_at = nil
      end

      def cancelled? = @monitor.synchronize { @cancelled }

      def detached? = @detached

      # Idempotent: the first cancel wins (its reason/timestamp is the record),
      # later calls report false and change nothing.
      def cancel!(reason = "foreground task cancelled (^C)")
        @monitor.synchronize do
          return false if @cancelled

          @cancelled = true
          @reason = reason.to_s
          @cancelled_at = Time.now
          true
        end
      end
    end
  end
end
