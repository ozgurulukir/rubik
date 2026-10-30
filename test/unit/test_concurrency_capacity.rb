# frozen_string_literal: true

require_relative "../test_helper"
require "socket"
require "net/http"
require_relative "../../lib/rubik/concurrency"

# Issue #151: Quiet Concurrency Scheduler capacity and resilience:
# 1. 100 concurrent requests to a controlled local endpoint.
# 2. 1000 concurrent requests to a controlled local endpoint.
# 3. Timeout and cancel handling without hanging or leaking fibers.
# 4. Graceful skip if network/socket capability is restricted.
class TestConcurrencyCapacity < Minitest::Test
  def setup
    @server = nil
    @workers = []
    @running = false
  end

  def teardown
    @running = false
    @workers.each(&:kill)
    @workers.each { |worker| worker.join(1) }
    begin
      @server&.close
    rescue StandardError
      nil
    end
    Rubik::Concurrency.reset_disabled_cache!
    assert_nil ::Fiber.scheduler, "scheduler must be uninstalled after boundary"
  end

  def start_local_server(delay: 0.0)
    begin
      @server = TCPServer.new("127.0.0.1", 0)
    rescue Errno::EPERM, Errno::EACCES => e
      skip "Socket binding not permitted in this environment (#{e.class}: #{e.message})"
    end

    port = @server.addr[1]
    @running = true
    # Worker pool to accept incoming connections concurrently
    @workers = 8.times.map do
      Thread.new do
        while @running
          sock = nil
          begin
            accepted = @server.accept_nonblock(exception: false)
            if accepted == :wait_readable
              @server.wait_readable(0.05)
              next
            end
            sock = accepted
            # Consume the complete GET request before responding (Windows RST).
            while (header = sock.gets)
              break if header == "\r\n"
            end
            sleep(delay) if delay.positive?
            sock.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
          rescue StandardError
            break unless @running
          ensure
            sock&.close
          end
        end
      end
    end
    port
  end

  def test_100_concurrent_requests_succeed_with_subsecond_latency
    port = start_local_server
    latencies = []

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    results = Rubik::Concurrency.map(100.times.to_a) do
      req_t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      body = Net::HTTP.start("127.0.0.1", port, open_timeout: 2, read_timeout: 2,
                                                write_timeout: 2, max_retries: 0) { |http| http.get("/").body }
      latencies << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - req_t0)
      body
    end
    total_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    assert_equal(100, results.count { |r| r == "ok" })
    assert_operator total_time, :<, 3.0, "100 requests must complete in < 3.0s"

    sorted = latencies.sort
    p50 = sorted[(sorted.size * 0.50).to_i]
    p95 = sorted[(sorted.size * 0.95).to_i]
    assert_operator p50, :<, 0.5, "p50 latency should be under 500ms"
    assert_operator p95, :<, 1.0, "p95 latency should be under 1.0s"
  end

  def test_1000_concurrent_requests_scale_cleanly
    port = start_local_server
    latencies = []

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      results = Rubik::Concurrency.map(1000.times.to_a) do
        req_t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        body = Net::HTTP.start("127.0.0.1", port, open_timeout: 6, read_timeout: 6,
                                                  write_timeout: 6, max_retries: 0) { |http| http.get("/").body }
        latencies << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - req_t0)
        body
      end
    rescue Errno::EMFILE => e
      skip "File descriptor limit too low for 1000 concurrent sockets (#{e.message})"
    end
    total_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    assert_equal(1000, results.count { |r| r == "ok" })
    assert_operator total_time, :<, 6.0, "1000 requests must complete in < 6.0s (measured ~1s)"

    sorted = latencies.sort
    p50 = sorted[(sorted.size * 0.50).to_i]
    p95 = sorted[(sorted.size * 0.95).to_i]
    assert_operator p50, :<, 3.0, "p50 latency for 1000 reqs should be bounded"
    assert_operator p95, :<, 5.5, "p95 latency for 1000 reqs should be bounded"
  end

  def test_timeout_and_cancel_in_fibers_do_not_leak_or_hang
    # Start a server with intentional delay
    port = start_local_server(delay: 2.0)

    timed_out = false
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    Rubik::Concurrency.silently do
      uri = URI("http://127.0.0.1:#{port}/")
      http = Net::HTTP.new(uri.host, uri.port)
      http.max_retries = 0
      http.read_timeout = 0.1
      http.open_timeout = 0.1
      begin
        http.get("/")
      rescue Timeout::Error
        timed_out = true
      end
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    assert timed_out, "read timeout should be raised"
    assert_operator elapsed, :<, 1.5, "timeout must abort promptly without waiting for the full 2.0s delay"
  end
end
