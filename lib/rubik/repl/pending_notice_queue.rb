# frozen_string_literal: true

module Rubik
  module REPL
    # The idle-path wake queue (Plan 109 Faz B): a queue-only boundary in
    # the Orchestrator::SubagentNoticeInbox mold — validate at entry,
    # Queue-backed, FIFO drain with a ThreadError terminator. Deliberately
    # distinct from the orchestrator inbox: that one is the ACTIVE-turn
    # model-channel mailbox with run/continuation lifecycle; this one is
    # the IDLE-turn wake flag. Its contents are advisory payload only —
    # the authoritative copy of every notice rides @conversation_history
    # via the idle injection; the queue answers ONE question: does the
    # REPL owe agent-0 an autonomous notice turn?
    #
    # Threading contract: enqueue runs on the kworker thread (synchronous
    # EventBus dispatch) — validation plus a bare Queue#push, never a
    # lock a REPL thread might hold. any?/drain_all/clear! run on the
    # REPL thread between prompts. The check-then-act window between
    # any? and readline is benign by construction: the handler that
    # pushes also fires TerminalGuard#safe_wakeup!, whose ungetc wakes
    # the NEXT readline even if the current check already passed.
    class PendingNoticeQueue
      def initialize
        @queue = Queue.new
      end

      # Entry point and the ONLY mutation path: validate, then push.
      # Pinned message, mold style.
      def enqueue(notice)
        raise ArgumentError, "pending wake notice must be a Hash with :kind, got #{notice.inspect}" unless notice.is_a?(Hash) && notice[:kind]

        @queue.push(notice)
      end

      def any?
        !empty?
      end

      def empty?
        @queue.empty?
      end

      # Pops everything pending (FIFO); a second call returns [].
      def drain_all
        notices = []
        loop { notices << @queue.pop(true) }
      rescue ThreadError
        notices
      end

      # Staleness rule (Plan 109): any user-driven dispatch supersedes a
      # pending wake — the notices already ride the conversation history
      # into whatever turn runs next.
      def clear!
        drain_all
        nil
      end
    end
  end
end
