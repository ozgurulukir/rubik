# frozen_string_literal: true

require_relative "log"
require_relative "concurrency/errors"
require_relative "concurrency/event_loop"
require_relative "concurrency/scheduler"
require_relative "concurrency/boundary"

module Rubik
  # Silent concurrency over Ruby's Fiber Scheduler: plain blocking I/O —
  # Net::HTTP, sleep backoffs, Open3 pipe reads, Mutex/ConditionVariable
  # waits, Thread#join — interleaves cooperatively on a background event
  # loop while a boundary is open, with ZERO changes at the I/O call sites.
  # "Silently" = no async/await-style syntax noise ever reaches callers.
  #
  # Envelope (documented limits, plan §9): this is I/O concurrency, not CPU
  # parallelism (the GVL still serializes computation); regular-file reads
  # never park (read_nonblock on files returns immediately — they simply run
  # serially, which is harmless); Timeout.timeout-backed code paths are not
  # adopted inside boundaries in v1 (Thread.raise cannot be aimed at a
  # specific fiber). Escape hatch: RUBIK_FIBER_SCHEDULER=off degrades every
  # boundary to plain sequential execution.
  module Concurrency
    module_function

    # Runs the block on the current OS thread with a fiber scheduler
    # installed. Fibers spawned inside (via .map or Fiber.schedule) drain
    # before the block returns. Returns the block's value; errors surface
    # per Boundary.open's drain-then-raise policy. Nested calls reuse the
    # outer boundary. The scheduler is always uninstalled on exit.
    def silently(&block)
      disabled? ? block.call : Boundary.open(&block)
    end

    # Ordered fan-out: runs the block for every item concurrently and
    # returns results in INPUT order. concurrency: bounds simultaneously
    # live fibers (fiber stacks cost real memory — pass a bound for very
    # large enumerables). Drain-then-raise: after every item completes, the
    # lowest-INPUT-index error is raised and its siblings are logged.
    def map(enum, concurrency: nil, &block)
      return enum.map(&block) if disabled?

      items = enum.to_a
      return [] if items.empty?

      limit = concurrency&.positive? ? concurrency.to_i : nil
      slots = Boundary.open do
        loop = ::Thread.current.thread_variable_get(Boundary::ACTIVE_KEY).loop
        results = ::Array.new(items.size)
        latch = ::Object.new
        waiter = ::Fiber.current
        remaining = items.size
        slot_lock = ::Mutex.new
        slot_free = ::ConditionVariable.new
        used = 0

        items.each_with_index do |item, index|
          ::Fiber.schedule do
            acquired = false
            begin
              slot_lock.synchronize do
                slot_free.wait(slot_lock) while limit && used >= limit
                used += 1
              end
              acquired = true
              results[index] = { ok: true, value: block.call(item) }
            rescue StandardError => e
              results[index] = { ok: false, error: e }
            ensure
              # The ensure spans the ACQUISITION too: an Exception-level
              # death while parked on the semaphore (interrupt delivery)
              # must still count this item down or the latch never fires and
              # the boundary hangs. Mutex#synchronize releases on raise, so
              # re-locking here is safe.
              if acquired
                slot_lock.synchronize do
                  used -= 1
                  slot_free.signal
                end
              end
              remaining -= 1 # fibers serialize on the loop thread — no race
              loop.unpark(latch, waiter) if remaining.zero?
            end
          end
        end
        loop.park(latch)
        results
      end

      failures = slots.filter_map.with_index { |slot, i| [i, slot[:error]] if slot && !slot[:ok] }
      failures.each do |(index, error)|
        Rubik::Log.warn(:concurrency, "fan-out item #{index} failed: #{error.class}: #{error.message}")
      end
      raise failures.first[1] if failures.any?

      slots.map { |slot| slot[:value] }
    end

    # True while a boundary is installed on the current OS thread.
    def active?
      !::Thread.current.thread_variable_get(Boundary::ACTIVE_KEY).nil?
    end

    # RUBIK_FIBER_SCHEDULER=off degrades boundaries to sequential execution
    # (memoized at first use — the process-wide kill switch, plan K14).
    def disabled?
      return @disabled unless @disabled.nil?

      @disabled = ::ENV["RUBIK_FIBER_SCHEDULER"].to_s.casecmp("off").zero?
    end

    class << self
      # Test seam: reset the memoized kill-switch state after stubbing ENV.
      def reset_disabled_cache!
        @disabled = nil
        nil
      end
    end
  end
end

# Ruby prints "IO::Buffer is experimental" on the first buffer use; our
# io_read/io_write hooks exercise it on every boundary. Pay that one-shot
# warning now, silently, so it never surfaces mid-session.
original_verbose = $VERBOSE
begin
  $VERBOSE = nil
  IO::Buffer.new(1)
ensure
  $VERBOSE = original_verbose
end
