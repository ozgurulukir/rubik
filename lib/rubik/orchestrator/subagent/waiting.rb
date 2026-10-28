# frozen_string_literal: true

require_relative "notices"

module Rubik
  module Orchestrator
    module Subagent
      # Wait semantics (issue #126): waiting already knew when it returned; now
      # it reports WHY — settled, deadline (targets still active), an actionable
      # pause, a dependency queue, or unknown ids. The supervisor keeps
      # wait_for (rows only) for its existing callers; the tool surface reads
      # the reason so the model gets a truthful next action instead of guessing
      # whether a timeout meant failure.
      module WaitSupervisor
        WaitOutcome = Struct.new(:reason, :rows, :paused, :active, keyword_init: true) do
          def settled? = reason == :settled
        end

        def wait_for(ids = nil, timeout: Notices::DEFAULT_WAIT_TIMEOUT, wait_for_budget: true)
          wait(ids, timeout: timeout, wait_for_budget: wait_for_budget).rows
        end

        def notify_wait!
          @monitor.synchronize { @wait_cond&.broadcast }
        end

        def wait(ids = nil, timeout: Notices::DEFAULT_WAIT_TIMEOUT, wait_for_budget: true)
          target_ids = Array(ids).compact.map(&:to_s)
          deadline = Time.now + [timeout.to_i, 1].max

          @monitor.synchronize do
            loop do
              candidates = target_ids.empty? ? @instances.values : target_ids.filter_map { |id| @instances[id] }
              active_targets = candidates.select do |inst|
                inst.active? && !inst.error_paused? && !inst.awaiting_human? && (!wait_for_budget || !inst.awaiting_budget?)
              end

              # Kuyruğa takılı hedefler wait'i canlı tutar (zincir bitene dek).
              rem = deadline - Time.now
              break if (active_targets.empty? && !deferred_pending?(target_ids)) || rem <= 0

              if @wait_cond
                @wait_cond.wait([rem, 0].max)
              else
                sleep [rem, 0.1].min
              end
            end

            candidates = target_ids.empty? ? @instances.values : target_ids.filter_map { |id| @instances[id] || queued_spec(id) }
            paused = candidates.select { |c| parked_candidate?(c) }
            active = candidates.select { |c| c.respond_to?(:active?) && c.active? }
            WaitOutcome.new(reason: wait_reason(target_ids, candidates, active, deadline),
                            rows: candidates.map(&:to_h),
                            paused: paused.map(&:id),
                            active: active.map(&:id))
          end
        end

        private

        # The returned-fact classification, derived from what was observed —
        # never from a guess about the model's intent.
        def wait_reason(target_ids, candidates, active, deadline)
          return :unknown if target_ids.any? && candidates.empty?
          return :deadline if Time.now >= deadline && active.any?
          return :paused if candidates.any? { |c| parked_candidate?(c) }
          return :queued if candidates.any? { |c| c.respond_to?(:queued?) && c.queued? }

          :settled
        end

        def parked_candidate?(candidate)
          (candidate.respond_to?(:error_paused?) && candidate.error_paused?) ||
            (candidate.respond_to?(:awaiting_human?) && candidate.awaiting_human?) ||
            (candidate.respond_to?(:awaiting_budget?) && candidate.awaiting_budget?)
        end
      end
    end
  end
end
