# frozen_string_literal: true

require_relative "errors"
require_relative "timers"
require_relative "dns_pool"

module Rubik
  module Concurrency
    # The reactor backing a Scheduler: one OS thread, N non-blocking fibers.
    #
    # Thread discipline (load-bearing — verified against Ruby 4.0.6 probes,
    # see _plan/fiber-scheduler-silent-concurrency-2026-10-05.md):
    #   * VM hooks (io_wait, kernel_sleep, block, fiber creation) always run
    #     on the loop thread, inside a resume. Timers, the io-interest
    #     registry, park generations and spawn bookkeeping are therefore
    #     touched only by the loop thread — no locks.
    #   * Foreign threads (dying join targets, process waiters, DNS workers)
    #     wake fibers through #push / #unpark, which guard @runnable/@parked
    #     with @mutex and write a self-pipe byte so a blocked IO.select on
    #     the loop thread wakes immediately.
    #   * Wake staleness is handled by park generations: every registration
    #     stamps @gen[fiber]; timer fires and io dispatch only push when the
    #     generation still matches, so a fiber that timed out and re-parked
    #     elsewhere can never be resumed by a stale source.
    #
    # Drain model (waiters, not liveness — Fiber#alive? does not exist on
    # Ruby 4.0): the loop runs while anything is runnable, parked (Mutex/CV/
    # Thread#join/block), io-waiting, or timer-pending. Finished fibers leave
    # no registration, so "is anything waiting?" answers "are we done?".
    class EventLoop
      # The VM's io_wait hook passes and expects the scheduler-protocol wait
      # mask — the same domain as ::IO::READABLE / ::IO::WRITABLE (1 and 4;
      # 2 is IO::PRIORITY). A local 1/2 pair silently drops WRITABLE
      # interests (5.anybits?(2) is false): connects park forever until a
      # deadline fires — the mis-aimed-watchdog crash of #102 never even
      # needed the watchdog. Aliased to the real constants so a protocol
      # drift surfaces as a NameError, not a hang.
      READABLE = ::IO::READABLE
      WRITABLE = ::IO::WRITABLE

      # Timer generation slot for deadline registrations that must survive
      # re-parks (Timeout.timeout spans many io waits within ONE timed
      # operation). Sticky entries never go stale — they are cancelled
      # explicitly by the owning fiber's ensure.
      STICKY = :sticky

      attr_reader :spawn_errors

      def initialize
        @mutex = ::Mutex.new
        @runnable = []       # [[fiber, resume_value]] — guarded by @mutex
        @parked = {}         # fiber => true (block-hook parks) — guarded
        @waiter_threads = [] # process-wait threads — guarded
        # Stale timers (fiber re-parked or resumed since registration) must
        # not gate draining — @gen is bumped on every resume, so any of this
        # fiber's outstanding registrations becomes inert at that moment.
        @timers = Timers.new do |fiber, gen|
          next false if gen == STICKY

          @gen[fiber] != gen
        end
        @io_waiters = {}     # io => { read: {fiber=>gen}, write: {fiber=>gen} }
        @gen = ::Hash.new(0) # fiber => park generation (loop thread only)
        @live = {}           # fiber => true while a spawned fiber runs
        @next_ordinal = 0
        @spawn_errors = []   # [[ordinal, exception]] — body/spawn lifecycle
        @loop_thread = nil
        @closed = false
        @wake_read, @wake_write = ::IO.pipe
      end

      def closed?
        @closed
      end

      # ---- Any-thread API ---------------------------------------------------

      # Queues a fiber to be resumed with value. Safe from foreign threads:
      # pushes write a self-pipe byte so the loop's IO.select wakes at once.
      def push(fiber, value: true)
        @mutex.synchronize do
          return if @closed

          @runnable << [fiber, value]
        end
        kick unless ::Thread.current.equal?(@loop_thread)
      end

      # unblock-hook counterpart for programmatically parked fibers (DNS
      # jobs, fan-out latches): removes the park and delivers value. Park
      # removal and resume append happen under ONE lock section — a split
      # update could let the drain's idle? check observe both sets empty in
      # the gap and exit, stranding the resume (and the fiber's ensures).
      def unpark(_blocker, fiber, value: true)
        @mutex.synchronize do
          return if @closed

          @parked.delete(fiber)
          @runnable << [fiber, value]
        end
        kick unless ::Thread.current.equal?(@loop_thread)
      end

      def interrupt(fiber, exception = Interrupted)
        exc =
          if exception.is_a?(::Exception)
            exception
          elsif exception.is_a?(::Class)
            exception.new("fiber interrupted")
          else
            Interrupted.new("fiber interrupted")
          end
        push(fiber, value: exc)
      end

      def track_waiter(thread)
        @mutex.synchronize { @waiter_threads << thread unless @closed }
      end

      # ---- Loop-thread API (VM hooks & body) ---------------------------------

      # Scheduler.fiber hook (Ruby 4.0): we create the fiber. Errors from the
      # block never escape into the reactor — they are captured per spawn
      # ordinal and raised by the boundary after the drain (K7), including
      # Interrupt-level deaths so teardown can finish cleanly first.
      def spawn_fiber(&block)
        @next_ordinal += 1
        ordinal = @next_ordinal
        fiber = nil
        fiber = ::Fiber.new(blocking: false) do
          block.call
        rescue ::Exception => e # rubocop:disable Lint/RescueException -- boundary re-raises after drain
          @spawn_errors << [ordinal, e]
        ensure
          @live.delete(fiber)
        end
        @live[fiber] = true
        push(fiber, value: nil)
        fiber
      end

      def nap(duration)
        park_fiber { |fiber, gen| @timers.add(monotonic + duration, fiber, true, gen) }
        true
      end

      # block-hook: park the current fiber on a blocker (Mutex, CV, Thread).
      # Returns truthy when unparked, false when the timeout elapsed. A
      # timeout of 0 still registers a timer (fires immediately) — truthiness
      # guards would park join(0)/wait(0) polls forever.
      def park(_blocker, timeout = nil)
        @mutex.synchronize { @parked[::Fiber.current] = true }
        value = park_fiber do |fiber, gen|
          @timers.add(monotonic + timeout, fiber, :timeout, gen) unless timeout.nil?
        end
        value == :timeout ? false : value
      end

      # io_wait hook: interests is a READABLE/WRITABLE mask. The resume value
      # is the ready-event mask (0 when the timeout elapsed — falsy, which is
      # what IO#wait_readable reports to callers like Net::HTTP).
      def wait_io(io, interests, timeout)
        fiber = ::Fiber.current
        gen = (@gen[fiber] += 1)
        slot = (@io_waiters[io] ||= { read: {}, write: {} })
        slot[:read][fiber] = gen if interests.anybits?(READABLE)
        slot[:write][fiber] = gen if interests.anybits?(WRITABLE)
        @timers.add(monotonic + timeout, fiber, 0, gen) unless timeout.nil?
        value = ::Fiber.yield
        raise value if value.is_a?(::Exception)

        value
      end

      # A zero minimum means one nonblocking attempt: return -errno to
      # the VM instead of parking here, so read_nonblock preserves the
      # caller's subsequent IO#wait_readable deadline (e.g. Net::HTTP).
      # Fiber.blocking prevents the primitive from re-entering this hook.
      def read_io(io, buffer, minimum = 0, offset = 0)
        transferred = 0
        capacity = buffer.size - offset
        return 0 if capacity.zero?

        loop do
          chunk = ::Fiber.blocking { io.read_nonblock(capacity - transferred, exception: false) }
          case chunk
          when :wait_readable, :wait_writable
            return transferred.positive? ? transferred : -Errno::EAGAIN::Errno if transferred >= minimum

            wait_io(io, chunk == :wait_readable ? READABLE : WRITABLE, nil)
          when nil then return transferred
          else
            buffer.set_string(chunk, offset + transferred)
            transferred += chunk.bytesize
            return transferred if transferred >= minimum || transferred == capacity
          end
        end
      rescue SystemCallError => e
        -e.errno
      end

      def write_io(io, buffer, minimum = 0, offset = 0)
        transferred = 0
        capacity = buffer.size - offset
        return 0 if capacity.zero?

        loop do
          data = buffer.get_string(offset + transferred, capacity - transferred)
          written = ::Fiber.blocking { io.write_nonblock(data, exception: false) }
          if written.is_a?(::Integer)
            transferred += written
            return transferred if transferred >= minimum || transferred == capacity
          else
            return transferred.positive? ? transferred : -Errno::EAGAIN::Errno if transferred >= minimum

            wait_io(io, written == :wait_readable ? READABLE : WRITABLE, nil)
          end
        end
      rescue SystemCallError => e
        -e.errno
      end

      # DNS resolution parks the fiber; the DnsPool worker delivers the list
      # of IP strings (or an exception instance to raise) via unpark.
      def resolve_address(hostname)
        pool = (@dns_pool ||= DnsPool.new(self))
        pool.resolve(hostname)
      rescue StandardError => e
        # Pool unusable (thread creation blocked, shutdown racing): resolve
        # inline — correct, just not interleaved.
        Rubik::Log.warn(:concurrency, "dns pool unavailable, resolving inline: #{e.class}: #{e.message}")
        ::Addrinfo.getaddrinfo(hostname, nil).map(&:ip_address).uniq
      end

      # True while this thread is inside run/run_until_drained (a boundary
      # is draining). Timeout deadlines are fiber-native only in this
      # window — outside it no loop consumes the timers, so the patch falls
      # back to the stock Timeout watchdog.
      def draining?
        !@closed && !@loop_thread.nil?
      end

      # Fiber-native Timeout.timeout body (see concurrency/fiber_timeout.rb):
      # runs the block inline and delivers the deadline exception through
      # the interrupt path at the fiber's current park. The :sticky
      # generation means re-parks during the timed operation never stale
      # the deadline (a Net open spans many io waits); the ensure cancels
      # the timer and retracts an already-fired, still-queued delivery, so
      # a deadline that loses the race against block completion can never
      # leak into a later operation.
      def fiber_timeout(sec, exception_class, message)
        fiber = ::Fiber.current
        error = (exception_class || ::Timeout::Error).new(message || "execution expired")
        timer = @timers.add(monotonic + sec, fiber, error, STICKY)
        begin
          yield
        ensure
          @timers.cancel(timer)
          discard_queued(fiber, error)
        end
      end

      # ---- Reactor -------------------------------------------------------------

      # Runs the boundary body as a fiber and drains everything it spawned.
      # Returns [body_result, body_error]; spawned-fiber errors live in
      # #spawn_errors for the boundary to raise after the fact.
      def run(&body)
        @loop_thread = ::Thread.current
        result = nil
        body_error = nil
        runner = nil
        runner = ::Fiber.new(blocking: false) do
          result = body.call
        rescue ::Exception => e # rubocop:disable Lint/RescueException -- re-raised by Boundary after drain
          body_error = e
        end
        @live[runner] = true
        push(runner, value: nil)
        run_until_drained
        [result, body_error]
      ensure
        @live.delete(runner) if runner
      end

      def run_until_drained
        @loop_thread = ::Thread.current
        until idle?
          run_batch
          break if idle?

          select_or_wait
        end
      end

      def idle?
        @mutex.synchronize { @runnable.empty? && @parked.empty? } &&
          @timers.empty? && @io_waiters.empty?
      end

      # Idempotent teardown. Never raises (mirrors Platform::IoDrain):
      # stops the DNS pool, joins process-wait threads with a bounded
      # timeout, kills stragglers, closes the self-pipe, and reports any
      # pending work left behind by an abandoned drain instead of hiding it.
      def shutdown
        waiters = nil
        @mutex.synchronize do
          return if @closed

          @closed = true
          waiters = @waiter_threads.dup
          @waiter_threads.clear
        end
        @dns_pool&.shutdown
        waiters.each do |thread|
          thread.join(0.1)
          thread.kill if thread.alive?
        rescue StandardError
          nil
        end
        leak = nil
        @mutex.synchronize do
          leak = { runnable: @runnable.size, parked: @parked.size, timers: @timers.size,
                   io_waiters: @io_waiters.size, live: @live.size }
        end
        Rubik::Log.warn(:concurrency, "event loop closed with pending work: #{leak.inspect}") if leak.values.sum.positive?
        [@wake_read, @wake_write].each do |io|
          io.close unless io.closed?
        rescue StandardError
          nil
        end
      end

      private

      # Shared park sequence: bump the generation (invalidating older stale
      # wakeups), register the caller's timers, yield, and either re-raise a
      # delivered exception or return the resume value.
      def park_fiber
        fiber = ::Fiber.current
        gen = (@gen[fiber] += 1)
        yield fiber, gen
        value = ::Fiber.yield
        raise value if value.is_a?(::Exception)

        value
      end

      def run_batch
        while (item = @mutex.synchronize { @runnable.shift })
          fiber, value = item
          # A resumed fiber is definitionally no longer parked; dropping the
          # registration here keeps interrupt-style wakes from leaking parks.
          # Bumping the park generation invalidates every OTHER outstanding
          # registration the fiber still holds (io_wait timeout timer, io
          # interests) so dead entries cannot gate draining.
          @mutex.synchronize { @parked.delete(fiber) }
          @gen[fiber] += 1
          drop_io_interest(fiber)
          begin
            fiber.resume(value)
          rescue ::FiberError
            nil # stale wakeup for a finished fiber
          rescue StandardError => e
            # A failure of the resume machinery itself (not the fiber's block
            # — those are captured in spawn_fiber): record it so the
            # boundary's raise policy surfaces it instead of only a log line.
            Rubik::Log.warn(:concurrency, "fiber resume failed: #{e.class}: #{e.message} @ #{(e.backtrace || []).first}")
            @spawn_errors << [@next_ordinal += 1, e]
          end
        end
      end

      def select_or_wait
        read_set = @io_waiters.keys
        write_set = @io_waiters.each_with_object([]) do |(io, slot), acc|
          acc << io unless slot[:write].empty?
        end
        read_set << @wake_read
        timeout = @timers.next_gap(monotonic)

        ready = safe_select(read_set, write_set, timeout)
        return if ready == :retry

        drain_wake_pipe
        if ready
          ready_read, ready_write = ready
          dispatch_ready(ready_read, ready_write)
        end
        fire_due_timers
      end

      # A closed io among the watched sets makes IO.select raise; prune the
      # offender and let the caller loop again (sentinel :retry). When
      # nothing is prunable the loop would spin hot forever — fail loud and
      # let the boundary's raise policy surface it instead.
      def safe_select(read_set, write_set, timeout)
        ::IO.select(read_set, write_set, nil, timeout)
      rescue IOError, Errno::EBADF, Errno::EINVAL => e
        pruned = prune_closed_ios((read_set + write_set).uniq)
        return :retry if pruned.positive?

        Rubik::Log.warn(:concurrency, "io_select failed with nothing prunable (#{e.class}: #{e.message}; " \
                                      "watching #{read_set.size + write_set.size} ios)")
        raise Error, "event loop io_select failed: #{e.class}: #{e.message}"
      end

      def fire_due_timers
        @timers.fire_due!(monotonic) do |fiber, value, gen|
          next if gen != STICKY && @gen[fiber] != gen # stale: fiber moved on after registering

          drop_io_interest(fiber)
          push(fiber, value: value)
        end
      end

      def dispatch_ready(ready_read, ready_write)
        ready_read.each { |io| wake_io(io, READABLE) }
        ready_write.each { |io| wake_io(io, WRITABLE) }
      end

      def wake_io(io, events)
        slot = @io_waiters[io]
        return unless slot

        waiters = {}
        waiters.merge!(slot[:read]) if events.anybits?(READABLE)
        waiters.merge!(slot[:write]) if events.anybits?(WRITABLE)
        waiters.each do |fiber, gen|
          if @gen[fiber] != gen
            # Stale interest (the fiber timed out or moved on): remove it so
            # a never-ready io cannot keep the loop from draining.
            slot[:read].delete(fiber)
            slot[:write].delete(fiber)
            next
          end

          # Drop both interest directions for this fiber; if it waits again
          # it re-registers with a fresh generation.
          slot[:read].delete(fiber)
          slot[:write].delete(fiber)
          push(fiber, value: events)
        end
        @io_waiters.delete(io) if slot[:read].empty? && slot[:write].empty?
      end

      def drop_io_interest(fiber)
        @io_waiters.each do |io, slot|
          next unless slot[:read].key?(fiber) || slot[:write].key?(fiber)

          slot[:read].delete(fiber)
          slot[:write].delete(fiber)
          @io_waiters.delete(io) if slot[:read].empty? && slot[:write].empty?
        end
      end

      # Removes closed ios from the interest registry, waking their waiting
      # fibers with a 0 mask (their next nonblocking attempt sees the truth).
      # Returns the number of ios pruned.
      def prune_closed_ios(ios)
        pruned = 0
        ios.each do |io|
          next unless io.closed?

          slot = @io_waiters.delete(io)
          next unless slot

          (slot[:read].keys + slot[:write].keys).each { |fiber| push(fiber, value: 0) }
          pruned += 1
        end
        pruned
      end

      def drain_wake_pipe
        nil while @wake_read.read_nonblock(4096, exception: false).is_a?(String)
      rescue IOError, Errno::EBADF
        nil
      end

      # Retract a queued resume: a deadline that fired while its fiber was
      # running (mid-operation) sits in @runnable until the next pop —
      # without retraction, the block's completion would leave the
      # exception aimed at the fiber's NEXT park (the watchdog-leak shape,
      # in miniature). Same-thread ordering makes this airtight: the entry
      # can only be consumed by a resume that delivers it into the timed
      # block, and then the ensure's cancel finds nothing to retract.
      def discard_queued(fiber, value)
        @mutex.synchronize do
          @runnable.reject! { |(queued_fiber, queued_value)| queued_fiber.equal?(fiber) && queued_value.equal?(value) }
        end
        nil
      end

      def kick
        @wake_write.write_nonblock(".", exception: false)
      rescue StandardError
        nil # pipe full (a wake byte is already pending) or closing
      end

      def monotonic
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end
    end
  end
end
