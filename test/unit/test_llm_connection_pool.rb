# frozen_string_literal: true

require_relative "../test_helper"
require "socket"
require_relative "../../lib/rubik/llm/client"

# Regression tests for the persistent connection pool in
# Rubik::LLM::HTTPClient (keep-alive reuse, interrupt hygiene, re-entrancy,
# and the streaming retry policy).
class TestLLMConnectionPool < Minitest::Test
  SSE_BODY = "data: {\"delta\":\"one\"}\n\ndata: {\"delta\":\"two\"}\n\n"
  JSON_BODY = "{\"ok\":true}"

  # Minimal stand-in for a streaming Net::HTTP response.
  class FakeStreamResponse
    def code = "200"

    def message = "OK"

    def read_body(&blk)
      return SSE_BODY unless blk

      SSE_BODY.each_line { |line| blk.call(line) }
      SSE_BODY
    end
  end

  # Keep-alive TCP server: serves any number of requests over any number of
  # connections. Responds with SSE when the request Accepts event-stream,
  # plain JSON otherwise. Records each accepted TCP connection.
  class KeepAliveServer
    attr_reader :accepts

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @accepts = 0
      @thread = Thread.new { run }
    end

    def port = @server.addr[1]

    def shutdown
      @thread.kill
      @thread.join(0.5)
      @server.close
    rescue StandardError
      nil
    end

    private

    def run
      loop do
        client = @server.accept
        @accepts += 1
        # One thread per connection so a second concurrent client (nested
        # call fallback) is served while the first connection stays open.
        Thread.new(client) { |c| serve_client(c) }
      end
    rescue StandardError
      nil
    end

    def serve_client(client)
      loop do
        head = +""
        loop do
          line = client.gets
          return if line.nil?

          head << line
          break if ["\r\n", "\n"].include?(line)
        end
        len = head[/Content-Length:\s*(\d+)/i, 1].to_i
        client.read(len) if len.positive?

        sse = head.match?(%r{Accept:\s*text/event-stream}i)
        body = sse ? SSE_BODY : JSON_BODY
        ctype = sse ? "text/event-stream" : "application/json"
        client.write("HTTP/1.1 200 OK\r\nContent-Type: #{ctype}\r\n" \
                     "Content-Length: #{body.bytesize}\r\nConnection: keep-alive\r\n\r\n#{body}")
      end
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      nil
    ensure
      client.close
    end
  end

  def setup
    # Socket capability is a precondition, not an assumption (issue #148):
    # in sandboxes that forbid loopback sockets the server cannot start, so
    # @server stays nil and only the socket-requiring tests skip — the
    # fake-transport tests below keep running. Teardown is nil-safe so a
    # failed setup never produces a secondary nil.shutdown error.
    @socket_error = localhost_socket_error
    @server = @socket_error ? nil : KeepAliveServer.new
  end

  def teardown
    @server&.shutdown
    Rubik::LLM::HTTPClient.instance_variable_get(:@pool).clear
  end

  # Explicit precondition for tests that need the loopback server: skip with
  # the real socket error (a sandbox restriction, not a product failure).
  def require_loopback_server!
    return if @server

    skip("localhost sockets unavailable (#{@socket_error.class}: #{@socket_error.message}) — sandbox restriction, not a product failure")
  end

  # The factory-injected tests never dial, so a placeholder port keeps them
  # runnable when the loopback server could not start (socket-restricted
  # sandbox, issue #148).
  def url = "http://127.0.0.1:#{@server ? @server.port : 9}/v1/chat"

  def pooled_sessions_for_port
    pool = Rubik::LLM::HTTPClient.instance_variable_get(:@pool)
    pool.keys.select { |(_host, port, _ssl)| port == @server.port }
  end

  def test_second_stream_reuses_the_pooled_session
    require_loopback_server!
    2.times do
      events = []
      Rubik::LLM::HTTPClient.post_stream_json(url, payload: {}) { |e| events << e }
      assert_equal 2, events.size
    end

    assert_equal 1, @server.accepts, "second request must reuse the pooled TCP session"
    assert_equal 1, pooled_sessions_for_port.size
  end

  def test_interrupt_midstream_drops_the_pooled_session
    require_loopback_server!
    raised = false
    begin
      Rubik::LLM::HTTPClient.post_stream_json(url, payload: {}) do |_event|
        raise Interrupt
      end
    rescue Interrupt
      raised = true
    end

    assert raised, "Interrupt must propagate to the caller"
    assert_empty pooled_sessions_for_port, "a half-read session must never be handed back to the pool"

    # Poisoned-socket follow-up: the next request must succeed on a fresh
    # connection instead of choking on leftover SSE bytes ("wrong status line").
    events = []
    Rubik::LLM::HTTPClient.post_stream_json(url, payload: {}) { |e| events << e }
    assert_equal 2, events.size
    assert_equal 2, @server.accepts
  end

  def test_nested_same_host_call_does_not_deadlock
    require_loopback_server!
    inner_result = nil
    events = []
    Rubik::LLM::HTTPClient.post_stream_json(url, payload: {}) do |event|
      events << event
      # Same-host nested call from inside the streaming callback: the pooled
      # mutex is already owned by this thread — must fall back to a private
      # connection instead of raising ThreadError (deadlock).
      inner_result ||= Rubik::LLM::HTTPClient.post_json(url, payload: {}) if events.size == 1
    end

    assert_equal 2, events.size
    assert_equal({ "ok" => true }, inner_result)
    assert_equal 2, @server.accepts, "nested call dials its own connection"
  end

  def test_read_timeout_is_never_retried_even_before_headers
    calls = 0
    factory = lambda do |_uri|
      http = Object.new
      http.define_singleton_method(:request) do |*_args|
        calls += 1
        raise Net::ReadTimeout
      end
      http
    end

    err = assert_raises(Rubik::LLM::ClientError) do
      Rubik::LLM::HTTPClient.post_stream_json(url, payload: {}, http_factory: factory) { |_e| }
    end

    assert_match(/Network error during stream/, err.message)
    assert_equal 1, calls, "read timeout must not be re-sent (server may already be generating)"
  end

  def test_transport_error_before_headers_retries_once
    calls = 0
    factory = lambda do |_uri|
      http = Object.new
      http.define_singleton_method(:request) do |_req, &blk|
        calls += 1
        raise Errno::ECONNRESET if calls == 1

        blk.call(FakeStreamResponse.new)
      end
      http
    end

    events = []
    res = Rubik::LLM::HTTPClient.post_stream_json(url, payload: {}, http_factory: factory) { |e| events << e }

    assert_equal :ok, res
    assert_equal 2, calls
    assert_equal 2, events.size
  end

  def test_unexpected_transport_error_is_wrapped_as_client_error
    factory = lambda do |_uri|
      http = Object.new
      http.define_singleton_method(:request) { |_req| raise OpenSSL::SSL::SSLError, "handshake failed" }
      http
    end

    err = assert_raises(Rubik::LLM::ClientError) do
      Rubik::LLM::HTTPClient.post_stream_json(url, payload: {}, http_factory: factory) { |_e| }
    end

    assert_match(/Network error during stream/, err.message)
  end

  # ── socket-precondition classification (issue #148) ──────────────────

  def test_teardown_is_nil_safe_after_a_failed_setup
    # Locked-down sandbox simulation: setup never got its server; the REAL
    # teardown must stay silent instead of raising a secondary nil.shutdown
    # error that masks the original setup failure.
    saved_server = @server
    saved_error = @socket_error
    @server = nil
    begin
      teardown # idempotent — minitest calls it again after the test
      assert_nil @server
    ensure
      @server = saved_server
      @socket_error = saved_error
    end
  end

  def test_socket_precondition_skips_with_an_explicit_reason
    saved_server = @server
    saved_error = @socket_error
    @server = nil
    @socket_error = Errno::EACCES.new("socket creation blocked")
    begin
      skip_error = assert_raises(Minitest::Skip) { require_loopback_server! }
      assert_includes skip_error.message, "localhost sockets unavailable"
      assert_includes skip_error.message, "sandbox restriction, not a product failure"
    ensure
      @server = saved_server
      @socket_error = saved_error
    end
  end
end
