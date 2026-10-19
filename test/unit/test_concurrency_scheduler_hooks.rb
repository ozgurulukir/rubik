# frozen_string_literal: true

require "English"
require_relative "../test_helper"
require "socket"
require "open3"
require "monitor"
require_relative "../../lib/rubik/concurrency"

# Hook-level contracts of the scheduler core: the 3.3/4.0 dual fiber
# protocol, timer scale, io_wait semantics, pipe-read interleaving through
# io_read/io_write, cross-fiber Mutex and Monitor behavior, Thread#join,
# process_wait, DNS resolution, the self-pipe wake, and interrupt/close
# lifecycle. The ground-truth VM behaviors these pin were verified by probe
# against Ruby 4.0.6 (plan §2, _plan/fiber-scheduler-silent-concurrency-2026-10-05.md).
class TestConcurrencySchedulerHooks < Minitest::Test
  def teardown
    assert_nil ::Fiber.scheduler, "scheduler must be uninstalled after every boundary"
  end

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # The only Ruby-3.3/4.0 protocol drift point: 4.0 hands the block to the
  # scheduler (which creates the fiber); 3.3 handed a pre-created fiber.
  # Both invocation styles must work when called directly.
  def test_fiber_hook_supports_both_creation_protocols
    scheduler = Rubik::Concurrency::Scheduler.new(Rubik::Concurrency::EventLoop.new)

    created = scheduler.fiber { :v40_style }
    assert_instance_of ::Fiber, created

    prebuilt = ::Fiber.new(blocking: false) { :v33_style }
    returned = scheduler.fiber(prebuilt, prebuilt.instance_variable_get(:@block))
    assert_same prebuilt, returned
  end

  def test_kernel_sleep_scales_to_a_thousand_concurrent_timers
    t0 = clock
    done = 0
    Rubik::Concurrency.silently do
      1000.times do
        ::Fiber.schedule do
          sleep 0.01
          done += 1
        end
      end
    end

    assert_equal 1000, done
    assert_operator clock - t0, :<, 2.5, "1000 concurrent sleeps must interleave (serial floor is ~10s)"
  end

  def test_io_wait_reports_ready_events_and_times_out_falsily
    server = TCPServer.new("127.0.0.1", 0)
    peer = TCPSocket.new("127.0.0.1", server.addr[1])
    client = server.accept

    timed_out = Rubik::Concurrency.silently { peer.wait_readable(0.05) }
    ready_at = Queue.new
    Rubik::Concurrency.silently do
      ::Fiber.schedule do
        ready_at << peer.wait_readable
      end
      ::Fiber.schedule do
        sleep 0.02
        client.write("x")
      end
    end
    got = peer.read_nonblock(1)

    refute timed_out, "io_wait timeout must look falsy to IO#wait_readable callers"
    assert ready_at.pop, "readiness must wake the waiting fiber"
    assert_equal "x", got
  ensure
    [server, peer, client].each do |io|
      io.close
    rescue
      nil
    end
  end

  def test_pipe_reads_complete_correctly_across_fibers_via_io_read
    # In-process pipe pairs (no child processes): each item's reader fiber
    # parks in IO#read — which routes through the io_read hook — until its
    # writer thread delivers the payload and closes (EOF through io_read's
    # nil path). Correctness is asserted here; the WALL-CLOCK interleave
    # proof lives with the socket tests — under a bundler parent, Windows
    # staggers child processes equally for fibers and plain threads
    # (measured 8 × 0.5 s children ≈ 4 s either way), so process timing is
    # an environment property, not a scheduler one.
    outputs = Rubik::Concurrency.map(8.times.to_a) do |i|
      reader, writer = ::IO.pipe
      ::Thread.new do
        sleep 0.02
        writer.write("payload-#{i}")
        writer.close
      end
      data = reader.read
      reader.close
      data
    end

    assert_equal 8.times.map { |i| "payload-#{i}" }, outputs
  end

  def test_cross_fiber_mutex_parks_via_block_hook_without_thread_error
    mutex = Mutex.new
    trace = []
    Rubik::Concurrency.silently do
      ::Fiber.schedule do
        mutex.synchronize do
          trace << "a-locked"
          sleep 0.05
        end
        trace << "a-released"
      end
      sleep 0.01
      ::Fiber.schedule do
        mutex.synchronize { trace << "b-locked" }
        trace << "b-released"
      end
    end

    assert_equal ["a-locked", "a-released", "b-locked", "b-released"], trace
  end

  # Characterization pin (plan R2): Monitor cooperates with fibers on this
  # interpreter — same-thread fibers hand the monitor off like Mutex does.
  # Future adoption inside Monitor-guarded managers relies on this.
  def test_monitor_reentrancy_is_fiber_cooperative_on_this_ruby
    monitor = Monitor.new
    trace = []
    Rubik::Concurrency.silently do
      ::Fiber.schedule do
        monitor.synchronize do
          trace << "a-locked"
          sleep 0.05
        end
        trace << "a-released"
      end
      sleep 0.01
      ::Fiber.schedule do
        monitor.synchronize { trace << "b-locked" }
        trace << "b-released"
      end
    end

    assert_equal ["a-locked", "a-released", "b-locked", "b-released"], trace
  end

  def test_thread_join_from_a_scheduled_fiber_returns_the_value
    value = Rubik::Concurrency.silently do
      ::Thread.new do
        sleep 0.05
        42
      end.value
    end

    assert_equal 42, value
  end

  def test_process_wait_reaps_spawned_children_from_fibers
    pid_status = Rubik::Concurrency.silently do
      pid = ::Process.spawn(RbConfig.ruby, "-e", "exit 3")
      ::Process.wait(pid)
      $?
    end

    assert_instance_of Process::Status, pid_status
    assert_equal 3, pid_status.exitstatus
  end

  def test_address_resolve_parks_and_returns_ip_strings
    # White-box: drive the loop's own resolver inside a boundary — the
    # fiber parks via the block hook and a DNS-pool worker thread wakes it
    # through unpark/self-pipe. The VM contract (4.0) is a list of IP
    # STRINGS (ruby's own test scheduler maps to ip_address likewise).
    ips = nil
    t0 = clock
    Rubik::Concurrency.silently do
      loop = ::Thread.current.thread_variable_get(Rubik::Concurrency::Boundary::ACTIVE_KEY).loop
      ips = loop.resolve_address("localhost")
    end

    assert_kind_of ::Array, ips
    assert_includes ips.map(&:to_s), "127.0.0.1"
    assert_operator clock - t0, :<, 1.0, "pooled resolution must not stall the loop"

    # Black-box: a hostname connect drives the VM's address_resolve hook
    # end-to-end. The server binds `localhost` itself so the VM's
    # try-first-family (IPv6 ::1 on Windows) finds a listener — against an
    # IPv4-only listener this connect costs a fixed ~2 s INSIDE and OUTSIDE
    # the scheduler alike (VM behavior, not a scheduler property).
    server = TCPServer.new("localhost", 0)
    port = server.addr[1]
    Thread.new do
      loop do
        client = server.accept
        client&.close
      end
    rescue StandardError
      nil
    end

    connected = Rubik::Concurrency.silently do
      TCPSocket.new("localhost", port).close
      true
    rescue StandardError
      false
    end
    assert connected, "hostname connect through the DNS pool must succeed"
  rescue Errno::EADDRNOTAVAIL, Errno::EAFNOSUPPORT
    skip "IPv6 loopback unavailable"
  ensure
    server&.close
  end

  def test_cross_thread_wake_interrupts_the_loop_select_via_self_pipe
    mutex = Mutex.new
    holder = ::Thread.new do
      mutex.synchronize { sleep 0.15 }
    end
    t0 = clock
    sleep 0.005 until mutex.locked?

    Rubik::Concurrency.silently do
      # The fiber parks on the mutex via the block hook; the ONLY possible
      # wakeup is the foreign holder thread's unblock — delivered through
      # the self-pipe or never (select has nothing else to watch).
      mutex.synchronize { nil }
    end
    elapsed = clock - t0
    holder.join(1)

    assert_operator elapsed, :>=, 0.1, "the fiber must actually wait for the holder"
    assert_operator elapsed, :<, 1.0, "foreign-thread unblock must wake the loop promptly"
  end

  def test_fiber_interrupt_resumes_a_parked_fiber_with_interrupted
    loop = Rubik::Concurrency::EventLoop.new
    scheduler = Rubik::Concurrency::Scheduler.new(loop)
    caught = nil
    ::Fiber.set_scheduler(scheduler)
    fiber = scheduler.fiber do
      sleep 30
    rescue Rubik::Concurrency::Interrupted => e
      caught = e
    end
    waker = ::Thread.new do
      sleep 0.05
      loop.interrupt(fiber)
    end
    loop.run_until_drained
    ::Fiber.set_scheduler(nil)
    waker.join(1)

    assert_instance_of Rubik::Concurrency::Interrupted, caught
  ensure
    ::Fiber.set_scheduler(nil)
    waker&.kill
  end

  def test_scheduler_close_is_idempotent
    loop = Rubik::Concurrency::EventLoop.new
    Rubik::Concurrency::Scheduler.new(loop)

    loop.shutdown
    loop.shutdown # second close must be a no-op, not a raise

    assert loop.closed?
  end
end
