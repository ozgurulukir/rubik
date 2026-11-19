# frozen_string_literal: true

require_relative "../../errors"

module Rubik
  module Orchestrator
    module Subagent
      # The Instance lifecycle vocabulary (Plan 95 extraction): TRANSITIONS
      # is the single home of the state machine, transition! its only
      # mutation path, these predicates the only control-flow surface.
      # Instance::TRANSITIONS / Instance::StateError stay the public
      # constants — adding a state means editing THIS file (plus the kernel
      # STATE_MAP, held by contract test).
      module Lifecycle
        class StateError < Rubik::StateError; end

        # Every legal from->to edge. A transition not listed here is a bug
        # — fail loud with both endpoints in the message. :disposed is
        # absorbing (reaper/evict own the shell). completed/failed ->
        # running is the redeploy window (redeploy_for! only resets;
        # start_async performs the flip). canceling -> completed/failed is
        # the kill race: kill announces under the monitor but Thread#kill
        # lands after, so the worker may still record its outcome;
        # completed -> failed is the total-catch rescue firing after a
        # post-outcome raise (transcript save, sync). Same-state writes are
        # idempotent no-ops — the waker flips before the parked thread
        # re-flips.
        TRANSITIONS = {
          pending: [:running, :canceling, :disposed],
          running: [:waiting_input, :waiting_budget, :paused_error, :completed, :failed, :canceling, :disposed],
          waiting_input: [:running, :canceling, :disposed],
          waiting_budget: [:budget_exhausted, :running, :failed, :canceling, :disposed],
          budget_exhausted: [:running, :failed, :canceling, :disposed],
          paused_error: [:running, :failed, :canceling, :disposed],
          canceling: [:completed, :failed, :disposed],
          completed: [:running, :failed, :canceling, :disposed],
          failed: [:running, :canceling, :disposed],
          disposed: []
        }.transform_values(&:freeze).freeze

        # Attention vocabulary (the tool plane's "needs attention" set,
        # derived here so a rename can never silently desync it).
        # PARKED_STATES is the condvar-parked set; ATTENTION_STATES rides
        # :waiting_input on top. Owned constants — no clean derivation
        # from the TRANSITIONS edges exists.
        PARKED_STATES = [:paused_error, :waiting_budget, :budget_exhausted].freeze
        ATTENTION_STATES = (PARKED_STATES + [:waiting_input]).freeze

        # --- Predicates: control-flow questions answer here. All take the
        # re-entrant monitor (re-entrant: composition under a held lock
        # pays nothing extra; readers see consistent snapshots).

        # Worker thread mid-flight (possibly parked on a wait).
        def running?
          @monitor.synchronize { @state == :running || @state == :waiting_input || @state == :waiting_budget || @state == :paused_error }
        end

        # Occupies a concurrency slot / tracked in Supervisor#instances:
        # everything live except :budget_exhausted (deliberately excluded,
        # pinned by test_pause_and_await_budget_expansion_timeout;
        # supervisor's send_message compensates via deliverable?).
        def active?
          @monitor.synchronize { pending? || running? || canceling? }
        end

        # Issue #594, dispatched-work view: active? PLUS :budget_exhausted —
        # a parked unit holds no slot (see active?) but its work is unfinished.
        def in_flight?
          @monitor.synchronize { pending? || running? || canceling? || @state == :budget_exhausted }
        end

        def pending? = @monitor.synchronize { @state == :pending }
        def executing? = @monitor.synchronize { @state == :running }
        def awaiting_human? = @monitor.synchronize { @state == :waiting_input }
        def error_paused? = @monitor.synchronize { @state == :paused_error }
        def canceling? = @monitor.synchronize { @state == :canceling }
        def completed? = @monitor.synchronize { @state == :completed }
        def failed? = @monitor.synchronize { @state == :failed }
        def disposed? = @monitor.synchronize { @state == :disposed }

        # A budget grant is the only wake-up from either of these.
        def awaiting_budget?
          @monitor.synchronize { @state == :waiting_budget || @state == :budget_exhausted }
        end

        # Condvar-parked, reap-immune; the resume_all targets.
        def parked?
          @monitor.synchronize { PARKED_STATES.include?(@state) }
        end

        # The no-resurrection set (kill's race window included).
        def terminal?
          @monitor.synchronize { settled? || disposed? || canceling? }
        end

        # Final outcome recorded; the thread may still be in its ensure
        # block — terminal_and_settled? (Redeploy) is the strict form.
        def settled?
          @monitor.synchronize { @state == :completed || @state == :failed }
        end

        # Inbox accepts a message; exactly active? plus :budget_exhausted.
        # :canceling stays deliverable (a message to a dying instance is
        # harmless but pointless) — preserved behavior, revisitable.
        def deliverable?
          @monitor.synchronize { !settled? && !disposed? }
        end

        # Guarded low-level seam (mirrors Unit#transition_to!): business
        # callers use the named drivers (resume!, grant_budget!, kill...);
        # tests use this for legal-but-rare windows (e.g. the :canceling
        # kill race, which is not externally holdable). Idempotent on same
        # state; raises StateError on an undeclared edge. Does NOT sync the
        # unit or emit — call sites own that timing (the kernel reconciles
        # lazily through its own sync_state! polls).
        def transition!(to)
          @monitor.synchronize do
            target = to.to_sym
            return @state if @state == target

            raise StateError, "illegal subagent transition #{@id}: #{@state} -> #{target}" unless TRANSITIONS.fetch(@state, []).include?(target)

            @state = target
          end
        end
      end
    end
  end
end
