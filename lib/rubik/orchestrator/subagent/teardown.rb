# frozen_string_literal: true

require_relative "notices"

module Rubik
  module Orchestrator
    module Subagent
      # Instance teardown choreography, extracted from instance.rb (module
      # hygiene; issue #125 added the cancellation notice and the
      # operator-cancelled flag here): kill request (one terminal outcome per
      # execution, thread kill), idempotent cleanup, and the monitor-guarded
      # context disposal. Disposal itself stays LIFO + error-isolated inside
      # Runtime::Context; cleanup_context only guarantees it runs exactly once.
      module Teardown
        # True when an OPERATOR kill (not a natural settle) stopped this
        # execution. The completion handler reads it to suppress its own
        # settle notice, so one execution never produces two terminal
        # outcomes (issue #125).
        def cancelled_by_operator? = @monitor.synchronize { @cancelled_by_operator }

        def kill
          announce = false
          @monitor.synchronize do
            return true if disposed?

            announce = !settled?
            @cancelled_by_operator ||= announce
            transition!(:canceling)
            @ended_at = Time.now
            @budget_cond.broadcast
            @error_cond.broadcast
          end

          # The cancellation announcement belongs to the kill path (the
          # operator act), not to the completion choreography: it is emitted
          # exactly once, and only when the run had not already settled.
          if announce
            Notices.emit(@event_bus, Notices::COMPLETED_EVENT,
                         { id: @id, role: @role, state: :cancelled, max_steps: @budget.max_steps })
          end
          @journal&.record_cancelled(run: @run_seq, reason: "kill requested by maestro")

          begin; @thread&.kill if @thread&.alive?; rescue StandardError; nil; end

          cleanup
          true
        end

        def cleanup
          @monitor.synchronize do
            return if disposed?

            @budget_cond.broadcast
            @error_cond.broadcast
            cleanup_context
            transition!(:disposed)
          end
        end

        # Idempotent under monitor: check-and-set of @context_cleaned_up
        # (ensure block vs kill cleanup race).
        def cleanup_context
          @monitor.synchronize do
            return if @context_cleaned_up

            @context_cleaned_up = true
            begin
              @context&.dispose unless @context&.disposed?
            rescue StandardError => e
              @last_error ||= "#{e.class}: #{e.message}"
            end
          end
        end
      end
    end
  end
end
