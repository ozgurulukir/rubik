# frozen_string_literal: true

module Rubik
  module Concurrency
    # Bounded worker pool for getaddrinfo: MRI's resolver blocks the whole OS
    # thread, so a scheduler-side address_resolve must run it elsewhere or a
    # single slow DNS lookup would stall the event loop. Workers deliver the
    # Addrinfo list (or an exception to raise) back to the parked fiber via
    # EventLoop#unpark, which self-pipe-wakes the loop.
    class DnsPool
      SIZE = 4
      SHUTDOWN = Object.new

      def initialize(loop)
        @loop = loop
        @jobs = ::Queue.new
        @workers = SIZE.times.map do
          ::Thread.new { worker_loop }
        end
      end

      def resolve(hostname)
        blocker = ::Object.new
        @jobs << [hostname, ::Fiber.current, blocker]
        @loop.park(blocker)
      end

      # Never raises; sentinel per worker, bounded join, kill as last resort.
      def shutdown
        SIZE.times { @jobs << SHUTDOWN }
        @workers.each do |thread|
          thread.join(0.1)
          thread.kill if thread.alive?
        end
      rescue StandardError
        nil
      end

      private

      def worker_loop
        while (job = @jobs.pop)
          break if job.equal?(SHUTDOWN)

          hostname, fiber, blocker = job
          value = begin
            # The VM's address_resolve contract on 4.0 is a list of IP
            # strings, NOT Addrinfo objects (verified; ruby's own test
            # scheduler maps to ip_address for the same reason).
            ::Addrinfo.getaddrinfo(hostname, nil).map(&:ip_address).uniq
          rescue StandardError => e
            e
          end
          begin
            @loop.unpark(blocker, fiber, value: value)
          rescue StandardError => e
            # Delivery failure must never strand the fiber parked with no
            # wakeup source (a silent boundary hang): interrupt it instead.
            Rubik::Log.warn(:concurrency, "dns unpark failed: #{e.class}: #{e.message}")
            @loop.interrupt(fiber, Interrupted.new("dns delivery failed"))
          end
        end
      rescue StandardError => e
        Rubik::Log.warn(:concurrency, "dns worker died: #{e.class}: #{e.message}")
      end
    end
  end
end
