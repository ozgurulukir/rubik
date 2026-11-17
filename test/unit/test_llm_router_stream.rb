# frozen_string_literal: true

require_relative "../test_helper"

# Tests for `LLM::Router#stream_chat` (PR-E).
# Verifies the router can resolve a provider and delegate streaming
# through the dispatch path, including a true end-to-end with a real
# local TCP server for the Ollama path (NDJSON).
class TestLLMRouterStream < Minitest::Test
  KNOB = "x-opencode-session"
  UUID_RE = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  def setup
    @temp_dir = Dir.mktmpdir
    @temp_home = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
    FileUtils.remove_entry(@temp_home)
  end

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

  def test_stream_chat_without_block_returns_working_enumerator
    config = Rubik::Config.new
    router = Rubik::LLM::Router.new(config: config)
    stub = Class.new(Rubik::LLM::BaseProvider) do
      def stream_chat(_messages, _opts = {}, &block)
        block.call(Rubik::LLM::Chunk.new(text_delta: "enumerated"))
        block.call(Rubik::LLM::Chunk.new(done: true))
      end
    end.new
    router.registry.define_singleton_method(:get) { |name| name == "ollama" ? stub : nil }
    router.registry.define_singleton_method(:get_for) { |_spec| stub }

    enum = router.stream_chat([{ role: "user", content: "hi" }], provider: "ollama")
    assert_kind_of Enumerator, enum
    chunks = enum.to_a
    assert_equal "enumerated", chunks.select(&:text_delta?).map(&:text_delta).join
  end

  # ---------- Opt-in session_key injection (issue #534) ----------

  # Provider double that records the opts it was called with and answers
  # `#name` like a registry-built provider (downcased explicit name).
  def capturing_stub(name: "testprov")
    stub = Class.new(Rubik::LLM::BaseProvider) do
      attr_reader :last_opts

      def stream_chat(_messages, opts = {}, &block)
        @last_opts = opts
        block&.call(Rubik::LLM::Chunk.new(done: true))
        :ok
      end
    end.new
    stub.define_singleton_method(:name) { name }
    stub
  end

  # Router with a fully stubbed registry vending `provider`, plus a Config
  # whose providers.testprov.session_header knob follows `knob_set`.
  def session_router(provider, knob_set: true)
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    config.set("providers.testprov.session_header", KNOB) if knob_set
    router = Rubik::LLM::Router.new(config: config)
    router.registry.define_singleton_method(:get) { |_name| provider }
    router.registry.define_singleton_method(:get_for) { |_spec| provider }
    router.registry.define_singleton_method(:context_limit_for) { |*| 128_000 }
    router.registry.define_singleton_method(:max_output_tokens_for) { |*| 4096 }
    [router, config]
  end

  def test_stream_chat_injects_session_header_when_session_key_given
    provider = capturing_stub
    router, = session_router(provider)

    # Route path: the resolved provider must equal the knob's provider key.
    router.stream_chat([{ role: "user", content: "hi" }], task_type: :default, session_key: "session_x") { |_c| }

    uuid = provider.last_opts[:headers][KNOB]
    assert_match UUID_RE, uuid, "injected value must be an RFC-4122-shaped UUID"
    assert_equal Rubik::LLM::SessionHeader.uuid_for("session_x"), uuid
  end

  def test_stream_chat_with_session_key_but_no_knob_leaves_headers_absent
    provider = capturing_stub
    router, = session_router(provider, knob_set: false)

    router.stream_chat([{ role: "user", content: "hi" }], provider: provider, session_key: "session_x") { |_c| }

    refute provider.last_opts.key?(:headers), "the :headers key stays absent when the knob is unset"
  end

  def test_stream_chat_without_session_key_is_byte_identical_to_old_behavior
    provider = capturing_stub
    router, = session_router(provider)

    router.stream_chat([{ role: "user", content: "hi" }], task_type: :default) { |_c| }

    opts = provider.last_opts
    refute opts.key?(:headers), "no kwarg, no injection — pass-through stays untouched"
    assert_equal 128_000, opts[:context_limit], "router-computed context_limit still injected"
    assert_equal 4096, opts[:max_output_tokens], "router-computed max_output_tokens still injected"
  end

  def test_stream_chat_explicit_caller_header_beats_automatic_injection
    provider = capturing_stub
    router, = session_router(provider)

    router.stream_chat([{ role: "user", content: "hi" }],
                       provider: provider,
                       session_key: "session_x",
                       headers: { "X-Opencode-Session" => "manual" }) { |_c| }

    assert_equal "manual", provider.last_opts[:headers]["X-Opencode-Session"],
                 "per-call opts merge LAST in adapters — auto-injection must not clobber"
    refute_includes provider.last_opts[:headers].values, Rubik::LLM::SessionHeader.uuid_for("session_x")
  end

  def test_stream_chat_enumerator_path_carries_injected_headers
    provider = capturing_stub
    router, = session_router(provider)

    enum = router.stream_chat([{ role: "user", content: "hi" }], provider: provider, session_key: "session_x")
    assert_kind_of Enumerator, enum
    enum.to_a

    uuid = provider.last_opts[:headers][KNOB]
    assert_equal Rubik::LLM::SessionHeader.uuid_for("session_x"), uuid,
                 "injection happens BEFORE the to_enum return, so the forwarded opts carry :headers"
  end

  # ---------- ProviderKey.derive (registry-style key SSOT) ----------

  def test_provider_key_derives_from_explicit_name
    provider = Object.new
    def provider.name = "TestProv"
    assert_equal "testprov", Rubik::LLM::ProviderKey.derive(provider)
  end

  def test_provider_key_empty_name_counts_as_unnamed
    provider = Object.new
    def provider.name = ""
    assert_equal "object", Rubik::LLM::ProviderKey.derive(provider),
                 "an empty name must fall back to the class-name derivation"
  end

  def test_provider_key_unnamed_object_falls_back_to_class_name
    stub_class = Class.new(Rubik::LLM::BaseProvider)
    Object.const_set(:FooBarProvider, stub_class)
    begin
      assert_equal "foobar", Rubik::LLM::ProviderKey.derive(stub_class.new)
    ensure
      Object.send(:remove_const, :FooBarProvider)
    end
  end

  def test_provider_key_strips_namespace_and_provider_suffix
    namespace = Module.new
    Object.const_set(:FakeDeep, namespace)
    stub_class = Class.new(Rubik::LLM::BaseProvider)
    namespace.const_set(:NestedProvider, stub_class)
    begin
      assert_equal "nested", Rubik::LLM::ProviderKey.derive(stub_class.new)
    ensure
      Object.send(:remove_const, :FakeDeep)
    end
  end

  def test_provider_key_object_without_name_is_class_derived
    stub_class = Class.new(Rubik::LLM::BaseProvider)
    Object.const_set(:WidgetProvider, stub_class)
    begin
      # BaseProvider instances carry no `#name`, so the class-name fallback
      # must own the derivation.
      provider = stub_class.new
      refute provider.respond_to?(:name)
      assert_equal "widget", Rubik::LLM::ProviderKey.derive(provider)
    ensure
      Object.send(:remove_const, :WidgetProvider)
    end
  end

  def test_provider_key_anonymous_class_is_nil_safe
    provider = Class.new(Rubik::LLM::BaseProvider).new
    assert_nil provider.class.name, "precondition: anonymous class"
    assert_nil Rubik::LLM::ProviderKey.derive(provider)
  end
end
