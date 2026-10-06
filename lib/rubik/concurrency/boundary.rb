# frozen_string_literal: true

require_relative "event_loop"
require_relative "scheduler"

module Rubik
  module Concurrency
    # Thread-scoped scope around an event loop: install scheduler → run body
    # as a fiber → drain every spawned fiber → uninstall (revertible by
    # construction — the install's inverse lives in the same ensure).
    #
    # The active marker is a THREAD variable (not fiber-local): fibers on the
    # thread share the boundary. Nested opens reuse the outer loop, so a
    # .map inside .silently joins the same drain instead of nesting loops.
    module Boundary
      ACTIVE_KEY = :"rubik.concurrency.boundary"

      module_function

      # Returns the block's value. Error policy (K7): the body's own error
      # wins; otherwise the LOWEST-ordinal spawned-fiber error is raised
      # after the drain, and its siblings are logged (never swallowed). An
      # exception arriving during the drain (Interrupt, Ctrl-Break's
      # SignalException, …) finishes the drain once, resiliently, then
      # surfaces only if the body did not already fail. The uninstall tail
      # is unconditional: an exception raised inside an ensure block skips
      # the REST of that ensure, so the tail lives in its own nested ensure
      # (otherwise a second Ctrl-C mid-drain could leave the scheduler
      # installed on the thread, hanging every later boundary).
      def open(&)
        return yield if ::Thread.current.thread_variable_get(ACTIVE_KEY)

        loop = EventLoop.new
        scheduler = Scheduler.new(loop)
        drain_error = nil

        ::Fiber.set_scheduler(scheduler)
        ::Thread.current.thread_variable_set(ACTIVE_KEY, scheduler)
        begin
          result, body_error = loop.run(&)
        ensure
          begin
            begin
              loop.run_until_drained
            rescue ::Exception => e # rubocop:disable Lint/RescueException -- cleanup isolation; re-raised below
              drain_error = e
              Rubik::Log.warn(:concurrency, "#{e.class} during drain; finishing drain")
              begin
                loop.run_until_drained
              rescue ::Exception => e2 # rubocop:disable Lint/RescueException -- second failure: abandon the drain
                Rubik::Log.warn(:concurrency, "#{e2.class} during second drain; abandoning remaining work")
              end
            end
          ensure
            ::Thread.current.thread_variable_set(ACTIVE_KEY, nil)
            ::Fiber.set_scheduler(nil)
            loop.shutdown
          end
        end

        raise body_error if body_error
        raise drain_error if drain_error

        errors = loop.spawn_errors.sort_by(&:first)
        errors.each do |(ordinal, error)|
          Rubik::Log.warn(:concurrency, "spawned fiber ##{ordinal} failed: #{error.class}: #{error.message}")
        end
        raise errors.first[1] if errors.any?

        result
      end
    end
  end
end
