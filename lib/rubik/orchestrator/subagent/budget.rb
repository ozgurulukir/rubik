# frozen_string_literal: true

require "monitor"

module Rubik
  module Orchestrator
    module Subagent
      # Step-budget state machine for a subagent Instance (architecture-review
      # Candidate 04): owns max_steps/current_step/warned and their entire
      # invariant set — initial normalization, consumption, exhaustion, the
      # once-per-epoch 75% warning latch, and grant (normalize -> floor -> +=
      # -> re-arm).
      #
      # Kinship: the main loop's Orchestrator::BudgetManager implements the
      # identical 75% arithmetic as a STATELESS collaborator over Loop-held
      # state, emitting XML into the main history. This class is the OWNING
      # variant for the subagent path (different owner, different channel:
      # a subagent-local user message). The two stay separate by the
      # stateless-over-owner doctrine; do not merge them.
      #
      # Concurrency contract: every method synchronizes on this object's
      # Monitor. Lock order is ALWAYS instance -> budget: callers may hold
      # the Instance monitor while calling in (grant_budget!, to_h, pause);
      # Budget never calls back into Instance, so no inverse order exists.
      # Grants are monotone and the worker thread is the sole consumer, so
      # separately-locked operations compose without a global transaction.
      class Budget
        DEFAULT_MAX_STEPS = 88
        DEFAULT_GRANT_STEPS = 20
        WARN_RATIO = 0.75

        def initialize(max_steps: nil)
          @max_steps = (max_steps || DEFAULT_MAX_STEPS).to_i
          @current_step = 0
          @warned = false
          @monitor = Monitor.new
        end

        def max_steps
          @monitor.synchronize { @max_steps }
        end

        def current_step
          @monitor.synchronize { @current_step }
        end

        def warned?
          @monitor.synchronize { @warned }
        end

        def exhausted?
          @monitor.synchronize { @current_step >= @max_steps }
        end

        # Enter the next step; returns the new current_step.
        def consume
          @monitor.synchronize { @current_step += 1 }
        end

        # Check-compute-latch atomically: returns the pinned 75% warning
        # message exactly once per budget epoch, nil otherwise. The threshold
        # is recomputed at call time so a mid-run grant re-aims the checkpoint
        # at the new budget's 75% point (grant! re-arms the latch).
        def take_step_warning!
          @monitor.synchronize do
            warn_step = (@max_steps * WARN_RATIO).ceil
            return nil if @warned || @current_step < warn_step || @current_step >= @max_steps

            @warned = true
            remaining = @max_steps - @current_step
            "[Step budget warning]: Used #{@current_step}/#{@max_steps} steps (#{remaining} remaining). " \
              "Conclude work or prepare progress summary for init-0 supervisor."
          end
        end

        # Normalize -> floor -> += -> re-arm, atomically. Returns the
        # [extra, total] pair Instance's note lambda needs. Terminal-state
        # refusal, the :running transition, the history note, and the condvar
        # broadcast stay on Instance — lifecycle facts, not budget facts.
        # Called with the Instance monitor held (lock order: instance -> budget).
        def grant!(steps)
          @monitor.synchronize do
            extra = (steps || DEFAULT_GRANT_STEPS).to_i
            extra = DEFAULT_GRANT_STEPS if extra <= 0
            @max_steps += extra
            @warned = false
            [extra, @max_steps]
          end
        end

        # One-lock snapshot: the two counters can never straddle a grant.
        def to_h
          @monitor.synchronize { { current_step: @current_step, max_steps: @max_steps } }
        end
      end
    end
  end
end
