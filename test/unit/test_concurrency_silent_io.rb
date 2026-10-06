# frozen_string_literal: true

require_relative "../test_helper"
require "socket"
require "net/http"
require "json"
require "open3"
require_relative "../../lib/rubik/concurrency"
require_relative "../../lib/rubik/llm/client"

# The "silent" proof: unchanged, plain blocking I/O — the exact production
# call sites Rubik already ships (Net::HTTP via LLM::HTTPClient with its
# connection pool and Mutexes, Open3 child pipes) — interleaves when run
# inside the concurrency boundary. Nothing at the call sites is modified.
class TestConcurrencySilentIo < Minitest::Test
  # Local HTTP fixture: 50 ms-delayed JSON responses, one thread per
  # connection, port 0 (parallel-safe). Modeled on the KeepAliveServer in
  # test_llm_connection_pool.rb.
  class SlowJsonServer
    attr_reader :port

    def initialize(delay: 0.05)
      @delay = delay
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = ::Thread.new { accept_loop }
    end

    def shutdown
      @thread.kill
      @thread.join(0.5)
      @server.close
    rescue StandardError
      nil
    end

    private

    def accept_loop
      loop do
        client = @server.accept
        ::Thread.new(client) { |c| serve(c) }
      rescue StandardError
        nil
      end
    end

    def serve(client)
      request = +""
      until request.include?("\r\n\r\n")
        byte = client.read(1)
        break unless byte

        request << byte
      end
      # Drain the request BODY before responding: closing a socket with
      # unread inbound data makes Windows send RST, which surfaces as
      # ECONNRESET on the client instead of the response.
      if (match = request.match(/Content-Length:\s*(\d+)/i))
        remaining = match[1].to_i
        while remaining.positive? && (chunk = client.read([remaining, 4096].min))
          remaining -= chunk.bytesize
        end
      end
      sleep @delay
      body = JSON.dump(ok: true)
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      client.close
    rescue StandardError
      nil
    end
  end

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def teardown
    assert_nil ::Fiber.scheduler, "scheduler must be uninstalled after every boundary"
    # The LLM client's connection pool is process-global; drop the sockets
    # this test opened so later suites start clean (same discipline as
    # test_llm_connection_pool.rb).
    pool = Rubik::LLM::HTTPClient.instance_variable_get(:@pool)
    pool&.clear
    locks = Rubik::LLM::HTTPClient.instance_variable_get(:@pool_locks)
    locks&.clear
  end

  def test_concurrent_net_http_gets_interleave_without_call_site_changes
    server = SlowJsonServer.new(delay: 0.05)
    url = "http://127.0.0.1:#{server.port}/probe"

    nil
    t0 = clock
    ok = 0
    Rubik::Concurrency.silently do
      50.times do
        # Plain, untouched blocking Net::HTTP — the point of the test.
        ::Fiber.schedule do
          response = Net::HTTP.get_response(URI(url))
          ok += 1 if response.code.to_i == 200 && JSON.parse(response.body)["ok"]
        end
      end
    end
    wall = clock - t0
    serial_floor = 50 * 0.05

    assert_equal 50, ok, "every request must succeed with a correct body"
    assert_operator wall, :<, serial_floor / 2, "50 delayed GETs (serial floor #{serial_floor.round(2)}s) must interleave, took #{wall.round(2)}s"
  ensure
    server&.shutdown
  end

  def test_llm_client_pooled_requests_run_under_the_boundary
    servers = 3.times.map { SlowJsonServer.new(delay: 0.05) }

    results = Rubik::Concurrency.map(servers) do |server|
      # The real production entry point (connection pool, per-key Mutex,
      # retry policy) — called unchanged inside the boundary. Two requests
      # per endpoint also exercise keep-alive reuse of the pooled socket.
      first = Rubik::LLM::HTTPClient.post_json("http://127.0.0.1:#{server.port}/a", payload: { n: 1 }, timeout: 5)
      second = Rubik::LLM::HTTPClient.post_json("http://127.0.0.1:#{server.port}/b", payload: { n: 2 }, timeout: 5)
      [first["ok"], second["ok"]]
    end

    assert_equal [[true, true]] * 3, results
  ensure
    servers&.each(&:shutdown)
  end

  def test_open3_capture3_fan_out_returns_identical_outputs
    outputs = Rubik::Concurrency.map(8.times.to_a) do |i|
      out, _err, status = Open3.capture3(RbConfig.ruby, "-e", "puts 'line-#{i}'")
      status.success? ? out.strip : :failed
    end

    assert_equal 8.times.map { |i| "line-#{i}" }, outputs
  end
end
