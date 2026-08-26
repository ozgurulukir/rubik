# frozen_string_literal: true

require_relative "../test_helper"

class TestLLMHttpRetryPolicy < Minitest::Test
  FakeResponse = Struct.new(:code, :body)

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

      outcome
    end
  end

  def post_with(http, **kwargs)
    Rubik::LLM::HTTPClient.post_json(
      "http://127.0.0.1:1/v1/chat", # never dialed: factory replaces transport
      payload: { model: "x" }, backoff_base: 0, http_factory: ->(_uri) { http }, **kwargs
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
end
