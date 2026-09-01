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
    dead_client.instance_variable_set(:@running, true)
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
