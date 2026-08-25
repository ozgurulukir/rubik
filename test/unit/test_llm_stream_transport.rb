# frozen_string_literal: true

require_relative "../test_helper"
require "socket"
require_relative "../../lib/rubik/llm/client"

# Tests for the streaming transport introduced in PR-B:
#   - `Rubik::LLM::SSEParser` — buffers raw bytes, emits complete events
#   - `Rubik::LLM::HTTPClient.post_stream_json` — streams SSE events
#     from a real local TCP server to the caller via a block.
class TestLLMStreamTransport < Minitest::Test
  # ---------- SSEParser ----------

  def test_sse_parser_single_event_with_data
    parser = Rubik::LLM::SSEParser.new
    events = parser.feed("data: hello\n\n")
    assert_equal 1, events.size
    assert_equal "message", events[0][:type]
    assert_equal "hello", events[0][:data]
  end

  def test_sse_parser_event_with_explicit_type
    parser = Rubik::LLM::SSEParser.new
    events = parser.feed("event: ping\ndata: {}\n\n")
    assert_equal 1, events.size
    assert_equal "ping", events[0][:type]
    assert_equal "{}", events[0][:data]
  end

  def test_sse_parser_multi_line_data
    parser = Rubik::LLM::SSEParser.new
    events = parser.feed("data: line1\ndata: line2\ndata: line3\n\n")
    assert_equal 1, events.size
    assert_equal "line1\nline2\nline3", events[0][:data]
  end

  def test_sse_parser_multiple_events_in_one_feed
    parser = Rubik::LLM::SSEParser.new
    events = parser.feed("data: a\n\ndata: b\n\ndata: c\n\n")
    assert_equal 3, events.size
    assert_equal %w[a b c], events.map { |e| e[:data] }
  end

  def test_sse_parser_buffers_partial_event
    parser = Rubik::LLM::SSEParser.new
    events = parser.feed("data: hel")
    assert_empty events  # nothing yet — partial

    events = parser.feed("lo\n\n")
    assert_equal 1, events.size
    assert_equal "hello", events[0][:data]
  end

  def test_sse_parser_buffers_event_split_across_feeds
    parser = Rubik::LLM::SSEParser.new
    events = parser.feed("event: message\nda")
    assert_empty events

    events = parser.feed("ta: {\"x\":1}\n\n")
    assert_equal 1, events.size
    assert_equal "message", events[0][:type]
    assert_equal "{\"x\":1}", events[0][:data]
  end

  def test_sse_parser_flush_returns_trailing_event_without_blank_line
    parser = Rubik::LLM::SSEParser.new
    events = parser.feed("data: no_blank_line")
    assert_empty events  # not yet complete

    events = parser.flush
    assert_equal 1, events.size
    assert_equal "no_blank_line", events[0][:data]
  end

  def test_sse_parser_handles_blank_data_field
    parser = Rubik::LLM::SSEParser.new
    events = parser.feed("data:\n\n")
    assert_equal 1, events.size
    assert_equal "", events[0][:data]
  end

  def test_sse_parser_ignores_comment_lines
    parser = Rubik::LLM::SSEParser.new
    events = parser.feed(": this is a comment\ndata: real\n\n")
    assert_equal 1, events.size
    assert_equal "real", events[0][:data]
  end

  # ---------- HTTPClient.post_stream_json (real local TCP server) ----------

  # Spin up a tiny TCP server in a background thread that returns
  # a canned SSE response ONCE. The server handles exactly one client,
  # writes the response, and exits. Tests that need multiple calls
  # (e.g. the headers/body test) reuse the same server with a `count:`.
  def start_sse_server(response_body, status: "200 OK", headers: {}, count: 1)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    received_request = []
    thread = Thread.new do
      Thread.current.report_on_exception = false
      handled = 0
      while handled < count
        client = server.accept
        handled += 1
        begin
          # Read request — read all headers (terminate on \r\n)
          while (line = client.gets)
            received_request << line
            break if line == "\r\n"
          end
          # Drain body if Content-Length is present
          content_length = received_request
            .reverse
            .find { |l| l =~ /Content-Length:\s*(\d+)/i }
          if content_length
            len = content_length.match(/Content-Length:\s*(\d+)/i)[1].to_i
            if len > 0
              body = client.read(len) rescue nil
              received_request << body if body
            end
          end
          # Write response
          client.write("HTTP/1.1 #{status}\r\n")
          client.write("Content-Type: text/event-stream\r\n")
          client.write("Connection: close\r\n")
          headers.each { |k, v| client.write("#{k}: #{v}\r\n") }
          client.write("\r\n")
          client.write(response_body)
        rescue StandardError
          # ignore
        ensure
          client&.close
        end
      end
    end
    [port, server, thread, received_request]
  end

  def teardown_sse_server(server, thread)
    thread&.kill
    thread&.join(0.5)
    server&.close
  end

  def test_post_stream_json_yields_sse_events
    body = "data: hello\n\ndata: world\n\n"
    port, server, thread, _req = start_sse_server(body)

    received = []
    Rubik::LLM::HTTPClient.post_stream_json(
      "http://127.0.0.1:#{port}/v1/stream",
      payload: { model: "stub", stream: true }
    ) { |event| received << event }

    teardown_sse_server(server, thread)

    assert_equal 2, received.size
    assert_equal "message", received[0][:type]
    assert_equal "hello", received[0][:data]
    assert_equal "world", received[1][:data]
  end

  def test_post_stream_json_yields_anthropic_style_events_with_type
    body = "event: message_start\ndata: {\"type\":\"message_start\"}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\"}\n\n"
    port, server, thread, _req = start_sse_server(body)

    received = []
    Rubik::LLM::HTTPClient.post_stream_json(
      "http://127.0.0.1:#{port}/v1/messages",
      payload: { model: "claude-stub", stream: true }
    ) { |event| received << event }

    teardown_sse_server(server, thread)

    assert_equal 2, received.size
    assert_equal "message_start", received[0][:type]
    assert_equal "content_block_delta", received[1][:type]
  end

  def test_post_stream_json_raises_client_error_on_http_error
    port, server, thread, _req = start_sse_server("{\"error\":\"bad request\"}", status: "400 Bad Request")

    err = assert_raises(Rubik::LLM::ClientError) do
      Rubik::LLM::HTTPClient.post_stream_json(
        "http://127.0.0.1:#{port}/v1/stream",
        payload: { model: "stub" }
      ) { |_event| }
    end

    teardown_sse_server(server, thread)
    assert_match(/400/, err.message)
  end

  def test_post_stream_json_raises_client_error_on_invalid_url
    assert_raises(Rubik::LLM::ClientError) do
      Rubik::LLM::HTTPClient.post_stream_json("not a url") { |_event| }
    end
  end

  def test_post_stream_json_sends_custom_headers_and_json_body
    body = "data: ok\n\n"
    port, server, thread, received_request = start_sse_server(body)

    Rubik::LLM::HTTPClient.post_stream_json(
      "http://127.0.0.1:#{port}/v1/stream",
      headers: { "x-api-key" => "secret-key-123" },
      payload: { model: "claude-stub", messages: [{ role: "user", content: "hi" }] }
    ) { |_event| }

    teardown_sse_server(server, thread)
    # Give the request lines a moment to settle in the array.
    sleep 0.05
    request_text = received_request.join
    assert_match(/x-api-key: secret-key-123/i, request_text)
    assert_match(/Content-Type: application\/json/i, request_text)
    assert_match(/Accept: text\/event-stream/i, request_text)
    assert_match(/"model":"claude-stub"/, request_text)
  end
end
