# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/connect/probes"

class TestConnectProbes < Minitest::Test
  Probes = Rubik::Connect::Probes

  # Obviously-fake key material, assembled at runtime so no literal in this
  # file can be mistaken for a real credential.
  FAKE_KEY = "fake-test-key-#{RUBY_VERSION.tr('.', '')}".freeze

  def fetcher_with(status:, body: "", reason: nil, error: nil)
    lambda do |_uri|
      if reason
        { ok: false, error: error, status: status, reason: reason, body: body }
      else
        Struct.new(:code, :body).new(status.to_s, body)
      end
    end
  end

  def test_models_url_derivation
    assert_equal "https://api.openai.com/v1/models", Probes.models_url("https://api.openai.com")
    assert_equal "https://api.openai.com/v1/models", Probes.models_url("https://api.openai.com/v1")
    assert_equal "https://api.openai.com/v1/models", Probes.models_url("https://api.openai.com/v1/")
    assert_equal "https://gateway.example.com/paas/v1/models", Probes.models_url("https://gateway.example.com/paas/v1")
    # Gemini's documented OpenAI-compatible base lists /models directly
    assert_equal "https://generativelanguage.googleapis.com/v1beta/openai/models",
                 Probes.models_url("https://generativelanguage.googleapis.com/v1beta/openai")
    assert_equal "http://localhost:8000/v1/models", Probes.models_url("http://localhost:8000")
  end

  def test_openai_compatible_success_lists_models
    fetcher = fetcher_with(status: 200, body: { "data" => [{ "id" => "gpt-x" }, { "id" => "gpt-mini" }] }.to_json)
    res = Probes.openai_compatible("https://api.openai.com/v1", api_key: FAKE_KEY, fetcher: fetcher)

    assert res[:ok]
    refute res[:auth_failed]
    assert_equal ["gpt-x", "gpt-mini"], res[:models]
  end

  def test_openai_compatible_auth_rejected
    fetcher = fetcher_with(status: 401, body: "{}")
    res = Probes.openai_compatible("https://api.openai.com/v1", api_key: FAKE_KEY, fetcher: fetcher)

    refute res[:ok]
    assert res[:auth_failed]
    assert res[:reachable]
  end

  def test_openai_compatible_no_listing_is_ok_with_note
    fetcher = fetcher_with(status: 404, body: "")
    res = Probes.openai_compatible("http://localhost:8000", api_key: FAKE_KEY, fetcher: fetcher)

    assert res[:ok]
    assert_empty res[:models]
    assert res[:note].is_a?(String)
  end

  def test_openai_compatible_unreachable
    fetcher = fetcher_with(status: nil, reason: :unreachable, error: "Errno::ECONNREFUSED")
    res = Probes.openai_compatible("http://10.255.255.1:1", api_key: FAKE_KEY, fetcher: fetcher)

    refute res[:ok]
    refute res[:reachable]
    refute res[:auth_failed]
  end

  def test_openai_compatible_bad_json
    fetcher = fetcher_with(status: 200, body: "<html>not json</html>")
    res = Probes.openai_compatible("https://api.openai.com/v1", api_key: FAKE_KEY, fetcher: fetcher)

    refute res[:ok]
    assert res[:reachable]
  end

  def test_openai_compatible_parses_https_uri
    captured = nil
    fetcher = lambda do |uri|
      captured = uri
      { ok: true, status: 200, json: { "data" => [] } }
    end

    res = Probes.openai_compatible("https://api.openai.com/v1", api_key: FAKE_KEY, fetcher: fetcher)

    assert res[:ok]
    assert captured.is_a?(URI::HTTPS)
  end

  def test_anthropic_success_and_auth_failure
    ok_fetcher = fetcher_with(status: 200, body: { "data" => [{ "id" => "claude-x" }] }.to_json)
    res = Probes.anthropic(api_key: FAKE_KEY, fetcher: ok_fetcher)

    assert res[:ok]
    assert_equal ["claude-x"], res[:models]

    bad_fetcher = fetcher_with(status: 403, body: "{}")
    res = Probes.anthropic(api_key: FAKE_KEY, fetcher: bad_fetcher)

    refute res[:ok]
    assert res[:auth_failed]
  end

  def test_ollama_lists_installed_models
    fetcher = fetcher_with(status: 200, body: { "models" => [{ "name" => "qwen2.5-coder:7b" }, { "name" => "llama3" }] }.to_json)
    res = Probes.ollama("http://localhost:11434", fetcher: fetcher)

    assert res[:ok]
    assert_equal ["qwen2.5-coder:7b", "llama3"], res[:models]
  end

  def test_ollama_down_is_unreachable
    fetcher = fetcher_with(status: nil, reason: :unreachable, error: "connection refused")
    res = Probes.ollama("http://localhost:11434", fetcher: fetcher)

    refute res[:ok]
    refute res[:reachable]
  end

  def test_error_notes_never_contain_the_api_key
    fetcher = fetcher_with(status: 500, body: "internal error mentioning #{FAKE_KEY} inside")
    res = Probes.openai_compatible("https://api.openai.com/v1", api_key: FAKE_KEY, fetcher: fetcher)

    refute res[:note].include?(FAKE_KEY)
  end

  def test_hostless_url_rejected_as_invalid_url
    res = Probes.openai_compatible("http:///no-host", api_key: FAKE_KEY)

    refute res[:ok]
    refute res[:reachable]
    assert_includes res[:note], "only http/https URLs are supported"
  end
end
