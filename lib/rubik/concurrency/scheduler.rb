# frozen_string_literal: true

require_relative "event_loop"
require_relative "process_waiter"

module Rubik
  module Concurrency
    # Adapter for the VM's Fiber::Scheduler hook protocol — stateless; all
    # state lives on the EventLoop. Ruby 3.3 ↔ 4.0 protocol drift is
    # concentrated here (probes against 4.0.6, plan §2):
    #
    #   fiber    4.0: fiber(&blk) — scheduler creates and returns the fiber.
    #            3.3: fiber(fiber, block) — VM pre-created it.
    #   io_read  integer args differ (3.3 passes length; 4.0 passes 0, 0)
    #   io_write but the buffer is always sized to the operation, so both
    #            hooks drive off buffer.size — see EventLoop#read_io.
    #
    # io_read/io_write are required on 4.0: without them a plain IO#read
    # inside a scheduled fiber falls back to a whole-thread BLOCKING read
    # (measured: 20 × 0.2 s child pipes serialized into 13 s). The buffer is
    # filled/drained with read_nonblock/write_nonblock + IO::Buffer views —
    # IO#nonblock= and IO::Buffer#read(io,...) are NOT usable on Windows
    # builds (NoMethodError / constant-zero reads, verified), while the
    # nonblock(…, exception: false) family works for pipes and sockets alike.
    class Scheduler
      attr_reader :loop

      def initialize(loop)
        @loop = loop
      end

      def fiber(*args, &blk)
        blk ? @loop.spawn_fiber(&blk) : args[0]
      end

      def fiber_interrupt(target, exception = nil)
        @loop.interrupt(target, exception)
        nil
      end

      def io_wait(io, events, timeout)
        @loop.wait_io(io, events, timeout)
      end

      # The integer args differ per protocol (3.3: length; 4.0. offset/length
      # both zero) but the buffer is always sized to the operation, so the
      # EventLoop drives both hooks off buffer.size — see read_io/write_io.
      def io_read(io, buffer, *_protocol_args)
        @loop.read_io(io, buffer)
      end

      def io_write(io, buffer, *_protocol_args)
        @loop.write_io(io, buffer)
      end

      def kernel_sleep(duration = nil)
        duration ? @loop.nap(duration) : @loop.park(:sleep)
        true
      end

      def block(blocker, timeout = nil)
        @loop.park(blocker, timeout)
      end

      def unblock(blocker, fiber)
        @loop.unpark(blocker, fiber)
        nil
      end

      def process_wait(pid, flags)
        ProcessWaiter.wait(pid, flags, @loop)
      end

      def address_resolve(hostname)
        @loop.resolve_address(hostname)
      end

      def scheduler_close
        @loop.shutdown
        nil
      end
    end
  end
end
