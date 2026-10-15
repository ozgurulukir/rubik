# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/llm/client"
require_relative "../../lib/rubik/llm/anthropic"

class TestLLMRetry < Minitest::Test
  FakeResponse = Struct.new(:code, :body, :headers) do
    def initialize(code, body, headers = {})
      super
    end

    def key?(name)
      headers.key?(name)
    end

    def [](name)
      headers[name]
    end

    def read_body
      yield body if block_given?
      body
    end
  end

  class FakeHttp
    attr_accessor :read_timeout, :open_timeout
    attr_reader :requests

    def initialize(responses)
      @responses = responses.dup
      @requests = []
    end

    def request(req)
      @requests << req
      resp = @responses.size > 1 ? @responses.shift : @responses.first
      raise resp if resp.is_a?(Class) || resp.is_a?(StandardError)

      yield resp if block_given?
      resp
    end
  end

  def test_retry_after_delay_calculation
    res = FakeResponse.new(429, "rate limited", { "Retry-After" => "12" })
    delay = Rubik::LLM::HTTPClient.retry_delay_after(res, 1, 0.2)
    assert_equal 12.0, delay
  end

  def test_retry_after_delay_fallback_with_jitter
    res = FakeResponse.new(429, "rate limited", {})
    delays = 10.times.map do
      Rubik::LLM::HTTPClient.retry_delay_after(res, 1, 1.0)
    end
    # With jitter (0.8 + 0.4 * rand), delays should vary between 0.8 and 1.2
    delays.each do |d|
      assert_operator d, :>=, 0.79
      assert_operator d, :<=, 1.21
    end
    # Not all values should be identical
    assert delays.uniq.size > 1, "Delays should include jitter"
  end

  def test_wall_clock_cap_terminates_retry_early
    http = FakeHttp.new([
                          FakeResponse.new(503, "unavailable"),
                          FakeResponse.new(503, "unavailable")
                        ])

    retried = []
    err = assert_raises(Rubik::LLM::ClientError) do
      # Set max_wall_clock: 0.05 and backoff_base: 0.1 so next delay exceeds wall clock
      Rubik::LLM::HTTPClient.post_json(
        "https://api.example.com/v1/chat",
        payload: { model: "test" },
        max_retries: 5,
        backoff_base: 0.1,
        max_wall_clock: 0.05,
        http_factory: ->(_uri) { http },
        on_retry: ->(attempt, max, reason) { retried << [attempt, max, reason] }
      )
    end

    assert_includes err.message, "503"
    # Should not have completed all 5 retries due to wall clock cap
    assert_operator retried.size, :<, 5
  end

  def test_anthropic_stream_chat_passes_idle_timeout
    provider = Rubik::LLM::AnthropicProvider.new(api_key: "dummy_key")

    called_events = []
    seen = {}
    fake_http = FakeHttp.new([])
    # Pool injection (issue #148): no TCP/TLS connection is ever opened — the
    # pool seam hands the streaming path a stub transport carrying the
    # timeouts production would apply to a real session.
    pool_stub = lambda do |_uri, timeout:, open_timeout:, &blk|
      seen[:timeout] = timeout
      seen[:open_timeout] = open_timeout
      fake_http.read_timeout = timeout
      fake_http.open_timeout = open_timeout
      blk.call(fake_http)
    end

    stream_stub = lambda do |h, _u, _r, terminator: nil, state: nil, &cb|
      _ = terminator
      _ = state
      assert_equal 45, h.read_timeout
      cb.call({ type: "content_block_delta", data: JSON.generate({ delta: { type: "text_delta", text: "hello" } }) })
    end

    Rubik::LLM::HTTPClient.stub(:with_pooled_connection, pool_stub) do
      Rubik::LLM::HTTPClient.stub(:stream_attempt, stream_stub) do
        provider.stream_chat(
          [{ role: "user", content: "hi" }],
          idle_timeout: 45,
          endpoint: "https://api.anthropic.com/v1/messages"
        ) do |chunk|
          called_events << chunk
        end
      end
    end

    assert_equal 45, seen[:timeout], "idle timeout must reach the pooled transport"
    assert_equal 1, called_events.size
  end
end
