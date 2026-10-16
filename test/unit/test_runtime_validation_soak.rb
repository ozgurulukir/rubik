# frozen_string_literal: true

require_relative "../test_helper"
require "minitest/mock"
require_relative "../../dev/runtime_validation/telemetry"
require_relative "../../dev/runtime_validation/soak_harness"

class TestRuntimeValidationSoak < Minitest::Test
  def test_process_alive_returns_false_if_proc_stat_disappears
    harness = Rubik::RuntimeValidation::SoakHarness.new(epochs: 1)
    File.stub(:exist?, true) do
      File.stub(:read, ->(*) { raise Errno::ENOENT }) do
        refute harness.send(:process_alive?, Process.pid)
      end
    end
  end

  def test_default_epochs_reach_every_repeated_family
    harness = Rubik::RuntimeValidation::SoakHarness.new
    counts = {}
    [:context_epochs, :service_epochs, :fiber_cycles, :rollback_cycles, :plugin_reload_cycles, :mcp_manager_cycles, :mcp_handshake_failures, :mcp_real_process_cycles,
     :mcp_server_crash_recovery].each do |name|
      harness.define_singleton_method("check_#{name}") do |count|
        counts[name] = count
        []
      end
    end
    harness.define_singleton_method(:check_mcp_inflight_reload) { [] }
    harness.define_singleton_method(:check_mcp_descendant_cleanup) { [] }
    harness.define_singleton_method(:sample_resources) { |*| }

    results = harness.run_all

    assert_equal [1000], counts.values.uniq
    assert_equal [1000], results.first(9).map { |r| r[:epochs] }.uniq
    assert_equal([1, 1], results.last(2).map { |r| r[:epochs] })
  end

  def test_unsupported_probe_is_inconclusive_not_passed
    harness = Rubik::RuntimeValidation::SoakHarness.new(epochs: 1)
    harness.define_singleton_method(:sample_resources) { |*| }
    result = harness.send(:run_family, "unsupported") do
      raise Rubik::RuntimeValidation::SoakHarness::UnsupportedProbe, "probe unavailable"
    end

    assert result[:inconclusive]
    refute result[:passed]
    assert_equal ["probe unavailable"], result[:violations]
  end

  def test_real_manager_fixture_is_cleaned_when_probe_raises
    harness = Rubik::RuntimeValidation::SoakHarness.new(epochs: 1)
    script_path = nil
    context = nil
    assert_raises(RuntimeError) do
      harness.send(:with_real_manager) do |_manager, ctx, _registry, script|
        script_path = script.path
        context = ctx
        raise "injected failure"
      end
    end

    refute File.exist?(script_path)
    assert context.disposed?
  end
end
