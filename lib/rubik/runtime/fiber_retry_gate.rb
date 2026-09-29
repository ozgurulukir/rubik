# frozen_string_literal: true

# Failed-fiber retry gate (G4 extraction from Runtime::Manager; review
# 2026-09-17, Finding 3): a permanently-broken factory used to re-run on EVERY
# reconcile_all (each provide/register). Failures back off exponentially and
# stop after MAX_RETRIES attempts; a successful activation or a fresh
# register_fiber clears the bookkeeping.
#
# The backoff sleep must NOT run while holding the Manager Monitor: the sleep
# happens with the monitor fully released (depth 0) so it never serializes
# other threads; bookkeeping is committed atomically under it first, and the
# factory activation re-acquires the lock (depth 1) afterwards.
module Rubik
  module Runtime
    class FiberRetryGate
      MAX_RETRIES = 5
      BACKOFF_BASE_S = 0.05

      def initialize(monitor, context)
        @monitor = monitor
        @context = context
        @bookkeeping = {} # name -> { attempts:, last_attempt_at:, warned: }
      end

      # Explicit re-registration / unregistration resets the retry budget.
      def clear(name)
        @monitor.synchronize { @bookkeeping.delete(name) }
      end

      # No bookkeeping outlives the manager (fresh-eye R2).
      def clear_all
        @bookkeeping.clear
      end

      def attempt(fiber)
        delay = 0.0
        elapsed = 0.0
        @monitor.synchronize do
          book = @bookkeeping[fiber.name] ||= { attempts: 0, last_attempt_at: nil }
          if book[:attempts] >= MAX_RETRIES
            warn_budget_exhausted(fiber, book) # atomic, one-shot, stays under the lock
            return
          end

          prev_attempts = book[:attempts]
          ts_prev = book[:last_attempt_at]
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          delay = ts_prev ? BACKOFF_BASE_S * (2**prev_attempts) : 0.0
          elapsed = ts_prev ? (now - ts_prev) : Float::INFINITY
          book[:attempts] += 1
          book[:last_attempt_at] = now
        end

        # Sleep happens with the monitor FULLY released (depth 0) so it never
        # serializes other threads; bookkeeping is already committed above.
        sleep(delay - elapsed) if delay > elapsed

        # Re-acquire (depth 1) and run the factory: the failing fiber is not in
        # the manager's activation marker, so the reentrancy guard lets this
        # re-activate it. A successful activation clears its bookkeeping.
        @monitor.synchronize do
          yield fiber
          @bookkeeping.delete(fiber.name) if fiber.state == :active
        end
      end

      private

      # One-shot visibility when a fiber's retry budget is exhausted (fresh-eye
      # R3): the old always-retry behavior was noisy but visible; without this
      # warn a permanently-broken factory would sink silently into :failed.
      # Warns exactly once per budget cycle — re-registration resets the flag.
      def warn_budget_exhausted(fiber, book)
        return if book[:warned]

        book[:warned] = true
        last = fiber.last_error
        Rubik::Log.warn(:runtime, "fiber '#{fiber.name}' retry budget exhausted " \
                                  "(#{book[:attempts]} attempts, MAX_FIBER_RETRIES=#{MAX_RETRIES}) — " \
                                  "staying :failed; re-register to retry. Last error: #{last&.class}: #{last&.message}")
      end
    end
  end
end
