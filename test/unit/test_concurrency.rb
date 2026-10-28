# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/concurrency"

# Boundary semantics of Rubik::Concurrency.silently / .map: block values,
# drain-before-return, drain-then-raise error policy, nesting, revert, and
# the RUBIK_FIBER_SCHEDULER=off kill switch.
class TestConcurrency < Minitest::Test
  def teardown
    Rubik::Concurrency.reset_disabled_cache!
    refute Rubik::Concurrency.active?, "boundary must not leak past the call"
    assert_nil ::Fiber.scheduler, "scheduler must be uninstalled after every call"
  end

  def test_silently_returns_block_value_and_reverts_the_scheduler
    value = Rubik::Concurrency.silently { 40 + 2 }

    assert_equal 42, value
    assert_nil ::Fiber.scheduler
  end

  def test_silently_drains_spawned_fibers_before_returning
    done = []
    Rubik::Concurrency.silently do
      10.times do |i|
        ::Fiber.schedule do
          sleep(0.001 * (10 - i))
          done << i
        end
      end
    end

    assert_equal (0...10).to_a, done.sort
  end

  def test_silently_reraises_the_lowest_ordinal_spawned_error_after_drain
    drained = []
    error = assert_raises RuntimeError do
      Rubik::Concurrency.silently do
        ::Fiber.schedule do
          sleep 0.05
          drained << :late
          raise "late-boom"
        end
        ::Fiber.schedule do
          sleep 0.01
          drained << :early
          raise "early-boom"
        end
      end
    end

    # Spawn-ordinal selection (fiber #1 raised "late-boom"), NOT
    # first-to-complete — the outcome must be deterministic across runs.
    assert_equal "late-boom", error.message
    assert_includes drained, :late # drain completes BEFORE the raise
  end

  def test_silently_body_error_wins_over_spawned_errors
    error = assert_raises RuntimeError do
      Rubik::Concurrency.silently do
        ::Fiber.schedule { raise "spawned-boom" }
        sleep 0.01
        raise "body-boom"
      end
    end

    assert_equal "body-boom", error.message
  end

  def test_silently_uninstalls_the_scheduler_when_the_body_raises
    assert_raises RuntimeError do
      Rubik::Concurrency.silently { raise "x" }
    end

    assert_nil ::Fiber.scheduler
  end

  def test_nested_silently_reuses_the_outer_boundary
    inner_saw_outer = nil
    Rubik::Concurrency.silently do
      Rubik::Concurrency.silently do
        inner_saw_outer = Rubik::Concurrency.active?
      end
      # The nested call must not have closed the outer boundary.
      assert Rubik::Concurrency.active?
    end

    assert inner_saw_outer, "nested silently should run inside the outer boundary"
    refute Rubik::Concurrency.active?
  end

  def test_map_returns_results_in_input_order_regardless_of_completion_order
    results = Rubik::Concurrency.map([5, 1, 3]) do |n|
      sleep(0.02 * n)
      n * 100
    end

    assert_equal [500, 100, 300], results
  end

  def test_map_reraises_the_lowest_input_index_error_after_drain
    completed = []
    error = assert_raises RuntimeError do
      Rubik::Concurrency.map([:a, :b, :c]) do |item|
        case item
        when :b then raise "b-boom"
        when :c then raise "c-boom"
        else
          sleep 0.05
          completed << :a
        end
      end
    end

    assert_equal "b-boom", error.message
    assert_includes completed, :a # every item finished before the raise
  end

  def test_map_bounds_simultaneously_live_fibers_with_concurrency
    live = 0
    peak = 0
    lock = Mutex.new
    Rubik::Concurrency.map(20.times.to_a, concurrency: 3) do
      lock.synchronize do
        live += 1
        peak = [peak, live].max
      end
      sleep 0.01
      lock.synchronize { live -= 1 }
    end

    assert_equal 3, peak
  end

  def test_map_runs_inside_silently_without_a_second_boundary
    orders = Rubik::Concurrency.silently do
      Rubik::Concurrency.map(3.times.to_a) do |i|
        sleep(0.01 * (3 - i))
        i
      end
    end

    assert_equal [0, 1, 2], orders
  end

  def test_map_with_empty_enumerable_returns_empty_array
    assert_equal [], Rubik::Concurrency.map([]) { |i| i }
  end

  def test_kill_switch_degrades_to_sequential_execution
    ENV["RUBIK_FIBER_SCHEDULER"] = "off"
    Rubik::Concurrency.reset_disabled_cache!

    order = []
    results = Rubik::Concurrency.map(3.times.to_a) do |i|
      order << i
      i
    end
    value = Rubik::Concurrency.silently { :plain }

    assert_equal [0, 1, 2], order # strictly sequential, no interleaving
    assert_equal [0, 1, 2], results
    assert_equal :plain, value
    assert_nil ::Fiber.scheduler
  ensure
    ENV.delete("RUBIK_FIBER_SCHEDULER")
    Rubik::Concurrency.reset_disabled_cache!
  end

  def test_disabled_returns_true_when_env_is_off_case_insensitively
    ["off", "OFF", "Off", "oFf"].each do |off_val|
      ENV["RUBIK_FIBER_SCHEDULER"] = off_val
      Rubik::Concurrency.reset_disabled_cache!
      assert_equal true, Rubik::Concurrency.disabled?, "Expected disabled? to be true for RUBIK_FIBER_SCHEDULER=#{off_val}"
    end
  ensure
    ENV.delete("RUBIK_FIBER_SCHEDULER")
    Rubik::Concurrency.reset_disabled_cache!
  end

  def test_disabled_returns_false_when_env_is_not_off
    [nil, "", "on", "ON", "auto", "0", "false", "1"].each do |non_off_val|
      if non_off_val.nil?
        ENV.delete("RUBIK_FIBER_SCHEDULER")
      else
        ENV["RUBIK_FIBER_SCHEDULER"] = non_off_val
      end
      Rubik::Concurrency.reset_disabled_cache!
      assert_equal false, Rubik::Concurrency.disabled?, "Expected disabled? to be false for RUBIK_FIBER_SCHEDULER=#{non_off_val.inspect}"
    end
  ensure
    ENV.delete("RUBIK_FIBER_SCHEDULER")
    Rubik::Concurrency.reset_disabled_cache!
  end

  def test_disabled_memoizes_value_until_reset_disabled_cache
    ENV["RUBIK_FIBER_SCHEDULER"] = "off"
    Rubik::Concurrency.reset_disabled_cache!
    assert_equal true, Rubik::Concurrency.disabled?

    # Mutate ENV without resetting cache
    ENV["RUBIK_FIBER_SCHEDULER"] = "on"
    assert_equal true, Rubik::Concurrency.disabled?, "Expected cached disabled? value to persist"

    # Reset cache seam and verify it re-reads ENV
    Rubik::Concurrency.reset_disabled_cache!
    assert_equal false, Rubik::Concurrency.disabled?, "Expected reset_disabled_cache! to invalidate memoized state"
  ensure
    ENV.delete("RUBIK_FIBER_SCHEDULER")
    Rubik::Concurrency.reset_disabled_cache!
  end
end
