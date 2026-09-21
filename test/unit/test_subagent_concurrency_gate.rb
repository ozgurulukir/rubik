# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/orchestrator/subagent/concurrency_gate"

class TestSubagentConcurrencyGate < Minitest::Test
  def test_initialization_defaults_and_capacity
    gate = Rubik::Orchestrator::Subagent::ConcurrencyGate.new(2)
    assert_equal 2, gate.capacity
    assert_equal 2, gate.available_count
    assert_equal 0, gate.active_count
  end

  def test_capacity_floors_at_one
    gate = Rubik::Orchestrator::Subagent::ConcurrencyGate.new(0)
    assert_equal 1, gate.capacity
  end

  def test_synchronize_limits_concurrency_to_capacity
    gate = Rubik::Orchestrator::Subagent::ConcurrencyGate.new(2)
    max_observed_concurrent = 0
    current_concurrent = 0
    monitor = Monitor.new
    completed = 0

    threads = Array.new(6) do
      Thread.new do
        gate.synchronize do
          monitor.synchronize do
            current_concurrent += 1
            max_observed_concurrent = [max_observed_concurrent, current_concurrent].max
          end

          sleep 0.02

          monitor.synchronize do
            current_concurrent -= 1
            completed += 1
          end
        end
      end
    end

    threads.each(&:join)

    assert_equal 2, max_observed_concurrent, "In-flight concurrency must never exceed capacity (2)"
    assert_equal 6, completed, "All 6 threads must finish successfully"
    assert_equal 2, gate.available_count, "Gate must restore full capacity after all threads finish"
    assert_equal 0, gate.active_count
  end

  def test_synchronize_releases_token_on_exception
    gate = Rubik::Orchestrator::Subagent::ConcurrencyGate.new(2)

    assert_raises(RuntimeError) do
      gate.synchronize do
        raise "simulated LLM provider error"
      end
    end

    assert_equal 2, gate.available_count, "Token must be returned even if exception occurs"
    assert_equal 0, gate.active_count

    # Verify gate is still fully functional
    ran = false
    gate.synchronize { ran = true }
    assert ran
  end
end
