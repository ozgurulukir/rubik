# frozen_string_literal: true

require_relative "join"

module Rubik
  module Concurrency
    # Single home of the bounded-queue worker skeleton shared by the pruner
    # and vakanuvis harnesses: one worker thread drains a bounded FIFO until
    # a STOP marker, with atomic admission (stopped-check + push share one
    # monitor critical section), idempotent shutdown, busy accounting and a
    # last-ditch dispatch net. Mechanics only, per the join.rb contract: the
    # host keeps its own monitor and log channel — the skeleton never
    # allocates a lock and never logs directly.
    #
    # Host contract — state (host-initialized, skeleton-operated):
    #   @monitor / @queue / @worker — host-owned; domain state shares the monitor
    #   @stopped / @busy            — skeleton-owned flags under @monitor
    #   plus private hooks: worker_max_queue (FIFO bound), worker_warn (log
    #   sink), worker_drop_accounted (overflow reconciliation),
    #   worker_dispatch_failed (net: receives kind, payload, error so the
    #   host reconciles its accounting), worker_before_join
    #   (pre-join teardown, default none) and handle_event (dispatch hook).
    module Worker
      # Queue terminator; drop-oldest must never swallow it (the worker would drain forever).
      STOP = :__worker_stop__

      # Shutdown grants the worker JOIN_TIMEOUT seconds to drain; the idle
      # probe polls at a cadence that keeps teardown feeling immediate.
      JOIN_TIMEOUT = 2
      IDLE_POLL = 0.01

      def stopped? = @monitor.synchronize { @stopped }

      # Queue + in-flight count: incremented at admission, decremented when
      # consumed or dropped — closes the accounting window pop would open.
      def busy? = @monitor.synchronize { @busy.positive? }

      def queue_size = @queue.size

      # Idle probe: Join's mechanics are handle-shaped (join a thread), this
      # is predicate-shaped (poll busy?) — same deadline discipline, own loop.
      def wait_idle(timeout: 2.0)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        sleep IDLE_POLL while busy? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        !busy?
      end

      def shutdown
        @monitor.synchronize do
          return if @stopped

          @stopped = true
          @busy += 1 # the STOP marker counts as consumed work
          @queue.push(STOP)
        end
        worker_before_join
        outcome = Join.thread(@worker, timeout: JOIN_TIMEOUT)
        if outcome == :timeout
          # Thread#kill waits out the dying thread's unwind, so the in-flight
          # ensure decrement runs before we return; busy then equals the
          # unconsumed queue — lost work stays honestly counted (-1: the
          # STOP marker itself is still queued).
          worker_warn("worker did not stop in #{JOIN_TIMEOUT}s — killing with #{queue_size - 1} event(s) unprocessed")
          @worker.kill
        elsif outcome.is_a?(StandardError)
          # Error-as-data: Join returns a dead-with-exception thread's error
          # — teardown completes, the death is reported, never swallowed.
          worker_warn("worker thread died: #{outcome.class}: #{outcome.message}")
        end
        @worker = nil
      end

      # Atomic admission: the stopped-check and the push share one critical
      # section — an event racing shutdown either lands before STOP (and is
      # consumed) or is refused; it can never straddle the marker and leak a
      # busy increment behind an unconsumable item. The overflow hook fires
      # OUTSIDE the monitor: a slow host reconcile (gate locks, log I/O) must
      # never stall admission, shutdown or wait_idle.
      def enqueue_event(kind, payload)
        dropped = nil
        @monitor.synchronize do
          return false if @stopped

          if @queue.size >= worker_max_queue
            dropped = drop_oldest!
            return false if dropped == STOP
          end
          @busy += 1
          @queue.push([kind, payload])
        end
        worker_drop_accounted(dropped) if dropped
        true
      end

      private

      def worker_before_join; end

      def run_worker
        loop do
          kind, payload = @queue.pop
          break if kind == STOP

          handle_event(kind, payload)
        rescue StandardError => e
          # A raise escaping handle_event's own rescue would kill the worker
          # with queued events unconsumed; hand the item to the hook (the
          # host reconciles its accounting) and keep draining. The net is
          # itself guarded: when it runs, log/reconcile infrastructure is
          # already failing and a second raise must not kill the worker.
          begin
            worker_dispatch_failed(kind, payload, e)
          rescue StandardError
            nil
          end
        ensure
          @monitor.synchronize { @busy -= 1 }
        end
      end

      # Make room for one admission (assumes @monitor held): pops the oldest
      # item, decrements its busy increment, and returns it for the caller to
      # hand to worker_drop_accounted outside the monitor. Returns STOP
      # (marker re-pushed; the caller refuses rather than strand an event
      # behind the terminator) or nil when the worker drained the queue
      # between the size check and this pop (nothing dropped, unaccounted).
      def drop_oldest!
        item = @queue.pop(true)
        if item == STOP
          @queue.push(STOP)
          return STOP
        end

        @busy -= 1
        item
      rescue ThreadError
        # Worker drained between the size check and pop(true): no-op race
        # loss — nothing was dropped, nothing to account.
        nil
      end
    end
  end
end
