# frozen_string_literal: true

require_relative "../test_helper"

class TestLSPCircuitBreaker < Minitest::Test
  def setup
    @config = Rubik::Config.new
    @config.set("lsp.enabled", true)
    @config.set("lsp.auto_start", true)
    @manager = Rubik::LSP::Manager.new(config: @config)
  end

  def teardown
    @manager.stop_all
  end

  def test_circuit_is_initially_closed
    refute @manager.circuit_open?("ruby")
    refute @manager.circuit_open?("go")
  end

  def test_recording_crashes_trips_circuit_after_threshold
    refute @manager.circuit_open?("python")

    # 1st crash
    @manager.record_crash("python")
    refute @manager.circuit_open?("python")

    # 2nd crash
    @manager.record_crash("python")
    refute @manager.circuit_open?("python")

    # 3rd crash -> TRIPS circuit
    @manager.record_crash("python")
    assert @manager.circuit_open?("python")
  end

  def test_circuit_open_prevents_automatic_start_during_ensure_healthy
    # Force open circuit for rust
    3.times { @manager.record_crash("rust") }
    assert @manager.circuit_open?("rust")

    dead_client = Rubik::LSP::Client.new("rust", root_dir: Dir.pwd)
    dead_client.transport.instance_variable_set(:@running, true)
    dead_client.define_singleton_method(:alive?) { false }
    dead_client.define_singleton_method(:stop) { true }

    result = @manager.ensure_healthy!(dead_client)
    assert_nil result
  end

  def test_reset_circuit_restores_closed_state
    3.times { @manager.record_crash("go") }
    assert @manager.circuit_open?("go")

    @manager.reset_circuit!("go")
    refute @manager.circuit_open?("go")
  end
end

# Direct unit coverage for the extracted object (issue #497).
class TestLSPCircuitBreakerUnit < Minitest::Test
  def setup
    @breaker = Rubik::LSP::CircuitBreaker.new
  end

  def test_initially_closed_per_language
    refute @breaker.open?("ruby")
    refute @breaker.open?("go")
    assert_empty @breaker.crash_stats
  end

  def test_opens_after_threshold_consecutive_crashes
    2.times { @breaker.record_crash("python") }
    refute @breaker.open?("python")

    @breaker.record_crash("python")
    assert @breaker.open?("python")
  end

  def test_circuits_are_independent_per_language
    3.times { @breaker.record_crash("zig") }
    assert @breaker.open?("zig")
    refute @breaker.open?("ruby")
  end

  def test_reset_clears_history_and_starts_stability_window
    3.times { @breaker.record_crash("go") }
    assert @breaker.open?("go")

    @breaker.reset!("go")
    refute @breaker.open?("go")
    assert_empty @breaker.crash_stats
  end

  def test_crash_after_healthy_start_retains_recent_history
    @breaker.note_healthy_start("ruby")
    @breaker.record_crash("ruby")
    assert_equal 1, @breaker.crash_stats.dig("ruby", :count)
    refute @breaker.open?("ruby")
  end

  def test_lang_keys_are_normalized_to_downcase_strings
    3.times { @breaker.record_crash("RUBY") }
    assert @breaker.open?("Ruby")
    assert @breaker.crash_stats.key?("ruby")
  end
end
