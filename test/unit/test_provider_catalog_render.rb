# frozen_string_literal: true

require_relative "../test_helper"

# Pins the provider-catalog rendering byte-for-byte for BOTH entry points
# (!provider list and the agent-visible !providers) before they share one
# renderer: the audiences differ, the pixels must not.
class TestProviderCatalogRender < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik_render_root")
    @temp_home = Dir.mktmpdir("rubik_render_home")
    @out = StringIO.new
    # Injected clean config: a default Shell would merge this repo's own
    # .rubik/config.yml into the catalog and the pin would flake per machine.
    @config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    @shell = Rubik::REPL::Shell.new(config: @config, output: @out)
    @shell.execute_input("!provider add acme openai_compatible https://api.acme.dev/v1 " \
                         "--model=acme-small --context=8192")
    @shell.execute_input("!provider add-model acme acme-large-with-long-name --context=131072")
  end

  def teardown
    @shell.stop
    FileUtils.remove_entry(@temp_root)
    FileUtils.remove_entry(@temp_home)
  end

  def expected_catalog
    <<~OUTPUT
      === Configured LLM Providers & Models ===

      • Provider: OLLAMA (OllamaProvider)
        Endpoint: http://localhost:11434
        Models  : (Default / dynamically requested via model name)

      • Provider: OPENAI (OpenAIProvider)
        Endpoint: https://api.openai.com/v1/chat/completions
        Models  : (Default / dynamically requested via model name)

      • Provider: ANTHROPIC (AnthropicProvider)
        Endpoint: cloud
        Models  : (Default / dynamically requested via model name)

      • Provider: ACME (OpenAICompatibleProvider)
        Endpoint: https://api.acme.dev/v1/chat/completions
        Models  :
          - acme-small                          [Context: 8192 tokens]
          - acme-large-with-long-name           [Context: 131072 tokens]
    OUTPUT
  end

  def test_provider_list_renders_the_full_catalog
    @out.reopen
    @shell.execute_input("!provider list")
    assert_equal expected_catalog, @out.string
  end

  def test_providers_renders_the_identical_catalog
    @out.reopen
    @shell.execute_input("!providers")
    assert_equal expected_catalog, @out.string
  end
end
