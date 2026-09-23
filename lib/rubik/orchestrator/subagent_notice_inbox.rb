# frozen_string_literal: true

module Rubik
  module Orchestrator
    # The Loop-side mailbox for subagent notices (fresh-scan card 4;
    # ContinuationManager mold: plain constructor, own state, eager init in
    # Loop#initialize plus a lazy reader for Loop.allocate test doubles).
    #
    # Boundary: QUEUE-ONLY. This class owns the thread-safe queue, the
    # notice-shape validation at entry, and the run/continuation lifecycle
    # of that queue. It deliberately does NOT render notices
    # (Subagent::Notices owns the vocabulary) and does NOT merge into
    # history (Loop owns @history): drain_all hands back validated notice
    # hashes and the caller renders.
    #
    # Threading contract (inherited verbatim from the pre-extraction Loop
    # code; see also repl/lifecycle.rb handle_subagent_event):
    # - enqueue runs on subagent worker threads (the bus emit is
    #   synchronous): validation plus a bare Queue#push, never a lock a
    #   REPL thread might hold while routing an event.
    # - drain_all / reset_for_new_run! run on the turn thread between
    #   steps and may race a concurrent enqueue safely: pop(true) raises
    #   ThreadError on empty, the race-safe terminator for the
    #   check-then-act window a conditional loop would miss.
    # - reset_for_new_run! REASSIGNS the queue (faithful to Loop's old
    #   `@subagent_notices = Queue.new`), it does not clear it. A notice
    #   pushed to the old Queue object in the microscopic window between
    #   the previous run's last drain and the reassign is stranded on the
    #   dead queue: accepted by design — the user channel already rendered
    #   its line at enqueue time, and manage_subagents wait remains the
    #   model's recovery path.
    class SubagentNoticeInbox
      def initialize
        @queue = Queue.new
      end

      # Entry point and the ONLY mutation path: validate, then push. The
      # REPL routing seam reaches this via Loop#enqueue_subagent_notice
      # with Notices.normalize output; this raise is the safety net against
      # the legacy string dialect. Message pinned verbatim by tests.
      def enqueue(notice)
        raise ArgumentError, "subagent notice must be a Hash with :kind, got #{notice.inspect}" unless notice.is_a?(Hash) && notice[:kind]

        @queue.push(notice)
      end

      # Pops everything pending (FIFO) and returns the notice hashes.
      # Empty-after-drain by construction; a second call returns [].
      def drain_all
        notices = []
        loop { notices << @queue.pop(true) }
      rescue ThreadError
        notices
      end

      # Per-run lifecycle (Loop#run, aligned with the @history reset):
      # stale notices from a previous run on a cached Loop instance must
      # never drain into the fresh history. Reassigns — see the class
      # comment for the stranding window this preserves on purpose.
      def reset_for_new_run!
        @queue = Queue.new
      end

      # Continuation lifecycle (Loop#continue_loop): an explicit,
      # contract-carrying no-op. Continuation resumes the same run, so
      # undelivered notices must survive into the next execute_steps pass.
      # Retention is the decision — encoding it as a named call at the
      # continuation seam keeps the run/continue asymmetry greppable in
      # code instead of living only in a comment inside #run.
      def keep_for_continuation; end
    end
  end
end
