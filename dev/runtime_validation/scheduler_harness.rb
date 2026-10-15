# frozen_string_literal: true

require "socket"
require "net/http"

module Rubik
  module RuntimeValidation
    # Quiet Concurrency Fiber Scheduler capacity harness.
    # Benchmarks 100 and 1000 concurrent requests, timeout/cancel, and scheduler-off comparison.
    class SchedulerHarness
      def run_all
        {
          requests100: bench_requests(100),
          requests1000: bench_requests(1000),
          timeout_cancel: bench_timeout_cancel,
          scheduler_comparison: bench_scheduler_comparison
        }
      end

      private

      def bench_requests(count)
        port, stop_proc = start_server
        latencies = []

        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        results = Rubik::Concurrency.map(count.times.to_a) do
          req_t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          body = Net::HTTP.get(URI("http://127.0.0.1:#{port}/"))
          latencies << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - req_t0) * 1000.0)
          body
        end
        total_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
        stop_proc.call

        success = results.count { |r| r == "ok" }
        sorted = latencies.sort
        {
          count: count,
          success: success,
          failed: count - success,
          duration_s: total_time.round(3),
          throughput_rps: (count / total_time).round(1),
          min_ms: sorted.first.round(2),
          p50_ms: sorted[(sorted.size * 0.50).to_i].round(2),
          p95_ms: sorted[(sorted.size * 0.95).to_i].round(2),
          p99_ms: sorted[(sorted.size * 0.99).to_i].round(2),
          max_ms: sorted.last.round(2)
        }
      rescue Errno::EPERM, Errno::EACCES => e
        {
          count: count,
          inconclusive: true,
          reason: "Socket binding restricted (#{e.class}: #{e.message})"
        }
      end

      def bench_timeout_cancel
        port, stop_proc = start_server(delay: 2.0)
        timed_out = false

        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Rubik::Concurrency.silently do
          uri = URI("http://127.0.0.1:#{port}/")
          http = Net::HTTP.new(uri.host, uri.port)
          http.read_timeout = 0.1
          http.open_timeout = 0.1
          begin
            http.get("/")
          rescue Timeout::Error
            timed_out = true
          end
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
        stop_proc.call

        {
          timed_out_cleanly: timed_out,
          elapsed_s: elapsed.round(3),
          expected_delay_s: 2.0,
          passed: timed_out && elapsed < 1.5
        }
      rescue Errno::EPERM, Errno::EACCES => e
        { inconclusive: true, reason: "Socket binding restricted (#{e.class}: #{e.message})" }
      end

      def bench_scheduler_comparison
        # 40 requests with 15ms simulated latency:
        # Sequential floor: 40 * 15ms = 600ms
        # Scheduler: concurrent execution on event loop
        port, stop_proc = start_server(delay: 0.015)
        count = 40

        # Scheduler ON
        ENV["RUBIK_FIBER_SCHEDULER"] = nil
        Rubik::Concurrency.reset_disabled_cache!
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        res_on = Rubik::Concurrency.map(count.times.to_a) do
          Net::HTTP.get(URI("http://127.0.0.1:#{port}/"))
        end
        dt_on = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

        # Scheduler OFF
        ENV["RUBIK_FIBER_SCHEDULER"] = "off"
        Rubik::Concurrency.reset_disabled_cache!
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        res_off = Rubik::Concurrency.map(count.times.to_a) do
          Net::HTTP.get(URI("http://127.0.0.1:#{port}/"))
        end
        dt_off = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

        ENV["RUBIK_FIBER_SCHEDULER"] = nil
        Rubik::Concurrency.reset_disabled_cache!
        stop_proc.call

        speedup = (dt_off / dt_on).round(2)
        {
          requests: count,
          scheduler_on_s: dt_on.round(3),
          scheduler_off_s: dt_off.round(3),
          speedup_ratio: speedup,
          passed: speedup >= 1.5 && res_on.all? { |r| r == "ok" } && res_off.all? { |r| r == "ok" }
        }
      rescue Errno::EPERM, Errno::EACCES => e
        { inconclusive: true, reason: "Socket binding restricted (#{e.class}: #{e.message})" }
      end

      def start_server(delay: 0.0)
        server = TCPServer.new("127.0.0.1", 0)
        port = server.addr[1]
        running = true

        workers = 8.times.map do
          Thread.new do
            while running
              begin
                sock = server.accept
                _req = sock.gets
                sleep(delay) if delay.positive?
                sock.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
                sock.close
              rescue StandardError
                break unless running
              end
            end
          end
        end

        stop_proc = lambda do
          running = false
          begin
            server.close
          rescue StandardError
            nil
          end
          workers.each do |w|
            w.kill
            begin
              w.join(0.1)
            rescue StandardError
              nil
            end
          end
        end

        [port, stop_proc]
      end
    end
  end
end
