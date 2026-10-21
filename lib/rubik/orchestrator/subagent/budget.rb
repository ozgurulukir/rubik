# frozen_string_literal: true

require "monitor"

module Rubik
  module Orchestrator
    module Subagent
      # Step-budget state machine for a subagent Instance (architecture-review
      # Candidate 04): owns max_steps/current_step and their entire invariant
      # set — initial normalization, consumption, exhaustion, the per-step
      # visibility marker, and grant (normalize -> floor -> +=).
      #
      # Kinship: the main loop's Orchestrator::BudgetManager implements the
      # 75% warning arithmetic as a STATELESS collaborator over Loop-held
      # state, emitting XML into the main history. This class is the OWNING
      # variant for the subagent path (different owner, different channel:
      # a subagent-local user message). The two stay separate by the
      # stateless-over-owner doctrine; do not merge them. Plan 109 removed
      # the subagent-side 75% latch: transparency ([Step X/Y] every step)
      # replaced it — the subagent paces itself, agent-0 steers.
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
        DEFAULT_MAX_TOTAL_STEPS = 256

        def initialize(max_steps: nil, max_total_steps: DEFAULT_MAX_TOTAL_STEPS)
          @max_total_steps = [(max_total_steps || DEFAULT_MAX_TOTAL_STEPS).to_i, 1].max
          @max_steps = [(max_steps || DEFAULT_MAX_STEPS).to_i, @max_total_steps].min
          @current_step = 0
          @monitor = Monitor.new
        end

        def max_steps
          @monitor.synchronize { @max_steps }
        end

        def max_total_steps
          @monitor.synchronize { @max_total_steps }
        end

        def current_step
          @monitor.synchronize { @current_step }
        end

        def exhausted?
          @monitor.synchronize { @current_step >= @max_steps }
        end

        # Enter the next step; returns the new current_step.
        def consume
          @monitor.synchronize { @current_step += 1 }
        end

        # Per-step visibility marker (Plan 109 Faz A, replacing the 75%
        # latch): computed under the Monitor so X/Y can never straddle a
        # concurrent grant — grant! raises Y and the next marker shows the
        # new total automatically. Stateless by design: only the newest
        # marker carries information, so emergency compaction may
        # summarize older markers away freely.
        def step_marker
          @monitor.synchronize { "[Step #{@current_step}/#{@max_steps}]" }
        end

        # Normalize -> floor -> cap, atomically. Returns the [extra, total]
        # pair Instance's note lambda needs. Repeated grants can never push a
        # run past its configured lifetime ceiling. Terminal-state
        # refusal, the :running transition, the history note, and the condvar
        # broadcast stay on Instance — lifecycle facts, not budget facts.
        # Called with the Instance monitor held (lock order: instance -> budget).
        def grant!(steps)
          @monitor.synchronize do
            extra = [Budget.normalize_grant(steps), @max_total_steps - @max_steps].min
            @max_steps += extra
            [extra, @max_steps]
          end
        end

        # One-lock snapshot: the two counters can never straddle a grant.
        def to_h
          @monitor.synchronize { { current_step: @current_step, max_steps: @max_steps } }
        end

        # Pure normalization half shared by grant! and the reporting edges
        # (manage_subagents steps arg, REPL !subagents extend arg). A grant
        # may be smaller than this normalized request when the lifetime
        # ceiling has less room remaining. Idempotent.
        def self.normalize_grant(steps)
          extra = (steps || DEFAULT_GRANT_STEPS).to_i
          extra = DEFAULT_GRANT_STEPS if extra <= 0
          extra
        end

        # Grant history notes (same audience as the step marker above: the
        # subagent's own loop, not the main agent — that is why they live
        # here rather than in Notices). Rendered by Instance's grant_budget!
        # note lambdas.
        def self.grant_note(extra, total)
          "[Supervisor maestro]: Granted #{extra} additional step(s). Total budget: #{total}. Continue execution."
        end

        def self.message_grant_note(extra, total)
          "[Supervisor maestro]: Granted #{extra} additional step(s) with message. Total budget: #{total}. Continue execution."
        end
      end
    end
  end
end
