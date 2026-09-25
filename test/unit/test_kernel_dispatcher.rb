# frozen_string_literal: true

require_relative "../test_helper"

class TestKernelDispatcher < Minitest::Test
  def setup
    @dmesg = Rubik::Kernel::Dmesg.new(capacity: 256)
    @dispatcher = Rubik::Kernel::Dispatcher.new(dmesg: @dmesg)
  end

  def teardown
    @dispatcher&.stop
  end

  def test_initial_state
    assert @dispatcher.alive?
    refute @dispatcher.stopped?
    assert_equal 0, @dispatcher.queue_size
  end

  def test_sequential_fifo_dispatching_from_single_thread
    received = []
    @dispatcher.subscribe(:step_completed) { |payload| received << payload[:step] }

    10.times { |i| @dispatcher.post(:step_completed, step: i) }
    assert @dispatcher.sync_drain

    assert_equal (0...10).to_a, received
  end

  def test_concurrent_publishers_monotonic_per_thread_and_zero_loss
    num_threads = 5
    events_per_thread = 20
    received = []
    mutex = Mutex.new

    @dispatcher.subscribe(:metric_recorded) do |payload|
      mutex.synchronize { received << payload }
    end

    threads = Array.new(num_threads) do |tid|
      Thread.new do
        events_per_thread.times do |seq|
          @dispatcher.post(:metric_recorded, thread_id: tid, seq: seq)
        end
      end
    end
    threads.each(&:join)

    assert @dispatcher.sync_drain
    assert_equal num_threads * events_per_thread, received.size

    num_threads.times do |tid|
      thread_seqs = received.select { |r| r[:thread_id] == tid }.map { |r| r[:seq] }
      assert_equal (0...events_per_thread).to_a, thread_seqs,
                   "Events published by thread #{tid} must preserve FIFO order"
    end
  end

  def test_subscriber_fault_isolation_and_dmesg_logging
    received_second = []
    @dispatcher.subscribe(:risky_event) { raise "Boom in subscriber!" }
    @dispatcher.subscribe(:risky_event) { |payload| received_second << payload[:val] }

    @dispatcher.post(:risky_event, val: 42)
    assert @dispatcher.sync_drain

    assert @dispatcher.alive?, "Worker thread must survive subscriber exception"
    assert_equal [42], received_second, "Subsequent subscribers must still execute"

    err_records = @dmesg.tail(10, level: :err, subsystem: :kernel)
    assert_equal 1, err_records.size
    assert_includes err_records.first.message, "Subscriber error on risky_event: Boom in subscriber!"

    # Dispatcher continues processing subsequent events normally
    @dispatcher.post(:risky_event, val: 99)
    assert @dispatcher.sync_drain
    assert_equal [42, 99], received_second
  end

  def test_dmesg_automatic_event_telemetry
    @dispatcher.post(
      :subagent_paused,
      { budget: 100, remaining: 0 },
      subsystem: :subagent,
      level: :warn,
      facility_id: "coder-1"
    )
    assert @dispatcher.sync_drain

    records = @dmesg.tail(10, subsystem: :subagent)
    assert_equal 1, records.size
    rec = records.first
    assert_equal :subagent, rec.subsystem
    assert_equal :warn, rec.level
    assert_equal "coder-1", rec.facility_id
    assert_equal "event:subagent_paused", rec.message
    assert_equal 100, rec.data[:budget]
  end

  def test_sync_drain_barrier_synchronization
    latch = Thread::Queue.new
    processed = []

    @dispatcher.subscribe(:blocking_event) do |p|
      latch.pop # simulate in-flight work
      processed << p[:id]
    end

    @dispatcher.post(:blocking_event, id: 1)
    @dispatcher.post(:blocking_event, id: 2)

    drain_finished = false
    drain_thread = Thread.new do
      @dispatcher.sync_drain
      drain_finished = true
    end

    sleep 0.05
    refute drain_finished, "sync_drain must block while events are in-flight"

    # Release workers
    latch.push(true)
    latch.push(true)
    drain_thread.join

    assert drain_finished
    assert_equal [1, 2], processed
  end

  def test_sync_drain_reentrancy_does_not_deadlock
    inner_drain_returned = false
    @dispatcher.subscribe(:reentrant_event) do
      inner_drain_returned = @dispatcher.sync_drain(0.5)
    end

    @dispatcher.post(:reentrant_event)
    assert @dispatcher.sync_drain

    assert inner_drain_returned, "Reentrant sync_drain from worker thread must return immediately without deadlock"
  end

  def test_unsubscribe_removes_listener_revertibly
    received = []
    token = @dispatcher.subscribe(:ping) { |p| received << p[:msg] }

    @dispatcher.post(:ping, msg: "first")
    assert @dispatcher.sync_drain
    assert_equal ["first"], received

    @dispatcher.unsubscribe(:ping, token)
    @dispatcher.post(:ping, msg: "second")
    assert @dispatcher.sync_drain

    assert_equal ["first"], received, "Unsubscribed listener must not receive further events"
  end

  def test_unsubscribe_by_token_alone
    received = []
    token = @dispatcher.subscribe(:ping) { |p| received << p[:msg] }

    @dispatcher.unsubscribe(token)
    @dispatcher.post(:ping, msg: "ignored")
    assert @dispatcher.sync_drain

    assert_empty received
  end

  def test_context_dispose_cleans_up_subscription_and_stops_dispatcher
    ctx = Rubik::Runtime::Context.new
    received = []

    # Bind subscription to context lifecycle
    @dispatcher.subscribe(:temp_event, context: ctx) { |p| received << p[:n] }

    # Bind dispatcher lifecycle to context
    ctx.provide(Rubik::Coeffects::DISPATCHER, @dispatcher)
    ctx.on_dispose { @dispatcher.stop }

    @dispatcher.post(:temp_event, n: 1)
    assert @dispatcher.sync_drain
    assert_equal [1], received

    # Context disposal triggers LIFO cleanup
    ctx.dispose

    assert @dispatcher.stopped?, "Dispatcher must be stopped on context dispose"
    refute @dispatcher.alive?, "Worker thread must not be alive after stop"
    assert_equal 0, @dispatcher.subscribers(:temp_event).size, "Subscription must be cleared"
  end

  def test_non_blocking_post
    entered_queue = Thread::Queue.new
    release_queue = Thread::Queue.new

    @dispatcher.subscribe(:slow_event) do
      entered_queue.push(true)
      release_queue.pop
    end

    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    posted = @dispatcher.post(:slow_event)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

    assert posted
    assert_operator elapsed, :<, 0.05, "post must be non-blocking and return immediately"

    # Wait for subscriber to pick it up and release it
    entered_queue.pop
    release_queue.push(true)
    assert @dispatcher.sync_drain
  end

  def test_stop_from_worker_thread_does_not_deadlock_or_raise
    stopped_inside = false
    @dispatcher.subscribe(:stop_myself) do
      stopped_inside = @dispatcher.stop(0.5)
    end
    @dispatcher.post(:stop_myself)
    sleep 0.05
    assert stopped_inside, "Stopping dispatcher from worker thread must succeed without ThreadError"
    assert @dispatcher.stopped?
  end

  def test_event_bus_dispatcher_swap_transfers_listeners_and_stops_old_worker
    bus = Rubik::EventBus.new
    old_dispatcher = bus.dispatcher
    received = []
    bus.subscribe(:swap_event) { |p| received << p[:val] }

    new_dispatcher = Rubik::Kernel::Dispatcher.new
    bus.dispatcher = new_dispatcher

    assert old_dispatcher.stopped?, "Old dispatcher must be stopped on swap"
    bus.emit(:swap_event, val: "migrated")

    assert_equal ["migrated"], received
  ensure
    bus&.stop
    new_dispatcher&.stop
  end
end
