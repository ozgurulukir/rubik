# frozen_string_literal: true

require_relative "../task_cancellation"
require_relative "notices"

module Rubik
  module Orchestrator
    module Subagent
      # Task ownership and cancellation choreography (issue #125). The
      # supervisor already knows every execution; this seam answers "which
      # executions belong to this token" and stops exactly those. Work that was
      # explicitly detached carries its own never-cancelled token and work
      # spawned under a different turn carries a different token, so both are
      # untouched by construction.
      #
      # The outcome reports the three states the UI needs: cancellation
      # requested (the token), complete (nothing remains), and incomplete
      # cleanup (threads that did not settle inside the grace period — they are
      # force-killed AND named, so a stuck execution is never silently lost).
      module TaskOwnershipSupervisor
        CancellationOutcome = Struct.new(:cancelled, :stopped, :remaining, :queued_cancelled, keyword_init: true) do
          def any? = !(stopped.empty? && remaining.empty? && queued_cancelled.empty?)
          def complete? = remaining.empty?
        end

        # Stop every owned descendant within the configured grace period, then
        # force-kill stragglers and report the remainder. Queued specs of the
        # token are cancelled before they ever start.
        def cancel_owned(token, timeout: nil)
          return CancellationOutcome.new(cancelled: false, stopped: [], remaining: [], queued_cancelled: []) unless token

          token.cancel!("foreground task cancelled (^C)")
          stopped = []
          deadline = Time.now + [timeout.to_f, 0.0].max
          loop do
            targets = @monitor.synchronize do
              @instances.values.select { |inst| owned_by?(inst, token) && !cancellation_settled?(inst) }
            end
            targets.each(&:kill)
            # A killed execution is disposed synchronously; a completion
            # handler may already have swept it from the roster, so the stopped
            # set is collected HERE, not derived from the final roster.
            targets.each { |inst| stopped << inst.id if cancellation_settled?(inst) }
            break if targets.empty? || Time.now >= deadline

            sleep 0.01
          end

          queued = cancel_queued_specs(token)
          remaining = @monitor.synchronize do
            (@instances.values + (@finished || {}).values).select do |inst|
              owned_by?(inst, token) && !cancellation_settled?(inst)
            end
          end
          CancellationOutcome.new(cancelled: true,
                                  stopped: stopped.uniq,
                                  remaining: remaining.map { |inst| { id: inst.id, state: inst.state.to_s } },
                                  queued_cancelled: queued)
        end

        # A stopped execution is either disposed (the kill path completed) or
        # settled naturally. Anything else is remaining work and must be named.
        def cancellation_settled?(instance)
          return true if instance.respond_to?(:disposed?) && instance.disposed?

          instance.terminal_and_settled?
        end

        def owned_by?(instance, token)
          instance.respond_to?(:owner_task) && instance.owner_task.equal?(token)
        end

        # Claim fence: a pending spec whose owner was cancelled never starts.
        # Called under the supervisor monitor by the dependency claim loops.
        def owned_claim_blocked?(spec)
          spec.respond_to?(:owner) && spec.owner&.cancelled?
        end

        # Guard for new owned work: refuse before anything is reserved.
        def refute_cancelled_owner!(token)
          return unless token&.cancelled?

          raise TaskCancelledError,
                "task was cancelled (^C) — new owned work is refused; pass detach: true to run it independently of this task"
        end

        private

        # Cancel queued specs owned by the token and report their ids (the
        # dependency wave that follows is announced by the same helper the
        # dead-predecessor path uses).
        def cancel_queued_specs(token)
          queued = @monitor.synchronize do
            specs = @deferred.values.select { |spec| spec.respond_to?(:owner) && spec.owner.equal?(token) }
            specs.each { |spec| cancel_spec!(spec, "owner task cancelled (^C)") }
            specs
          end
          announce_cancellations(queued)
          queued.map(&:id)
        end
      end
    end
  end
end
