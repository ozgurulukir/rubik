# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/llm/ollama"
require "rubik/llm/client"

# Plan 61 D-1: without num_ctx the Ollama server silently clips the prompt
# head to its own default window — the model never sees earlier turns.
# The provider must forward the resolved context window on every request.
class TestOllamaNumCtx < Minitest::Test
  def setup
    @provider = Rubik::LLM::OllamaProvider.new(model: "qwen2.5-coder:7b")
  end

  def test_context_limit_opt_is_sent_as_num_ctx
    payload = capture(:complete, { context_limit: 16_384 })
    assert_equal 16_384, payload.dig(:options, :num_ctx)
  end

  def test_no_opts_sends_no_options_block
    payload = capture(:complete, {})
    refute payload.key?(:options), "options block must stay absent when no window is configured"
  end

  def test_provider_level_num_ctx_wins_over_context_limit_opt
    provider = Rubik::LLM::OllamaProvider.new(model: "m", num_ctx: 8192)
    payload = capture(:complete, { context_limit: 16_384 }, provider)
    assert_equal 8192, payload.dig(:options, :num_ctx)
  end

  def test_explicit_num_ctx_opt_has_top_precedence
    provider = Rubik::LLM::OllamaProvider.new(model: "m", num_ctx: 8192)
    payload = capture(:complete, { num_ctx: 4096, context_limit: 16_384 }, provider)
    assert_equal 4096, payload.dig(:options, :num_ctx)
  end

  def test_streaming_request_also_carries_num_ctx
    payload = capture(:stream_chat, { context_limit: 12_000 })
    assert_equal 12_000, payload.dig(:options, :num_ctx)
    assert_equal true, payload[:stream]
  end

  def test_non_positive_num_ctx_is_omitted
    provider = Rubik::LLM::OllamaProvider.new(model: "m", num_ctx: 0)
    payload = capture(:complete, {}, provider)
    refute payload.key?(:options)
  end

  # Plan 61 D-5: routed turns rebuild providers via Registry#get_for — the
  # registered providers.<name>.num_ctx override must survive that rebuild.
  def test_registry_get_for_preserves_provider_num_ctx
    temp_dir = Dir.mktmpdir("rubik_num_ctx_cfg")
    temp_home = Dir.mktmpdir("rubik_num_ctx_home")
    begin
      config = Rubik::Config.new(root_dir: temp_dir, home_dir: temp_home)
      config.set("providers.ollama", { "type" => "ollama", "endpoint" => "http://localhost:11434", "num_ctx" => 8192 })
      registry = Rubik::LLM::Registry.new(config)

      routed = registry.get_for({ "provider" => "ollama", "name" => "qwen2.5-coder:7b" })
      assert_kind_of Rubik::LLM::OllamaProvider, routed
      assert_equal 8192, routed.num_ctx, "get_for must carry the registered provider's num_ctx"
    ensure
      FileUtils.remove_entry(temp_dir) if temp_dir && File.exist?(temp_dir)
      FileUtils.remove_entry(temp_home) if temp_home && File.exist?(temp_home)
    end
  end

  private

  def capture(method, opts, provider = @provider)
    payloads = []
    stub_lambda = lambda do |_url, **kw, &block|
      payloads << kw[:payload]
      block&.call({ type: :message, data: "{}" })
      {}
    end

    Rubik::LLM::HTTPClient.stub(:post_json, stub_lambda) do
      Rubik::LLM::HTTPClient.stub(:post_stream_json, stub_lambda) do
        # stream_chat requires a block, otherwise it returns an Enumerator
        # without ever touching the transport.
        provider.public_send(method, [{ role: "user", content: "merhaba" }], opts) { |_chunk| nil }
      end
    end
    payloads.first
  end
end
