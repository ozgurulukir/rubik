# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../../lib/rubik"

class TestDynamicLLMProviders < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_llm_test")
    @home_dir = Dir.mktmpdir("rubik_llm_home")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @home_dir)
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
    FileUtils.rm_rf(@home_dir)
  end

  def test_openai_compatible_provider_attributes_and_auth_headers
    provider = Rubik::LLM::OpenAICompatibleProvider.new(
      name: "openrouter",
      endpoint: "https://openrouter.ai/api/v1/chat/completions",
      api_key: "sk-test-12345",
      headers: { "HTTP-Referer" => "https://rubik.ai", "X-Title" => "Rubik" },
      model: "anthropic/claude-3.5-sonnet",
      default_context_limit: 200_000
    )

    assert_equal "openrouter", provider.name
    assert_equal "https://openrouter.ai/api/v1/chat/completions", provider.endpoint
    assert_equal "sk-test-12345", provider.api_key
    assert_equal "anthropic/claude-3.5-sonnet", provider.model
    assert_equal 200_000, provider.default_context_limit
    assert_equal "https://rubik.ai", provider.headers["HTTP-Referer"]
  end

  def test_openai_provider_inherits_from_openai_compatible
    openai = Rubik::LLM::OpenAIProvider.new(model: "gpt-4o")
    assert openai.is_a?(Rubik::LLM::OpenAICompatibleProvider)
    assert_equal "openai", openai.name
    assert_equal "https://api.openai.com/v1/chat/completions", openai.endpoint
    assert_equal 128_000, openai.default_context_limit
  end

  def test_registry_loads_custom_providers_from_config
    @config.set("providers", {
      "openrouter" => {
        "type" => "openai_compatible",
        "endpoint" => "https://openrouter.ai/api/v1/chat/completions",
        "api_key_env" => "OPENROUTER_API_KEY",
        "models" => [
          { "name" => "anthropic/claude-3.5-sonnet", "context_limit" => 200_000 },
          { "name" => "meta-llama/llama-3.3-70b-instruct", "context_limit" => 128_000 }
        ]
      },
      "groq" => {
        "type" => "openai_compatible",
        "endpoint" => "https://api.groq.com/openai/v1/chat/completions",
        "api_key_env" => "GROQ_API_KEY",
        "models" => [
          { "name" => "llama-3.3-70b-versatile", "context_limit" => 128_000 }
        ]
      },
      "local_vllm" => {
        "type" => "openai_compatible",
        "endpoint" => "http://localhost:8000/v1/chat/completions",
        "models" => ["Qwen/Qwen2.5-Coder-32B-Instruct"]
      }
    })

    registry = Rubik::LLM::Registry.new(@config)

    # 1. Custom providers registered
    assert_includes registry.list, "openrouter"
    assert_includes registry.list, "groq"
    assert_includes registry.list, "local_vllm"
    assert_includes registry.list, "ollama"

    # 2. Context limits verified
    assert_equal 200_000, registry.context_limit_for("openrouter", "anthropic/claude-3.5-sonnet")
    assert_equal 128_000, registry.context_limit_for("openrouter", "meta-llama/llama-3.3-70b-instruct")
    assert_equal 128_000, registry.context_limit_for("groq", "llama-3.3-70b-versatile")
    assert_equal 32_768, registry.context_limit_for("local_vllm", "Qwen/Qwen2.5-Coder-32B-Instruct")
    assert_equal 32_768, registry.context_limit_for("ollama", "llama3")

    # 3. Catalog structure
    cat = registry.catalog
    assert cat.key?("openrouter")
    assert_equal "OpenAICompatibleProvider", cat["openrouter"][:type]
    assert_equal 2, cat["openrouter"][:models].size

    # 4. get_for resolving custom provider instance
    instance = registry.get_for({ "provider" => "openrouter", "name" => "anthropic/claude-3.5-sonnet" })
    assert_equal "anthropic/claude-3.5-sonnet", instance.model
    assert_equal "https://openrouter.ai/api/v1/chat/completions", instance.endpoint
  end

  def test_router_returns_context_limit
    @config.set("providers", {
      "deepseek" => {
        "type" => "openai_compatible",
        "endpoint" => "https://api.deepseek.com/chat/completions",
        "models" => [
          { "name" => "deepseek-coder", "context_limit" => 64_000 }
        ]
      }
    })
    @config.set_model_spec(:default, provider: "deepseek", name: "deepseek-coder")

    registry = Rubik::LLM::Registry.new(@config)
    router = Rubik::LLM::Router.new(config: @config, registry: registry)

    routed = router.route(task_type: :default)
    assert_equal "deepseek", routed[:spec]["provider"]
    assert_equal "deepseek-coder", routed[:model]
    assert_equal 64_000, routed[:context_limit]
  end

  def test_context_builder_includes_context_budget_xml
    xml_with_limit = Rubik::Prompt::ContextBuilder.build_system_context(context_limit: 128_000)
    assert_includes xml_with_limit, '<context_budget limit="128000" unit="tokens" />'

    xml_without_limit = Rubik::Prompt::ContextBuilder.build_system_context(context_limit: nil)
    refute_includes xml_without_limit, '<context_budget'
  end

  def test_repl_provider_commands_and_model_display
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(output: out)

    # 1. !provider list
    shell.execute_input("!provider list")
    assert_includes out.string, "=== Configured LLM Providers & Models ==="
    assert_includes out.string, "OLLAMA"

    # 2. !provider add
    out.reopen
    shell.execute_input("!provider add mistral openai_compatible https://api.mistral.ai/v1/chat/completions --key-env=MISTRAL_API_KEY --model=mistral-large-latest --context=128000")
    assert_includes out.string, "Successfully added provider 'mistral'"

    # Verify provider registered in catalog and config
    out.reopen
    shell.execute_input("!provider list")
    assert_includes out.string, "MISTRAL"
    assert_includes out.string, "mistral-large-latest"
    assert_includes out.string, "128000 tokens"

    # 3. !model set with custom provider
    out.reopen
    shell.execute_input("!model set default mistral/mistral-large-latest")
    assert_includes out.string, "Set model role 'default' to mistral/mistral-large-latest"
    assert_includes out.string, "Context: 128000 tokens"

    # 4. !model list
    out.reopen
    shell.execute_input("!model")
    assert_includes out.string, "mistral/mistral-large-latest [Context: 128000 tokens]"

    # 5. !provider remove
    out.reopen
    shell.execute_input("!provider remove mistral")
    assert_includes out.string, "Removed provider 'mistral'"
  end
end
