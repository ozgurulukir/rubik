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
    mock_loop = Rubik::Orchestrator::Loop.allocate
    mock_loop.instance_variable_set(:@config, cfg)
    mock_loop.instance_variable_set(:@context_limit, 32_000)
    mock_loop.instance_variable_set(:@max_output_tokens, 2048)
    mock_loop.instance_variable_set(:@history, [])

    stream_mgr = Object.new

    def stream_mgr.llm_retry_notifier
      -> {}
    end
    mock_loop.instance_variable_set(:@stream_manager, stream_mgr)

    mock_provider = Object.new
    mock_loop.instance_variable_set(:@provider, mock_provider)

    mock_loop.define_singleton_method(:streaming_enabled) { false }
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
end
