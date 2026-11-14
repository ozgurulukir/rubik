# frozen_string_literal: true

require_relative "../test_helper"

# Grace-then-kill reaper for abandoned tool workers (issue #449), behind
# `tools.timeout_kill_after`. Knob unset ⇒ pure abandonment — no registry
# traffic, no reaper thread, existing behavior byte-identical. Knob set ⇒
# abandoned workers are handed to a Monitor-synchronized registry and a
# reaper thread force-kills any worker still running once the grace elapses,
# exiting as soon as the registry drains.
class TestToolTimeoutReaper < Minitest::Test
  TOOL_TIMEOUT = Rubik::Orchestrator::ToolTimeout
  BUDGET_EXCEEDED = TOOL_TIMEOUT::BudgetExceeded

  CALL_TIMEOUT = 0.05
  GRACE = 0.3

  class ConfigDouble
    def initialize(data = {})
      @data = data
    end

    def fetch(key, default = nil)
      @data.key?(key) ? @data[key] : default
    end
  end

  def setup
    @saved_env = ENV.fetch("RUBIK_TOOLS_CALL_TIMEOUT", nil)
    ENV.delete("RUBIK_TOOLS_CALL_TIMEOUT")
  end

  def teardown
    # Safety net: never leak a looping worker or a parked reaper into the
    # next test, even if an assertion aborted mid-scenario.
    TOOL_TIMEOUT.pending_kills.each { |entry| entry[:thread].kill }
    wait_until(2) { TOOL_TIMEOUT.pending_kills.empty? || !TOOL_TIMEOUT.reaper_alive? }
    if @saved_env.nil?
      ENV.delete("RUBIK_TOOLS_CALL_TIMEOUT")
    else
      ENV["RUBIK_TOOLS_CALL_TIMEOUT"] = @saved_env
    end
  end

  def test_knob_unset_keeps_pure_abandonment
    worker = nil
    error = assert_raises(BUDGET_EXCEEDED) do
      TOOL_TIMEOUT.call(nil,
                        config: ConfigDouble.new("tools.call_timeout" => CALL_TIMEOUT),
                        canonical_name: "stuck_tool") do
        worker = Thread.current
        loop { sleep 0.01 }
      end
    end
    assert_equal "stuck_tool", error.tool_name
    assert wait_until(1) { !worker.nil? }, "worker body never started"
    assert worker.alive?, "knob unset must keep the abandonment behavior (worker untouched)"
    assert_empty TOOL_TIMEOUT.pending_kills, "knob unset must not register kills"
    refute TOOL_TIMEOUT.reaper_alive?, "knob unset must not spawn a reaper"
  ensure
    worker&.kill
    wait_until(1) { worker.nil? || !worker.alive? }
  end

  def test_knob_set_kills_abandoned_worker_after_grace
    worker = nil
    logs = []
    config = ConfigDouble.new("tools.call_timeout" => CALL_TIMEOUT, "tools.timeout_kill_after" => GRACE)
    Rubik::Log.stub(:warn, log_recorder(logs)) do
      assert_raises(BUDGET_EXCEEDED) do
        TOOL_TIMEOUT.call(nil, config: config, canonical_name: "stuck_tool") do
          worker = Thread.current
          loop { sleep 0.01 }
        end
      end
      assert wait_until(1) { !worker.nil? }, "worker body never started"
      assert worker.alive?, "worker must still run during the grace window"
      assert wait_until(2) { TOOL_TIMEOUT.pending_kills.empty? }, "reaper must drain the registry"
      assert wait_until(2) { !TOOL_TIMEOUT.reaper_alive? }, "reaper must exit once the registry empties"
      assert wait_until(1) { !worker.alive? }, "abandoned worker must be killed after the grace"
    end
    kill_log = logs.find { |msg| msg.include?("stuck_tool") && msg.include?("killed it") }
    assert kill_log, "the kill must be logged with the tool name under the tools tag"
  ensure
    worker&.kill
  end

  def test_worker_finishing_during_grace_is_not_killed
    worker = nil
    release = Queue.new
    logs = []
    config = ConfigDouble.new("tools.call_timeout" => CALL_TIMEOUT, "tools.timeout_kill_after" => GRACE)
    error = nil
    Rubik::Log.stub(:warn, log_recorder(logs)) do
      error = assert_raises(BUDGET_EXCEEDED) do
        TOOL_TIMEOUT.call(nil, config: config, canonical_name: "slow_then_done") do
          worker = Thread.current
          release.pop
          :done
        end
      end
      assert wait_until(1) { !worker.nil? }, "worker body never started"
      release << true
      assert wait_until(2) { !worker.alive? }, "worker must finish on its own, not be killed"
      assert wait_until(2) { TOOL_TIMEOUT.pending_kills.empty? }, "reaper must clean the finished entry"
      assert wait_until(2) { !TOOL_TIMEOUT.reaper_alive? }, "reaper must exit once the registry empties"
    end
    assert_equal BUDGET_EXCEEDED, error.class
    late_log = logs.find { |msg| msg.include?("slow_then_done") && msg.include?("finished late") }
    assert late_log, "the late-completion log path must stay intact"
    refute logs.any? { |msg| msg.include?("killed it") }, "a worker that finished during the grace must not be killed"
  end

  def test_reaper_respawns_for_later_abandonments_and_exits_again
    config = ConfigDouble.new("tools.call_timeout" => CALL_TIMEOUT, "tools.timeout_kill_after" => GRACE)

    worker_a = abandon_looping_tool(config, "stuck_a")
    assert wait_until(2) { TOOL_TIMEOUT.pending_kills.empty? && !TOOL_TIMEOUT.reaper_alive? }
    refute worker_a.alive?

    worker_b = abandon_looping_tool(config, "stuck_b")
    assert wait_until(2) { TOOL_TIMEOUT.pending_kills.empty? && !TOOL_TIMEOUT.reaper_alive? }
    refute worker_b.alive?
  end

  private

  # Runs a tool whose body loops forever, lets the budget abandon it, and
  # returns the worker thread (after the body has demonstrably started).
  def abandon_looping_tool(config, name)
    worker = nil
    assert_raises(BUDGET_EXCEEDED) do
      TOOL_TIMEOUT.call(nil, config: config, canonical_name: name) do
        worker = Thread.current
        loop { sleep 0.01 }
      end
    end
    assert wait_until(1) { !worker.nil? }, "worker body never started"
    worker
  end

  def log_recorder(sink)
    ->(subsystem, message) { sink << "#{subsystem}: #{message}" }
  end
end
