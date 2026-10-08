# frozen_string_literal: true

require_relative "../test_helper"

# The bounded-join mechanics and the env-tristate async-knob resolution,
# single-homed by arch-deepening 2026-10-08 #12 (was: join_boot_safely
# mirroring join_indexer_safely; the ast.async_warm tristate copied
# verbatim onto mcp.async_load).
class TestBackgroundBootIdiom < Minitest::Test
  def test_returns_no_thread_status_for_nil_handle
    assert_equal :no_thread, Rubik::Concurrency::Join.thread(nil)
  end

  def test_joins_a_finished_thread_without_bound
    th = Thread.new { 1 }
    th.join

    assert_equal :joined, Rubik::Concurrency::Join.thread(th)
  end

  def test_reports_timeout_when_deadline_lapses
    th = Thread.new { loop { sleep 0.01 } }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result = Rubik::Concurrency::Join.thread(th, timeout: 0.1)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal :timeout, result
    assert_operator elapsed, :<, 2, "bounded join must not wait for the thread"
  ensure
    th&.kill
    th&.join
  end

  def test_joins_a_thread_finishing_inside_the_bound
    th = Thread.new { sleep 0.02 }

    assert_equal :joined, Rubik::Concurrency::Join.thread(th, timeout: 5)
  end

  def test_returns_join_failure_as_data_never_raises
    th = Thread.new { raise StandardError, "boot thread died" }

    result = Rubik::Concurrency::Join.thread(th)

    assert_instance_of StandardError, result
    assert_equal "boot thread died", result.message
  end

  def test_async_knob_explicit_values_win_over_test_armor
    with_rubik_test("1") do
      assert_equal true, Rubik::Platform.async_knob(duck_config("ast.async_warm" => true), "ast.async_warm")
      assert_equal false, Rubik::Platform.async_knob(duck_config("ast.async_warm" => false), "ast.async_warm")
    end
  end

  def test_async_knob_nil_falls_back_to_rubik_test_env
    with_rubik_test("1") do
      assert_equal false, Rubik::Platform.async_knob(duck_config("ast.async_warm" => nil), "ast.async_warm")
    end
    with_rubik_test(nil) do
      assert_equal true, Rubik::Platform.async_knob(duck_config("mcp.async_load" => nil), "mcp.async_load")
    end
  end

  private

  # Duck-type of the REPL config surface: fetch(key, default).
  class DuckConfig
    def initialize(pairs)
      @pairs = pairs
    end

    def fetch(key, default = nil)
      @pairs.fetch(key, default)
    end
  end

  def duck_config(pairs)
    DuckConfig.new(pairs)
  end

  def with_rubik_test(value)
    old = ENV.fetch("RUBIK_TEST", nil)
    assign_rubik_test(value)
    yield
  ensure
    assign_rubik_test(old)
  end

  def assign_rubik_test(value)
    if value.nil?
      ENV.delete("RUBIK_TEST")
    else
      ENV["RUBIK_TEST"] = value
    end
  end
end
