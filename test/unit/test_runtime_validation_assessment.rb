# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../dev/runtime_validation/assessment"
require_relative "../../dev/runtime_validation/scheduler_harness"

class TestRuntimeValidationAssessment < Minitest::Test
  Assessment = Rubik::RuntimeValidation::Assessment

  def test_leaks_and_missing_probes_cannot_pass
    baseline = { threads: 1, child_processes: 0, ruby_fibers: 1, child_contexts: 0, open_fds: 5, rss_kb: 100 }
    final = baseline.merge(open_fds: 9, rss_kb: 62_000)
    assert_equal "FAIL", Assessment.verdict(Assessment.resource_checks(baseline, final).values)
    assert_equal "INCONCLUSIVE", Assessment.verdict(Assessment.resource_checks(baseline, baseline.merge(open_fds: nil)).values)
    assert_equal "PASS", Assessment.verdict(Assessment.resource_checks(baseline, baseline).values)
  end

  def test_slow_or_failed_requests_cannot_pass
    result = { count: 1000, failed: 0, duration_s: 1, p50_ms: 100, p95_ms: 200 }
    assert Assessment.requests_passed?(result)
    refute Assessment.requests_passed?(result.merge(p95_ms: 5000))
    refute Assessment.requests_passed?(result.merge(failed: 1))
    assert_nil Assessment.requests_passed?({ inconclusive: true })
    assert_equal "FAIL", Assessment.verdict([true, false, nil])
  end

  def test_comparison_failure_restores_environment_and_stops_server
    harness = Rubik::RuntimeValidation::SchedulerHarness.new
    old = ENV.fetch("RUBIK_FIBER_SCHEDULER", nil)
    ENV["RUBIK_FIBER_SCHEDULER"] = "original"
    stopped = false
    harness.stub(:start_server, [1234, -> { stopped = true }]) do
      Rubik::Concurrency.stub(:map, ->(*) { raise IOError, "fixture failure" }) do
        assert_raises(IOError) { harness.send(:bench_scheduler_comparison) }
      end
    end
    assert stopped
    assert_equal "original", ENV.fetch("RUBIK_FIBER_SCHEDULER", nil)
  ensure
    ENV["RUBIK_FIBER_SCHEDULER"] = old
    Rubik::Concurrency.reset_disabled_cache!
  end
end
