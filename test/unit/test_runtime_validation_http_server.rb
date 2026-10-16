# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../dev/runtime_validation/scheduler_harness"

class TestRuntimeValidationHTTPServer < Minitest::Test
  def test_idle_server_disposal_stops_every_worker_promptly
    baseline = Thread.list
    _port, stop = Rubik::RuntimeValidation::SchedulerHarness.new.send(:start_server)
    workers = Thread.list - baseline
    assert_equal 8, workers.size

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stop.call

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    refute workers.any?(&:alive?), "listener workers must finish before disposal returns"
  rescue Errno::EPERM, Errno::EACCES
    skip "Socket binding not permitted in this environment"
  ensure
    stop&.call
  end

  def test_timeout_and_cancellation_dispose_the_server_workers
    baseline = Rubik::RuntimeValidation::Telemetry.active_user_thread_count
    result = Rubik::RuntimeValidation::SchedulerHarness.new.send(:bench_timeout_cancel)
    skip result[:reason] if result[:inconclusive]

    assert result[:passed], result.inspect
    assert_equal baseline, Rubik::RuntimeValidation::Telemetry.active_user_thread_count
  end
end
