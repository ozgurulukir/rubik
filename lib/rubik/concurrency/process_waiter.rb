# frozen_string_literal: true

require "English"
require_relative "errors"

module Rubik
  module Concurrency
    # process_wait hook body. Fast path: a WNOHANG poll satisfies callers
    # that only probe (Process.detach, waitpid(WNOHANG)) without a thread.
    # Blocking path: one short-lived waiter thread per waited pid doing a
    # blocking Process.wait — the fiber's Thread#join on it parks through the
    # block/unblock hooks, so no fiber-visible machinery is needed. Never
    # waits on -1 (that would race Open3's per-child wait_thr reapers).
    #
    # Errno::ECHILD means someone else (usually the Open3 wait thread that
    # spawned the child) reaped the pid first; returning nil forever would
    # make the VM spin on the dead pid, so a truthy StatusLike stands in.
    module ProcessWaiter
      module_function

      def wait(pid, flags, loop)
        # Process.wait returns the PID (Integer); the Process::Status the VM
        # requires as the hook's return lives in $? after the call. ECHILD
        # means another reaper (usually Open3's wait_thr) got the status
        # first; a StatusLike with a NIL exitstatus stands in — truthy for
        # the VM's done-check without fabricating a success/failure code.
        if flags.anybits?(::Process::WNOHANG)
          begin
            reaped = ::Process.wait(pid, flags)
            return reaped.nil? ? nil : $CHILD_STATUS
          rescue Errno::ECHILD
            return Errors::StatusLike.new(pid: pid, exitstatus: nil)
          end
        end

        waiter = ::Thread.new do
          ::Process.wait(pid)
          $CHILD_STATUS
        rescue Errno::ECHILD
          Errors::StatusLike.new(pid: pid, exitstatus: nil)
        rescue StandardError => e
          e
        end
        loop.track_waiter(waiter)
        value = waiter.value
        # Waiter failure arrives as the thread value; the VM expects a
        # Process::Status-shaped return, so RAISE the original error here —
        # returning it as data would surface as an opaque TypeError.
        raise value if value.is_a?(::Exception)

        value
      end
    end
  end
end
