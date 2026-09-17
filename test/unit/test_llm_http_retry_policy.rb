# frozen_string_literal: true

require_relative "../test_helper"

class TestLLMHttpRetryPolicy < Minitest::Test
  # FakeResponse supports a third field for response headers; header_value
  # reads it defensively via key?/[].
  FakeResponse = Struct.new(:code, :body) do
    def initialize(code, body, headers = {})
      super(code, body)
      @headers = headers
    end

    def key?(name)
      @headers.key?(name)
    end

    def [](name)
      @headers[name]
    end

    # Streaming path drains the body (error path drains with a block).
    def read_body
      yield body if block_given?
      body
    end
  end

  # Scripted transport: outcomes are exception Classes (raised) or
  # FakeResponse instances (returned). The last outcome repeats.
  class ScriptedHttp
    attr_reader :requests

    def initialize(outcomes)
      @outcomes = outcomes.dup
      @requests = []
    end

    def attempt_count
      @requests.size
    end

    def request(req)
      @requests << req
      outcome = @outcomes.size > 1 ? @outcomes.shift : @outcomes.first
      raise outcome if outcome.is_a?(Class)

      yield outcome if block_given? # streaming block form
      outcome
    end
  end

  def post_with(http, **)
    Rubik::LLM::HTTPClient.post_json(
      "http://127.0.0.1:1/v1/chat", # never dialed: factory replaces transport
      payload: { model: "x" }, backoff_base: 0, http_factory: ->(_uri) { http }, **
    )
  end

  def test_read_timeout_is_never_retried
    http = ScriptedHttp.new([Net::ReadTimeout])
    retries = []
    err = assert_raises(Rubik::LLM::ClientError) do
      post_with(http, on_retry: ->(a, m, r) { retries << [a, m, r] })
    end
    assert_match(/read timeout after 30s/, err.message)
    assert_match(/not retried/, err.message)
    assert_equal 1, http.attempt_count
    assert_empty retries
  end

  def test_econnreset_retried_then_succeeds
    http = ScriptedHttp.new([Errno::ECONNRESET, Errno::ECONNRESET, FakeResponse.new("200", '{"ok":true}')])
    retries = []
    res = post_with(http, on_retry: ->(a, m, r) { retries << [a, m, r] })
    assert_equal({ "ok" => true }, res)
    assert_equal 3, http.attempt_count
    assert_equal [[1, 2, "Errno::ECONNRESET"], [2, 2, "Errno::ECONNRESET"]], retries
  end

  def test_gives_up_after_max_retries
    http = ScriptedHttp.new([Errno::ECONNREFUSED])
    retries = []
    err = assert_raises(Rubik::LLM::ClientError) do
      post_with(http, on_retry: ->(a, m, r) { retries << [a, m, r] })
    end
    assert_includes err.message, "ECONNREFUSED"
    assert_equal 3, http.attempt_count # 1 + 2 retries
    assert_equal 2, retries.size
  end

  def test_http_5xx_and_429_are_retried_with_status_reason
    http = ScriptedHttp.new([
                              FakeResponse.new("503", "boom"),
                              FakeResponse.new("429", "slow"),
                              FakeResponse.new("200", '{"a":1}')
                            ])
    retries = []
    res = post_with(http, on_retry: ->(a, m, r) { retries << [a, m, r] })
    assert_equal({ "a" => 1 }, res)
    assert_equal ["HTTP 503", "HTTP 429"], retries.map(&:last)
  end

  def test_http_4xx_not_retried
    http = ScriptedHttp.new([FakeResponse.new("401", "denied")])
    retries = []
    err = assert_raises(Rubik::LLM::ClientError) do
      post_with(http, on_retry: ->(a, m, r) { retries << [a, m, r] })
    end
    assert_includes err.message, "401"
    assert_equal 1, http.attempt_count
    assert_empty retries
  end

  def test_invalid_json_on_200_not_retried
    http = ScriptedHttp.new([FakeResponse.new("200", "not json")])
    err = assert_raises(Rubik::LLM::ClientError) { post_with(http) }
    assert_includes err.message, "Invalid JSON"
    assert_equal 1, http.attempt_count
  end

  def test_open_timeout_is_retryable
    http = ScriptedHttp.new([Net::OpenTimeout, FakeResponse.new("200", "{}")])
    retries = []
    post_with(http, on_retry: ->(a, m, r) { retries << [a, m, r] })
    assert_equal "Net::OpenTimeout", retries.first.last
  end

  def test_interrupt_raised_by_transport_is_never_swallowed
    http = ScriptedHttp.new([Interrupt])
    assert_raises(Interrupt) { post_with(http) }
    assert_equal 1, http.attempt_count
  end

  def test_interrupt_raised_during_retry_hook_propagates
    http = ScriptedHttp.new([Errno::ECONNRESET])
    assert_raises(Interrupt) do
      post_with(http, on_retry: ->(_a, _m, _r) { raise Interrupt })
    end
    assert_equal 1, http.attempt_count, "no further attempts after Ctrl+C"
  end

  def test_request_carries_headers_and_payload
    http = ScriptedHttp.new([FakeResponse.new("200", "{}")])
    post_with(http, headers: { "Authorization" => "Bearer tok" })
    req = http.requests.first
    assert_equal "application/json", req["Content-Type"]
    assert_equal "Bearer tok", req["Authorization"]
    assert_includes req.body, '"model":"x"'
  end

  # ---- 429 / Retry-After policy (2026-09-17 review, Finding 1) ----------

  def test_429_has_independent_budget_from_5xx
    http = ScriptedHttp.new([FakeResponse.new("429", "slow"), FakeResponse.new("503", "boom")])
    retries = []
    err = assert_raises(Rubik::LLM::ClientError) do
      post_with(http, max_retries: 1, on_retry: ->(a, m, r) { retries << [a, m, r] })
    end
    assert_includes err.message, "503"
    # 1 rate-limit retry (budget 5) + 1 generic retry (budget 1) = 3 attempts
    assert_equal 3, http.attempt_count
    assert_equal ["HTTP 429", "HTTP 503"], retries.map(&:last)
  end

  def test_429_honors_retry_after_seconds
    http = ScriptedHttp.new([
                              FakeResponse.new("429", "slow", "Retry-After" => "2"),
                              FakeResponse.new("200", "{}")
                            ])
    delays = []
    # Replace Kernel#sleep locally: capture delay instead of real waiting.
    Rubik::LLM::HTTPClient.stub(:sleep, ->(s) { delays << s }) do
      post_with(http, backoff_base: 0)
    end
    assert_equal 2, delays.first, "server hinted 2s must be honored exactly"
    assert_equal 2, http.attempt_count
  end

  def test_429_without_hint_uses_jittered_exponential_backoff
    http = ScriptedHttp.new([
                              FakeResponse.new("429", "slow"),
                              FakeResponse.new("429", "slow"),
                              FakeResponse.new("200", "{}")
                            ])
    delays = []
    Rubik::LLM::HTTPClient.stub(:sleep, ->(s) { delays << s }) do
      post_with(http, backoff_base: 1.0)
    end
    assert_equal 2, delays.size
    # base 1.0: retry 1 -> ~1s, retry 2 -> ~2s, each with ±20% jitter
    assert_operator delays[0], :>=, 0.8
    assert_operator delays[0], :<=, 1.2
    assert_operator delays[1], :>=, 1.6
    assert_operator delays[1], :<=, 2.4
  end

  def test_429_retry_after_is_capped
    http = ScriptedHttp.new([
                              FakeResponse.new("429", "slow", "Retry-After" => "3600"),
                              FakeResponse.new("200", "{}")
                            ])
    delays = []
    Rubik::LLM::HTTPClient.stub(:sleep, ->(s) { delays << s }) do
      post_with(http, backoff_base: 0)
    end
    assert_equal Rubik::LLM::HTTPClient::RATE_LIMIT_MAX_DELAY_S, delays.first
  end

  def test_429_gives_up_with_typed_rate_limit_error
    http = ScriptedHttp.new([FakeResponse.new("429", "slow")])
    retries = []
    err = assert_raises(Rubik::LLM::RateLimitError) do
      post_with(http, max_429_retries: 2, backoff_base: 0, on_retry: ->(a, m, r) { retries << [a, m, r] })
    end
    assert_equal 3, http.attempt_count # 1 + 2 rate-limit retries
    assert_equal 2, retries.size
    assert_kind_of Rubik::LLM::ClientError, err, "RateLimitError stays a ClientError for existing rescues"
    assert_includes err.message, "429"
    assert_includes err.message, "no Retry-After hint"
  end

  def test_429_error_carries_retry_after_hint
    http = ScriptedHttp.new([FakeResponse.new("429", "slow", "Retry-After" => "7")])
    err = assert_raises(Rubik::LLM::RateLimitError) do
      post_with(http, max_429_retries: 0, backoff_base: 0)
    end
    assert_equal 7, err.retry_after
  end

  def test_429_exhaustion_respects_retry_after_budget_mix
    http = ScriptedHttp.new([
                              FakeResponse.new("429", "a", "Retry-After" => "1"),
                              FakeResponse.new("429", "b"),
                              FakeResponse.new("429", "c", "Retry-After" => "2")
                            ])
    delays = []
    Rubik::LLM::HTTPClient.stub(:sleep, ->(s) { delays << s }) do
      err = assert_raises(Rubik::LLM::RateLimitError) do
        post_with(http, max_429_retries: 2, backoff_base: 1.0)
      end
      # Exhaustion message reflects the FINAL response: its hint was "2s".
      assert_includes err.message, "server hinted 2.0s"
    end
    assert_equal 1.0, delays.first, "hint honored exactly when present"
    assert_operator delays.last, :>=, 1.6, "no hint -> jittered exponential backoff (base 2s ±20%)"
    assert_operator delays.last, :<=, 2.4
  end

  def test_retry_after_http_date_parsed
    value = Rubik::LLM::HTTPClient.parse_retry_after("Wed, 21 Oct 2026 07:28:00 GMT")
    assert_kind_of Numeric, value
  end

  def test_retry_after_garbage_returns_nil
    assert_nil Rubik::LLM::HTTPClient.parse_retry_after("soon-ish")
    assert_nil Rubik::LLM::HTTPClient.parse_retry_after(nil)
  end

  def test_streaming_429_raises_typed_rate_limit_error
    http = ScriptedHttp.new([FakeResponse.new("429", "slow", "Retry-After" => "3")])
    err = assert_raises(Rubik::LLM::RateLimitError) do
      Rubik::LLM::HTTPClient.post_stream_json(
        "http://127.0.0.1:1/v1/chat",
        payload: { model: "x" }, http_factory: ->(_uri) { http }
      ) { |_event| flunk("no events expected") }
    end
    assert_equal 3, err.retry_after
  end
end
