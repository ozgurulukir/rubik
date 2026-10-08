# frozen_string_literal: true

module Rubik
  module Concurrency
    # Bounded thread-join mechanics (arch-deepening 2026-10-08 #12): the
    # monotonic-deadline polling join previously hand-mirrored in
    # mcp/manager.rb#join_boot_safely and repl/ast_warmup.rb#join_indexer_safely.
    # Mechanics only — the caller passes the thread handle and keeps its own
    # log channel and timeout-exhaustion policy; this module never logs and
    # never raises (a Thread#join failure is RETURNED, the error-as-data
    # precedent from ProcessWaiter).
    module Join
      # Poll cadence: short enough that teardown feels immediate, long
      # enough to never spin the GVL.
      POLL_INTERVAL = 0.05

      module_function

      # Joins +th+ and reports the outcome:
      #   :no_thread     nil handle (caller-level "nothing to join")
      #   :joined        thread finished inside the bound
      #   :timeout       Numeric timeout: deadline lapsed, thread still alive
      #   StandardError  Thread#join re-raised the thread's death —
      #                  returned, never raised (caller owns the log).
      # timeout: nil joins unboundedly, polling at POLL_INTERVAL. The handle
      # is captured ONCE at call time — callers that must not hold a lock
      # while joining read the handle under their lock first (G5) and pass
      # it in.
      def thread(handle, timeout: nil)
        return :no_thread unless handle

        if timeout
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          while handle.alive?
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if remaining <= 0

            handle.join([remaining, POLL_INTERVAL].min)
          end
          return handle.alive? ? :timeout : :joined
        end

        handle.join(POLL_INTERVAL) while handle.alive?
        :joined
      rescue StandardError => e
        e
      end
    end
  end
end
