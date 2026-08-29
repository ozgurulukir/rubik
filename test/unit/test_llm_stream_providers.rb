# frozen_string_literal: true

require_relative "../test_helper"
require "socket"

# Tests for provider-level #stream_chat implementations (PR-D).
# Each test stands up a tiny TCP server that emits a canned SSE/NDJSON
# response, then asserts the provider correctly parses and yields Chunks.
class TestLLMStreamProviders < Minitest::Test
  # ---------- TCP server helper (singleton, handles N connections) ----------

  def start_server(response_body, status: "200 OK", count: 1, content_type: "text/event-stream")
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    received_requests = []
    thread = Thread.new do
      Thread.current.report_on_exception = false
      handled = 0
      while handled < count
        client = server.accept
        handled += 1
        begin
          headers = []
          while (line = client.gets)
            headers << line
            break if line == "\r\n"
          end
          # Drain body if Content-Length present
          cl = headers.reverse.find { |l| l =~ /Content-Length:\s*(\d+)/i }
          if cl
            len = cl.match(/Content-Length:\s*(\d+)/i)[1].to_i
            if len > 0
              body = begin
                client.read(len)
              rescue
                nil
              end
              received_requests << (headers.join + (body || ""))
            else
              received_requests << headers.join
            end
          else
            received_requests << headers.join
          end
          client.write("HTTP/1.1 #{status}\r\n")
          client.write("Content-Type: #{content_type}\r\n")
          client.write("Connection: close\r\n\r\n")
          client.write(response_body)
        rescue StandardError
        ensure
          client&.close
        end
      end
    end
    { port: port, server: server, thread: thread, requests: received_requests }
  end

  def teardown_server(h)
    h[:thread]&.kill
    h[:thread]&.join(0.5)
    h[:server]&.close
  end

  # ---------- AnthropicProvider ----------

  def test_anthropic_streams_text_deltas_and_done
    body = <<~SSE
      event: message_start
      data: {"type":"message_start","message":{"id":"msg_1"}}

      event: content_block_start
      data: {"type":"content_block_start","index":0}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

      event: message_delta
      data: {"type":"message_delta","usage":{"input_tokens":10,"output_tokens":2}}

      event: message_stop
      data: {"type":"message_stop"}

    SSE
    srv = start_server(body)

    # Stub the env var
    ENV["ANTHROPIC_API_KEY"] = "test-key-123"

    provider = Rubik::LLM::AnthropicProvider.new
    chunks = []
    begin
      provider.stream_chat(
        [{ role: "user", content: "hi" }],
        endpoint: "http://127.0.0.1:#{srv[:port]}/v1/messages"
      ) do |c|
        chunks << c
      end
    ensure
      ENV.delete("ANTHROPIC_API_KEY")
    end
    teardown_server(srv)

    text_chunks = chunks.select(&:text_delta?)
    assert_equal 2, text_chunks.size
    assert_equal "Hello", text_chunks[0].text_delta
    assert_equal " world", text_chunks[1].text_delta
    assert chunks.any?(&:done?)
  end

  def test_anthropic_stream_raises_when_api_key_missing
    ENV.delete("ANTHROPIC_API_KEY")
    provider = Rubik::LLM::AnthropicProvider.new
    assert_raises(Rubik::LLM::ClientError) do
      provider.stream_chat([{ role: "user", content: "hi" }]) { |_c| }
    end
  end

  def test_anthropic_stream_returns_enumerator_without_block
    ENV["ANTHROPIC_API_KEY"] = "test-key"
    provider = Rubik::LLM::AnthropicProvider.new
    begin
      enum = provider.stream_chat([{ role: "user", content: "hi" }])
      assert_kind_of Enumerator, enum
    ensure
      ENV.delete("ANTHROPIC_API_KEY")
    end
  end

  # ---------- OpenAICompatibleProvider ----------

  def test_openai_compatible_streams_text_and_done_marker
    body = <<~SSE
      data: {"choices":[{"delta":{"content":"Hi"}}]}

      data: {"choices":[{"delta":{"content":" there"}}]}

      data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}

    SSE
    srv = start_server(body)

    provider = Rubik::LLM::OpenAICompatibleProvider.new(
      name: "test-openai",
      endpoint: "http://127.0.0.1:#{srv[:port]}/v1/chat/completions",
      api_key: "test-key",
      model: "gpt-test"
    )
    chunks = []
    provider.stream_chat([{ role: "user", content: "hi" }]) do |c|
      chunks << c
    end
    teardown_server(srv)

    text = chunks.select(&:text_delta?).map(&:text_delta).join
    assert_equal "Hi there", text
    final = chunks.reverse.find(&:done?)
    assert final, "expected a done chunk"
    assert_equal 5, final.usage[:input_tokens]
    assert_equal 2, final.usage[:output_tokens]
  end

  def test_openai_compatible_normalizes_endpoint
    assert_equal "http://x.com/v1/chat/completions",
                 Rubik::LLM::OpenAICompatibleProvider.normalize_endpoint("http://x.com/v1")
    assert_equal "http://x.com/v1/chat/completions",
                 Rubik::LLM::OpenAICompatibleProvider.normalize_endpoint("http://x.com/v1/chat/completions")
  end

  def test_openai_compatible_stream_handles_done_marker_only
    body = "data: [DONE]\n\n"
    srv = start_server(body)
    provider = Rubik::LLM::OpenAICompatibleProvider.new(
      name: "test", endpoint: "http://127.0.0.1:#{srv[:port]}/v1/chat/completions",
      api_key: "k", model: "m"
    )
    chunks = []
    provider.stream_chat([{ role: "user", content: "hi" }]) { |c| chunks << c }
    teardown_server(srv)
    assert chunks.any?(&:done?)
  end

  # ---------- OllamaProvider (NDJSON) ----------

  def test_ollama_streams_ndjson_deltas
    body = JSON.dump(model: "llama3", response: "Hello", done: false) + "\n" +
           JSON.dump(model: "llama3", response: " world", done: false) + "\n" +
           JSON.dump(model: "llama3", response: "", done: true, prompt_eval_count: 7, eval_count: 3) + "\n"
    srv = start_server(body, content_type: "application/x-ndjson")

    provider = Rubik::LLM::OllamaProvider.new(
      endpoint: "http://127.0.0.1:#{srv[:port]}"
    )
    chunks = []
    provider.stream_chat([{ role: "user", content: "hi" }]) do |c|
      chunks << c
    end
    teardown_server(srv)

    text = chunks.select(&:text_delta?).map(&:text_delta).join
    assert_equal "Hello world", text
    final = chunks.reverse.find(&:done?)
    assert final
    assert_equal 7, final.usage[:input_tokens]
    assert_equal 3, final.usage[:output_tokens]
  end

  def test_ollama_stream_returns_enumerator_without_block
    provider = Rubik::LLM::OllamaProvider.new(endpoint: "http://127.0.0.1:1")
    enum = provider.stream_chat([{ role: "user", content: "hi" }])
    assert_kind_of Enumerator, enum
  end

  # ---------- BaseProvider#complete fallback (uses a bare subclass) ----------

  # Concrete providers in this codebase override `#complete` for direct
  # blocking HTTP calls, so the BaseProvider fallback is exercised here
  # through a minimal subclass that does NOT override #complete. This
  # isolates the fallback's contract (collect → join → pick usage) from
  # the wire-format details of Anthropic/OpenAI/Ollama.
  def test_complete_fallback_collects_chunks_from_stream_chat
    stub = Class.new(Rubik::LLM::BaseProvider) do
      def stream_chat(_messages, _opts = {}, &block)
        block.call(Rubik::LLM::Chunk.new(text_delta: "Hi"))
        block.call(Rubik::LLM::Chunk.new(text_delta: " there"))
        block.call(Rubik::LLM::Chunk.new(
                     text_delta: "!",
                     done: true,
                     usage: { input_tokens: 4, output_tokens: 6 }
                   ))
        :ok
      end
    end.new

    response = stub.complete([{ role: "user", content: "hi" }])
    assert_kind_of Rubik::LLM::Response, response
    assert_equal "Hi there!", response.text
    assert_equal 4, response.usage[:input_tokens]
    assert_equal 6, response.usage[:output_tokens]
  end

  def test_complete_fallback_handles_empty_stream
    stub = Class.new(Rubik::LLM::BaseProvider) do
      def stream_chat(_messages, _opts = {}, &)
        :ok
      end
    end.new

    response = stub.complete([{ role: "user", content: "hi" }])
    assert_equal "", response.text
    assert_equal({}, response.usage)
  end
end
