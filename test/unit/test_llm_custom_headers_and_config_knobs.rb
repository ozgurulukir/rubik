# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/config"
require "rubik/config/defaults"
require "rubik/llm/registry"
require "rubik/llm/openai_compatible"
require "rubik/llm/anthropic"
require "rubik/llm/ollama"
require "rubik/orchestrator/loop"

class TestLLMCustomHeadersAndConfigKnobs < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @temp_home = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
    FileUtils.remove_entry(@temp_home)
  end

  def test_default_config_knobs
    llm_cfg = Rubik::Config::Defaults::DEFAULT_CONFIG["llm"]
    assert_equal 120, llm_cfg["stream_timeout"]
    assert_equal 15, llm_cfg["open_timeout"]
    assert_equal 4096, llm_cfg["default_max_output_tokens"]
    assert_equal true, llm_cfg["capture_reasoning"]
    assert_equal({}, llm_cfg["headers"])
  end

  def test_registry_propagates_global_headers_to_stock_providers
    config_data = {
      "llm" => {
        "headers" => { "X-Global-Header" => "global_val" }
      }
    }
    File.write(File.join(@temp_dir, "rubik.yml"), YAML.dump(config_data))
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    registry = Rubik::LLM::Registry.new(cfg)

    ollama = registry.get("ollama")
    assert_equal({ "X-Global-Header" => "global_val" }, ollama.headers)

    openai = registry.get("openai")
    assert_equal({ "X-Global-Header" => "global_val" }, openai.headers)

    anthropic = registry.get("anthropic")
    assert_equal({ "X-Global-Header" => "global_val" }, anthropic.headers)
  end

  def test_registry_merges_global_and_custom_provider_headers
    config_data = {
      "llm" => {
        "headers" => { "X-Global-Header" => "global_val", "X-Common" => "from_global" }
      },
      "providers" => {
        "custom_deepseek" => {
          "type" => "openai_compatible",
          "endpoint" => "https://api.deepseek.com",
          "headers" => { "X-Common" => "from_provider", "X-Provider" => "p_val" }
        }
      }
    }
    File.write(File.join(@temp_dir, "rubik.yml"), YAML.dump(config_data))
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    registry = Rubik::LLM::Registry.new(cfg)
    provider = registry.get("custom_deepseek")

    assert_equal "from_provider", provider.headers["X-Common"]
    assert_equal "global_val", provider.headers["X-Global-Header"]
    assert_equal "p_val", provider.headers["X-Provider"]
  end

  def test_openai_compatible_headers_merge_and_override
    captured_headers = nil
    captured_timeout = nil
    captured_open_timeout = nil

    provider = Rubik::LLM::OpenAICompatibleProvider.new(
      endpoint: "https://api.test.com/v1/chat/completions",
      headers: { "X-Static" => "static_val", "X-Override" => "initial" },
      api_key: "secret"
    )

    Rubik::LLM::HTTPClient.stub(:post_json, lambda { |_url, opts|
      captured_headers = opts[:headers]
      captured_timeout = opts[:timeout]
      captured_open_timeout = opts[:open_timeout]
      { "choices" => [{ "message" => { "content" => "ok" } }] }
    }) do
      provider.complete(
        [{ role: "user", content: "hi" }],
        headers: { "X-Override" => "overridden", "X-Dynamic" => "dyn" },
        timeout: 99,
        open_timeout: 7
      )
    end

    assert_equal "Bearer secret", captured_headers["Authorization"]
    assert_equal "static_val", captured_headers["X-Static"]
    assert_equal "overridden", captured_headers["X-Override"]
    assert_equal "dyn", captured_headers["X-Dynamic"]
    assert_equal 99, captured_timeout
    assert_equal 7, captured_open_timeout
  end

  def test_anthropic_headers_merge_and_override
    captured_headers = nil
    captured_timeout = nil
    captured_open_timeout = nil

    provider = Rubik::LLM::AnthropicProvider.new(
      headers: { "X-Static" => "anthropic_static", "X-Version" => "v1" }
    )

    ENV["ANTHROPIC_API_KEY"] = "mock_anthropic_key"
    begin
      Rubik::LLM::HTTPClient.stub(:post_json, lambda { |_url, opts|
        captured_headers = opts[:headers]
        captured_timeout = opts[:timeout]
        captured_open_timeout = opts[:open_timeout]
        { "content" => [{ "type" => "text", "text" => "hello" }] }
      }) do
        provider.complete(
          [{ role: "user", content: "hi" }],
          headers: { "X-Version" => "v2", "X-Dynamic" => "dyn_anthropic" },
          timeout: 80,
          open_timeout: 12
        )
      end
    ensure
      ENV.delete("ANTHROPIC_API_KEY")
    end

    assert_equal "mock_anthropic_key", captured_headers["x-api-key"]
    assert_equal "anthropic_static", captured_headers["X-Static"]
    assert_equal "v2", captured_headers["X-Version"]
    assert_equal "dyn_anthropic", captured_headers["X-Dynamic"]
    assert_equal 80, captured_timeout
    assert_equal 12, captured_open_timeout
  end

  def test_ollama_headers_merge_and_override
    captured_headers = nil
    captured_timeout = nil
    captured_open_timeout = nil

    provider = Rubik::LLM::OllamaProvider.new(
      headers: { "X-Ollama-Static" => "static" }
    )

    Rubik::LLM::HTTPClient.stub(:post_json, lambda { |_url, opts|
      captured_headers = opts[:headers]
      captured_timeout = opts[:timeout]
      captured_open_timeout = opts[:open_timeout]
      { "message" => { "content" => "ollama response" } }
    }) do
      provider.complete(
        [{ role: "user", content: "hi" }],
        headers: { "X-Ollama-Dynamic" => "dynamic" },
        timeout: 45,
        open_timeout: 6
      )
    end

    assert_equal "static", captured_headers["X-Ollama-Static"]
    assert_equal "dynamic", captured_headers["X-Ollama-Dynamic"]
    assert_equal 45, captured_timeout
    assert_equal 6, captured_open_timeout
  end

  def test_loop_effective_opts_injects_timeouts_from_config
    config_data = {
      "llm" => {
        "stream_timeout" => 150,
        "open_timeout" => 25
      }
    }
    File.write(File.join(@temp_dir, "rubik.yml"), YAML.dump(config_data))
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)

    captured_effective_opts = nil
    mock_loop = build_knob_loop(cfg, Object.new)
    mock_loop.define_singleton_method(:execute_batch_request) do |opts|
      captured_effective_opts = opts
    end

    mock_loop.send(:send_llm_request_with_recovery, {})

    assert_equal 150, captured_effective_opts[:stream_timeout]
    assert_equal 25, captured_effective_opts[:open_timeout]
    assert_equal 150, captured_effective_opts[:timeout]
    assert_equal 32_000, captured_effective_opts[:context_limit]
    assert_equal 2048, captured_effective_opts[:max_tokens]
  end

  # Locks the allocate-compatibility contract from review Öneri 3: the loop's
  # provider-config resolution must work on an allocated (never-initialized)
  # loop, because build_knob_loop skips initialize entirely.
  def test_provider_registry_key_works_on_allocated_loop
    mock_loop = Rubik::Orchestrator::Loop.allocate
    provider = Object.new
    def provider.name = "internlm"
    mock_loop.instance_variable_set(:@provider, provider)
    assert_equal "internlm", mock_loop.send(:provider_registry_key)
  end

  # Builds an allocated Loop wired with the minimum state needed to observe
  # the send_llm_request_with_recovery routing decision.
  def build_knob_loop(cfg, provider)
    mock_loop = Rubik::Orchestrator::Loop.allocate
    mock_loop.instance_variable_set(:@config, cfg)
    mock_loop.instance_variable_set(:@context_limit, 32_000)
    mock_loop.instance_variable_set(:@max_output_tokens, 2048)
    mock_loop.instance_variable_set(:@history, [])
    mock_loop.instance_variable_set(:@provider, provider)

    stream_mgr = Object.new

    def stream_mgr.llm_retry_notifier
      -> {}
    end
    mock_loop.instance_variable_set(:@stream_manager, stream_mgr)
    mock_loop
  end

  # Stubs both routing exits and records which one fired. The streaming exit
  # lives on the loop's stream manager, not on the loop itself.
  def capture_routing(mock_loop)
    hits = { routed: nil }
    stream_mgr = mock_loop.instance_variable_get(:@stream_manager)
    stream_mgr.define_singleton_method(:execute_streaming_request) { |_opts| hits[:routed] = :streamed }
    mock_loop.define_singleton_method(:execute_batch_request) { |_opts| hits[:routed] = :batch }
    hits
  end

  def test_loop_provider_scoped_stream_false_routes_to_batch
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    cfg.set("providers.internlm.stream", false)

    provider = Object.new
    def provider.name = "internlm"
    def provider.stream_chat(*_args) = []

    mock_loop = build_knob_loop(cfg, provider)
    routing = capture_routing(mock_loop)

    mock_loop.send(:send_llm_request_with_recovery, {})

    assert_equal :batch, routing[:routed]
  end

  def test_loop_provider_scoped_stream_true_beats_global_off
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    cfg.set("llm.stream", false)
    cfg.set("providers.internlm.stream", true)

    provider = Object.new
    def provider.name = "internlm"
    def provider.stream_chat(*_args) = []

    mock_loop = build_knob_loop(cfg, provider)
    routing = capture_routing(mock_loop)

    mock_loop.send(:send_llm_request_with_recovery, {})

    assert_equal :streamed, routing[:routed]
  end

  def test_loop_stream_falls_back_to_global_when_provider_key_absent
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    cfg.set("llm.stream", false)

    provider = Object.new
    def provider.name = "otherprov"
    def provider.stream_chat(*_args) = []

    mock_loop = build_knob_loop(cfg, provider)
    routing = capture_routing(mock_loop)

    mock_loop.send(:send_llm_request_with_recovery, {})

    assert_equal :batch, routing[:routed]
  end

  def test_loop_stream_uses_class_derived_name_when_provider_unnamed
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    cfg.set("providers.ollama.stream", false)

    provider = Rubik::LLM::OllamaProvider.new(endpoint: "http://localhost:11434", model: "qwen2.5-coder:7b")

    mock_loop = build_knob_loop(cfg, provider)
    routing = capture_routing(mock_loop)

    mock_loop.send(:send_llm_request_with_recovery, {})

    assert_equal :batch, routing[:routed]
  end

  def test_loop_provider_scoped_timeouts_override_globals
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    cfg.set("providers.internlm.stream_timeout", 90)
    cfg.set("providers.internlm.open_timeout", 7)

    captured = {}

    internlm = Object.new
    def internlm.name = "internlm"
    internlm_loop = build_knob_loop(cfg, internlm)
    internlm_loop.define_singleton_method(:execute_batch_request) { |opts| captured[:internlm] = opts }
    internlm_loop.send(:send_llm_request_with_recovery, {})

    other = Object.new
    def other.name = "otherprov"
    other_loop = build_knob_loop(cfg, other)
    other_loop.define_singleton_method(:execute_batch_request) { |opts| captured[:other] = opts }
    other_loop.send(:send_llm_request_with_recovery, {})

    assert_equal 90, captured[:internlm][:stream_timeout]
    assert_equal 7, captured[:internlm][:open_timeout]
    assert_equal 90, captured[:internlm][:timeout]
    assert_equal 120, captured[:other][:stream_timeout]
    assert_equal 15, captured[:other][:open_timeout]
  end

  def test_scoped_knobs_reach_custom_named_ollama_and_anthropic_providers
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    cfg.set("providers.mynode", { "type" => "ollama", "endpoint" => "http://localhost:11434", "stream" => false })
    cfg.set("providers.myclaude", { "type" => "anthropic", "model" => "claude-x" })

    registry = Rubik::LLM::Registry.new(cfg)
    assert_equal "mynode", registry.get("mynode").name
    assert_equal "myclaude", registry.get("myclaude").name

    # The custom name is the config key the loop resolves scoped knobs under —
    # providers.mynode.stream must win even though the instance is an
    # OllamaProvider (class-derived key would be "ollama").
    mock_loop = build_knob_loop(cfg, registry.get("mynode"))
    routing = capture_routing(mock_loop)

    mock_loop.send(:send_llm_request_with_recovery, {})

    assert_equal :batch, routing[:routed]
  end

  def test_registry_max_output_tokens_for_reflects_dynamic_config_set
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    registry = Rubik::LLM::Registry.new(cfg)

    # Initial defaults with config: ollama inherits 4096 from DEFAULT_CONFIG, anthropic 16384, openai 16384
    assert_equal 4096, registry.max_output_tokens_for("ollama")
    assert_equal 16_384, registry.max_output_tokens_for("anthropic")
    assert_equal 16_384, registry.max_output_tokens_for("openai")

    # Update knob dynamically via config.set
    cfg.set("llm.default_max_output_tokens", 8192)
    assert_equal 8192, registry.max_output_tokens_for("ollama")
    assert_equal 16_384, registry.max_output_tokens_for("anthropic")
    assert_equal 16_384, registry.max_output_tokens_for("openai")

    # Set higher than built-in defaults
    cfg.set("llm.default_max_output_tokens", 32_768)
    assert_equal 32_768, registry.max_output_tokens_for("ollama")
    assert_equal 32_768, registry.max_output_tokens_for("anthropic")
    assert_equal 32_768, registry.max_output_tokens_for("openai")
  end

  def test_loop_and_loop_service_max_output_tokens_fallback_to_config
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    cfg.set("llm.default_max_output_tokens", 8192)

    mock_shell = Struct.new(:config, :buffer_manager, :snapshot_store, :context_index, :lsp_manager, :runtime_manager).new(
      cfg, nil, nil, nil, nil, nil
    )
    mock_provider = Object.new
    mock_tools = Object.new

    loop_inst = Rubik::Orchestrator::Loop.new(provider: mock_provider, tool_registry: mock_tools, shell: mock_shell)
    assert_equal 8192, loop_inst.instance_variable_get(:@max_output_tokens)

    require "rubik/runtime/loop_service"
    service_loop = Rubik::Runtime::LoopService.build_loop(nil, shell: mock_shell, config: { provider: mock_provider, tool_registry: mock_tools })
    assert_equal 8192, service_loop.instance_variable_get(:@max_output_tokens)
  end

  def test_ollama_provider_includes_num_predict_when_max_tokens_given
    provider = Rubik::LLM::OllamaProvider.new(endpoint: "http://localhost:11434")
    captured_payload = nil

    Rubik::LLM::HTTPClient.stub(:post_json, lambda { |_url, opts|
      captured_payload = opts[:payload]
      { "message" => { "content" => "ok" } }
    }) do
      provider.complete(
        [{ role: "user", content: "test" }],
        max_tokens: 8192,
        context_limit: 16_384
      )
    end

    assert_equal 8192, captured_payload.dig(:options, :num_predict)
    assert_equal 16_384, captured_payload.dig(:options, :num_ctx)
  end

  def test_config_set_llm_resets_sticky_conversation_stamp
    require "rubik/repl/shell"
    cfg = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(config: cfg)

    # Simulate sticky route stamp cached from turn 1
    shell.conversation_route_stamp = {
      provider: shell.llm_registry.get("ollama"),
      model: "qwen2.5-coder:7b",
      max_output_tokens: 4096
    }
    assert shell.conversation_route_stamp

    # Execute !config set llm.default_max_output_tokens 8192
    shell.execute_input("!config set llm.default_max_output_tokens 8192")

    assert_equal 8192, cfg.fetch("llm.default_max_output_tokens")
    assert_nil shell.conversation_route_stamp, "Setting llm.* config must reset the sticky stamp"

    # Next route call gets the updated 8192 limit
    routed = shell.router.route(task_type: :auto, prompt: "test prompt")
    assert_equal 8192, routed[:max_output_tokens]
  end
end
