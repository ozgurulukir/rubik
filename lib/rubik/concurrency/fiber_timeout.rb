# frozen_string_literal: true

require "timeout"

module Rubik
  module Concurrency
    # #102: Net::HTTP (and any stdlib code) enforces deadlines with the
    # Timeout module — a watchdog Thread that Thread#raises the calling
    # thread when the deadline expires. Under the scheduler that thread is
    # the loop thread, shared by every parked fiber: the raise lands in
    # whichever frame is executing (another fiber's IO.select, the minitest
    # reporter), and after an abandoned drain it fires into unrelated
    # runner code.
    #
    # While a boundary is draining on this thread, Timeout.timeout is
    # fiber-native instead: the block runs inline (no watchdog thread is
    # ever created) and the deadline exception is delivered through the
    # loop's interrupt path at the calling fiber's current park. Outside a
    # drain there is no loop to consume timers, so the stock watchdog
    # applies — a thread-raise into the thread that is genuinely blocked is
    # correctly targeted there.
    module TimeoutPatch
      def timeout(sec = nil, exception_class = nil, message = nil, &)
        scheduler = ::Fiber.scheduler
        if sec.is_a?(::Numeric) && sec.positive? &&
           scheduler.is_a?(::Rubik::Concurrency::Scheduler) && scheduler.native_deadlines?
          return scheduler.fiber_timeout(sec, exception_class, message, &)
        end

        super
      end
    end

    ::Timeout.singleton_class.prepend(TimeoutPatch)
  end
end
