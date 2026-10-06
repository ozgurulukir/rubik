# frozen_string_literal: true

module Rubik
  module Concurrency
    class Error < StandardError; end

    # Raised into a fiber interrupted through the Ruby 4.0 fiber_interrupt
    # hook (a safety net — a healthy boundary drains every fiber before
    # close, so this only surfaces when teardown must cut work short).
    class Interrupted < Interrupt; end

    # Truthy stand-in for Process::Status when a watched pid was already
    # reaped elsewhere (Open3's wait_thr beat us to it): process_wait must
    # return something non-nil or the VM would spin on the dead pid forever.
    StatusLike = Struct.new(:pid, :exitstatus, keyword_init: true)
  end
end
