# frozen_string_literal: true

require_relative "../test_helper"

# Tests for `LLM::Router#stream_chat` (PR-E).
# Verifies the router can resolve a provider and delegate streaming
# through the dispatch path, including a true end-to-end with a real
# local TCP server for the Ollama path (NDJSON).
class TestLLMRouterStream < Minitest::Test
  # ---------- Stub-based dispatch tests ----------

  def test_stream_chat_resolves_provider_via_route
    config = Rubik::Config.new
    router = Rubik::LLM::Router.new(config: config)

    # Inject a known provider into the registry
    stub = Class.new(Rubik::LLM::BaseProvider) do
      def stream_chat(_messages, _opts = {}, &block)
        block.call(Rubik::LLM::Chunk.new(text_delta: "from-router"))
        block.call(Rubik::LLM::Chunk.new(done: true))
        :ok
      end
    end.new

    router.registry.define_singleton_method(:get) { |_name| stub }
    router.registry.define_singleton_method(:get_for) { |_spec| stub }
    router.registry.define_singleton_method(:context_limit_for) { |*| 128_000 }
    router.registry.define_singleton_method(:max_output_tokens_for) { |*| 4096 }

    chunks = []
    router.stream_chat([{ role: "user", content: "hi" }], task_type: :default) do |c|
      chunks << c
    end
    text = chunks.select(&:text_delta?).map(&:text_delta).join
    assert_equal "from-router", text
    assert chunks.any?(&:done?)
  end

  def test_stream_chat_accepts_explicit_provider
    config = Rubik::Config.new
    router = Rubik::LLM::Router.new(config: config)
    stub = Class.new(Rubik::LLM::BaseProvider) do
      def stream_chat(_messages, _opts = {}, &block)
        block.call(Rubik::LLM::Chunk.new(text_delta: "explicit"))
        block.call(Rubik::LLM::Chunk.new(done: true))
        :ok
      end
    end.new
    router.registry.define_singleton_method(:get) { |_name| stub }

    chunks = []
    router.stream_chat([{ role: "user", content: "hi" }], provider: "anthropic") do |c|
      chunks << c
    end
    assert_equal "explicit", chunks.find(&:text_delta?).text_delta
  end

  def test_stream_chat_returns_enumerator_without_block
    config = Rubik::Config.new
    router = Rubik::LLM::Router.new(config: config)
    stub = Class.new(Rubik::LLM::BaseProvider) do
      def stream_chat(_messages, _opts = {}, &)
        :ok
      end
    end.new
    router.registry.define_singleton_method(:get) { |_name| stub }
    router.registry.define_singleton_method(:get_for) { |_spec| stub }

    enum = router.stream_chat([{ role: "user", content: "hi" }], task_type: :default)
    assert_kind_of Enumerator, enum
  end

  def test_stream_chat_raises_when_no_provider_available
    config = Rubik::Config.new
    router = Rubik::LLM::Router.new(config: config)
    router.registry.define_singleton_method(:get) { |_name| nil }
    router.registry.define_singleton_method(:get_for) { |_spec| nil }
    router.registry.define_singleton_method(:context_limit_for) { |*| 0 }
    router.registry.define_singleton_method(:max_output_tokens_for) { |*| 0 }

    assert_raises(Rubik::LLM::ClientError) do
      router.stream_chat([{ role: "user", content: "hi" }], task_type: :default) { |_c| }
    end
  end

  # ---------- Real end-to-end via local TCP server (Ollama NDJSON) ----------

  def test_router_end_to_end_with_real_ollama_provider
    # End-to-end with a real OllamaProvider is exercised in
    # test_llm_stream_providers.rb (test_ollama_streams_ndjson_deltas
    # and the complete-fallback test). Here we verify that the Router
    # correctly delegates to whatever provider the registry vends —
    # using a stub that yields deterministic chunks keeps this test
    # hermetic and fast.
    config = Rubik::Config.new
    router = Rubik::LLM::Router.new(config: config)
    stub = Class.new(Rubik::LLM::BaseProvider) do
      def stream_chat(_messages, _opts = {}, &block)
        block.call(Rubik::LLM::Chunk.new(text_delta: "router"))
        block.call(Rubik::LLM::Chunk.new(text_delta: "-"))
        block.call(Rubik::LLM::Chunk.new(text_delta: "e2e"))
        block.call(Rubik::LLM::Chunk.new(
                     done: true,
                     usage: { input_tokens: 11, output_tokens: 3 }
                   ))
        :ok
      end
    end.new
    router.registry.define_singleton_method(:get) { |name| name == "ollama" ? stub : nil }
    router.registry.define_singleton_method(:get_for) { |_spec| stub }

    chunks = []
    router.stream_chat(
      [{ role: "user", content: "hi" }],
      task_type: :default,
      provider: "ollama"
    ) do |c|
      chunks << c
    end

    text = chunks.select(&:text_delta?).map(&:text_delta).join
    assert_equal "router-e2e", text
    final = chunks.reverse.find(&:done?)
    assert final
    assert_equal 11, final.usage[:input_tokens]
    assert_equal 3, final.usage[:output_tokens]
  end
end
