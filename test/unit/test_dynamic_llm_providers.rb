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
    xml_with_limit = Rubik::Prompt::ContextBuilder.build_system_context(services: Rubik::Prompt::Services.new(context_limit: 128_000))
    assert_includes xml_with_limit, '<context_budget limit="128000" unit="tokens" />'

    xml_without_limit = Rubik::Prompt::ContextBuilder.build_system_context(services: Rubik::Prompt::Services.new)
    refute_includes xml_without_limit, "<context_budget"
  end

  def test_provider_set_parses_typed_scalar_fields
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(output: out)

    shell.execute_input("!provider add internlm openai_compatible https://api.internlm.ai/v1/chat/completions " \
                        "--model=intern-latest")
    out.reopen
    shell.execute_input("!provider set internlm stream false")
    assert_includes out.string, "Updated provider 'internlm' field 'stream' to 'false'"
    # Must be a real false — a raw "false" String is truthy in Ruby.
    assert_equal false, shell.config.fetch("providers.internlm.stream")

    out.reopen
    shell.execute_input("!provider set internlm tool_native false")
    assert_equal false, shell.config.fetch("providers.internlm.tool_native")

    out.reopen
    shell.execute_input("!provider set internlm stream_timeout 90")
    assert_equal 90, shell.config.fetch("providers.internlm.stream_timeout")

    out.reopen
    shell.execute_input("!provider set internlm tool_native true")
    assert_equal true, shell.config.fetch("providers.internlm.tool_native")
  end

  def test_config_set_repl_path_writes_typed_provider_knob
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(output: out)

    shell.execute_input("!provider add internlm openai_compatible https://api.internlm.ai/v1/chat/completions " \
                        "--model=intern-latest")
    out.reopen
    shell.execute_input("!config set providers.internlm.stream false")
    assert_includes out.string, "Config 'providers.internlm.stream' updated to 'false'"
    assert_equal false, shell.config.fetch("providers.internlm.stream")

    out.reopen
    shell.execute_input("!config get providers.internlm.stream")
    assert_includes out.string, "providers.internlm.stream = false"
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
    shell.execute_input("!provider add mistral openai_compatible https://api.mistral.ai/v1/chat/completions " \
                        "--key-env=MISTRAL_API_KEY --model=mistral-large-latest --context=128000")
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

    # 5. !provider add with direct --key
    out.reopen
    shell.execute_input("!provider add deepseek openai_compatible https://api.deepseek.com/v1/chat/completions " \
                        "--key=sk-secret-123 --model=deepseek-chat --context=64000")
    assert_includes out.string, "Successfully added provider 'deepseek'"
    deepseek_provider = shell.llm_registry.get("deepseek")
    assert_equal "sk-secret-123", deepseek_provider.api_key

    # 6. !provider add-model
    out.reopen
    shell.execute_input("!provider add-model deepseek deepseek-coder --context=128000")
    assert_includes out.string, "Added model 'deepseek-coder' (128000 tokens) to provider 'deepseek'"
    assert_equal 128_000, shell.llm_registry.context_limit_for("deepseek", "deepseek-coder")

    # 7. !provider set
    out.reopen
    shell.execute_input("!provider set deepseek key sk-updated-key")
    assert_includes out.string, "Updated provider 'deepseek' field 'key' to 'sk-updated-key'"
    assert_equal "sk-updated-key", shell.llm_registry.get("deepseek").api_key

    # 8. !provider remove-model
    out.reopen
    shell.execute_input("!provider remove-model deepseek deepseek-chat")
    assert_includes out.string, "Removed model 'deepseek-chat' from provider 'deepseek'"

    # 9. Invalid endpoint validation
    out.reopen
    shell.execute_input("!provider add bad_prov openai_compatible not_a_url")
    assert_includes out.string, "Error: Endpoint must be a valid HTTP/HTTPS URL"
    assert_nil shell.llm_registry.get("bad_prov")

    # 10. !provider remove
    out.reopen
    shell.execute_input("!provider remove mistral")
    assert_includes out.string, "Removed provider 'mistral'"

    # 11. !provider help and !provider alone
    out.reopen
    shell.execute_input("!provider help")
    assert_includes out.string, "Usage: !provider"

    out.reopen
    shell.execute_input("!provider")
    assert_includes out.string, "Configured LLM Providers"

    # 12. Rubik.runtime accessor (deprecated bridge — behavior preserved,
    # warns ONCE on first read then stays silent; review Öneri 4 sunset)
    Rubik.remove_instance_variable(:@ambient_warned) if Rubik.instance_variable_defined?(:@ambient_warned)
    _out, warned = capture_io do
      assert_equal shell.runtime_manager, Rubik.runtime
    end
    assert_includes warned, "[DEPRECATION]"
    _out2, silent = capture_io { Rubik.runtime }
    refute_includes silent, "[DEPRECATION]"

    # 13. Synthesize command cannot overwrite built-in !provider
    syn_tool = Rubik::Tools::SynthesizeCommandTool.new(
      shell,
      shell.overlay_storage,
      nil,
      runtime_manager: shell.runtime_manager
    )
    res = syn_tool.execute(
      "name" => "provider",
      "code" => "->(args, out) { out.puts 'malicious' }"
    )
    assert_includes res, "Cannot overwrite reserved built-in command '!provider'"

    # 14. Model names with slashes (e.g. cline-pass/deepseek-v4-flash, openrouter/anthropic/claude-3.5-sonnet)
    out.reopen
    shell.execute_input("!provider add openrouter openai_compatible https://openrouter.ai/api/v1/chat/completions --key=sk-openrouter")
    assert_includes out.string, "Successfully added provider 'openrouter'"

    # Add model with slash to openrouter
    out.reopen
    shell.execute_input("!provider add-model openrouter cline-pass/deepseek-v4-flash --context=64000")
    assert_includes out.string, "Added model 'cline-pass/deepseek-v4-flash' (64000 tokens) to provider 'openrouter'"

    # Set default model using openrouter/cline-pass/deepseek-v4-flash
    out.reopen
    shell.execute_input("!model openrouter/cline-pass/deepseek-v4-flash")
    assert_includes out.string, "Switched default model to openrouter/cline-pass/deepseek-v4-flash"
    assert_includes out.string, "Context: 64000 tokens"
    spec = shell.config.model_spec(:default)
    assert_equal "openrouter", spec["provider"]
    assert_equal "cline-pass/deepseek-v4-flash", spec["name"]

    # Set role model using colon syntax: openrouter:anthropic/claude-3.5-sonnet
    out.reopen
    shell.execute_input("!model set advanced openrouter:anthropic/claude-3.5-sonnet")
    assert_includes out.string, "Set model role 'advanced' to openrouter/anthropic/claude-3.5-sonnet"
    adv_spec = shell.config.model_spec(:advanced)
    assert_equal "openrouter", adv_spec["provider"]
    assert_equal "anthropic/claude-3.5-sonnet", adv_spec["name"]

    # Set model directly without provider prefix when default provider is openrouter
    out.reopen
    shell.execute_input("!model meta-llama/llama-3.3-70b-instruct")
    assert_includes out.string, "Switched default model to openrouter/meta-llama/llama-3.3-70b-instruct"
    new_spec = shell.config.model_spec(:default)
    assert_equal "openrouter", new_spec["provider"]
    assert_equal "meta-llama/llama-3.3-70b-instruct", new_spec["name"]

    # 15. Explicit space-separated provider and model syntax: !model set default openrouter deepseek/deepseek-v4-flash
    out.reopen
    shell.execute_input("!model set default openrouter deepseek/deepseek-v4-flash")
    assert_includes out.string, "Set model role 'default' to openrouter/deepseek/deepseek-v4-flash"
    sep_spec = shell.config.model_spec(:default)
    assert_equal "openrouter", sep_spec["provider"]
    assert_equal "deepseek/deepseek-v4-flash", sep_spec["name"]

    # Direct switch with separate provider and model: !model openrouter deepseek/deepseek-v4-flash
    out.reopen
    shell.execute_input("!model openrouter deepseek/deepseek-v4-flash")
    assert_includes out.string, "Switched default model to openrouter/deepseek/deepseek-v4-flash"
    dir_spec = shell.config.model_spec(:default)
    assert_equal "openrouter", dir_spec["provider"]
    assert_equal "deepseek/deepseek-v4-flash", dir_spec["name"]

    # 16. Change context limit via !model context <limit>
    out.reopen
    shell.execute_input("!model context 131072")
    assert_includes out.string, "Updated context limit for default model openrouter/deepseek/deepseek-v4-flash to 131072 tokens"
    assert_equal 131_072, shell.llm_registry.context_limit_for("openrouter", "deepseek/deepseek-v4-flash")

    # Change context limit via !model context fast <limit>
    out.reopen
    shell.execute_input("!model context fast 45000")
    assert_includes out.string, "Updated context limit for fast model"
    fast_m = shell.config.model_spec(:fast)
    assert_equal 45_000, shell.llm_registry.context_limit_for(fast_m["provider"], fast_m["name"])

    # Change context limit via !provider set-context
    out.reopen
    shell.execute_input("!provider set-context openrouter deepseek/deepseek-v4-flash 262144")
    assert_includes out.string, "Updated context limit for model 'deepseek/deepseek-v4-flash' on provider 'openrouter' to 262144 tokens"
    assert_equal 262_144, shell.llm_registry.context_limit_for("openrouter", "deepseek/deepseek-v4-flash")

    # 17. Unknown providers are refused cleanly on every upsert path —
    # no provider spec may be fabricated for a typo'd name
    out.reopen
    shell.execute_input("!model context ghost-provider some-model 4096")
    assert_includes out.string, "Provider 'ghost-provider' not found."
    assert_nil shell.config.fetch("providers.ghost-provider")

    out.reopen
    shell.execute_input("!provider add-model ghost some-model")
    assert_includes out.string, "Provider 'ghost' not found. Add it first via !provider add."

    out.reopen
    shell.execute_input("!model add ghost some-model --context=100")
    assert_includes out.string, "Provider 'ghost' not found. Add provider first via !provider add."

    out.reopen
    shell.execute_input("!provider remove-model ghost some-model")
    assert_includes out.string, "Provider 'ghost' not found."

    out.reopen
    shell.execute_input("!provider set-context ghost some-model 100")
    assert_includes out.string, "Provider 'ghost' not found."

    out.reopen
    shell.execute_input("!provider remove ghost")
    assert_includes out.string, "Provider 'ghost' not found."

    # No refusal may leak a spec into the config or the registry catalog
    assert_nil shell.config.fetch("providers.ghost")
    assert_nil shell.config.fetch("providers.ghost-provider")
    assert_nil shell.llm_registry.get("ghost")
  end
end
