# frozen_string_literal: true

require_relative "../test_helper"

# Regression: HTTP error bodies without a charset arrive from Net::HTTP
# tagged ASCII-8BIT. Embedding them raw into ClientError messages poisoned
# every UTF-8 consumer downstream — in the REPL the error printer itself
# raised inside the rescue clause, so the user saw a bare
# "Encoding::CompatibilityError: incompatible character encodings: UTF-8 and
# BINARY (ASCII-8BIT)" instead of the real HTTP error (InternLM batch mode).
class TestLLMErrorMessageEncoding < Minitest::Test
  FakeResponse = Struct.new(:code, :body)

  def post_with(body, status: "400")
    http = Object.new
    http.define_singleton_method(:request) { |_req| FakeResponse.new(status, body) }
    Rubik::LLM::HTTPClient.post_json(
      "http://127.0.0.1:1/v1/chat", # never dialed: factory replaces transport
      payload: { model: "x" }, backoff_base: 0, http_factory: ->(_uri) { http }
    )
  end

  def stream_error_client(status, chunks)
    response = Object.new
    response.define_singleton_method(:code) { status }
    response.define_singleton_method(:read_body) { |&blk| chunks.each(&blk) }
    http = Object.new
    http.define_singleton_method(:request) { |_req, &blk| blk.call(response) }
    http
  end

  def test_http_error_message_is_valid_utf8_when_body_has_no_charset
    body = JSON.generate("error" => "Geçersiz istek 🎉").b
    assert_equal Encoding::ASCII_8BIT, body.encoding

    err = assert_raises(Rubik::LLM::ClientError) { post_with(body) }

    assert_equal Encoding::UTF_8, err.message.encoding
    assert_predicate err.message, :valid_encoding?
    assert_match(/HTTP Request failed with code 400/, err.message)
    assert_includes err.message, "Geçersiz istek 🎉"
  end

  def test_http_error_message_scrubs_invalid_byte_sequences
    err = assert_raises(Rubik::LLM::ClientError) { post_with("hata:\xFF\xC3".b) }

    assert_equal Encoding::UTF_8, err.message.encoding
    assert_predicate err.message, :valid_encoding?
  end

  def test_success_path_unaffected_by_body_encoding
    res = post_with(JSON.generate("ok" => true).b, status: "200")
    assert_equal({ "ok" => true }, res)
  end

  def test_stream_error_message_is_valid_utf8_when_body_has_no_charset
    body = "geçersiz istek 🎉".b
    http = stream_error_client("400", [body])

    err = assert_raises(Rubik::LLM::ClientError) do
      Rubik::LLM::HTTPClient.post_stream_json(
        "http://127.0.0.1:1/v1/chat",
        payload: { model: "x" }, http_factory: ->(_uri) { http }
      ) { |_event| flunk("no events expected on an HTTP error") }
    end

    assert_equal Encoding::UTF_8, err.message.encoding
    assert_predicate err.message, :valid_encoding?
    assert_match(/HTTP Request failed with code 400/, err.message)
    assert_includes err.message, "geçersiz istek 🎉"
  end

  # Issue #634: provider bodies are embedded in exception messages; secrets
  # must be masked and long bodies bounded unless RUBIK_DEBUG is set.
  def test_error_body_redacts_secrets_by_default
    secret = "sk-#{'a' * 30}"
    body = JSON.generate("error" => "bad api_key=#{secret}")

    err = assert_raises(Rubik::LLM::ClientError) { post_with(body) }

    refute_includes err.message, secret
    assert_includes err.message, Rubik::Security::Redactor::MASK_STRING
  end

  def test_error_body_is_bounded_and_drops_distant_prompt_fragment
    prompt_fragment = "DISTINCTIVE_PROMPT_FRAGMENT_9f3a"
    body = "#{'filler ' * 200}#{prompt_fragment}"

    err = assert_raises(Rubik::LLM::ClientError) { post_with(body) }

    assert_operator err.message.length, :<, body.length
    refute_includes err.message, prompt_fragment
    assert_includes err.message, "truncated"
  end

  def test_error_body_full_content_only_with_debug_toggle
    secret = "secret-value-#{'z' * 40}"
    body = JSON.generate("error" => secret)
    old = ENV.fetch("RUBIK_DEBUG", nil)
    ENV["RUBIK_DEBUG"] = "1"

    err = assert_raises(Rubik::LLM::ClientError) { post_with(body) }

    assert_includes err.message, secret
  ensure
    ENV["RUBIK_DEBUG"] = old
  end
end
