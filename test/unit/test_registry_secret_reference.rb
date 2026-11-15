# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/llm/registry"

# Registry-side resolution: provider specs holding "rubik-secret:" pointers
# build clients whose api_key is the stored plaintext; raw values pass
# through unchanged (legacy configs keep working).
class TestRegistrySecretReference < Minitest::Test
  FAKE = "sk-test-not-a-real-credential"

  def setup
    @temp_root = Dir.mktmpdir("rubik_project")
    @temp_home = Dir.mktmpdir("rubik_home")
    Rubik::Security::SecretStore.backend = MemoryBackend.new
    @config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
  end

  def teardown
    Rubik::Security::SecretStore.reset!
    FileUtils.remove_entry(@temp_root)
    FileUtils.remove_entry(@temp_home)
  end

  def test_reference_resolves_into_client_api_key
    @config.set("providers.acme",
                { "type" => "openai_compatible", "endpoint" => "https://acme.test/v1", "api_key" => FAKE },
                persist: :global)
    registry = Rubik::LLM::Registry.new(@config)

    client = registry.get("acme")
    refute_nil client
    assert_equal FAKE, client.api_key
  end

  def test_missing_store_entry_resolves_to_nil
    @config.set("providers.ghost",
                { "type" => "openai_compatible", "endpoint" => "https://ghost.test/v1",
                  "api_key" => "rubik-secret:providers.ghost.api_key" },
                persist: :global)
    registry = Rubik::LLM::Registry.new(@config)

    client = registry.get("ghost")
    refute_nil client
    assert_nil client.api_key # falls back to api_key_env at request time
  end

  def test_raw_plaintext_passthrough_is_unchanged
    # Legacy config written before SecretStore: a raw value must keep
    # flowing through unmodified. Poked straight into @data to bypass the
    # write-time routing.
    @config.data["providers"] ||= {}
    @config.data["providers"]["legacy"] = {
      "type" => "openai_compatible", "endpoint" => "https://legacy.test/v1", "api_key" => FAKE
    }

    registry = Rubik::LLM::Registry.new(@config)
    client = registry.get("legacy")

    assert_equal FAKE, client.api_key
  end

  def test_keyring_refresh_applies_on_registry_rebuild
    @config.set("providers.acme",
                { "type" => "openai_compatible", "endpoint" => "https://acme.test/v1", "api_key" => FAKE },
                persist: :global)
    registry = Rubik::LLM::Registry.new(@config)

    Rubik::Security::SecretStore.set("providers.acme.api_key", "sk-test-rotated-credential")
    registry.load_from_config(@config)

    assert_equal "sk-test-rotated-credential", registry.get("acme").api_key
  end

  MemoryBackend = Class.new do
    def initialize
      @saved = {}
    end

    def write(name, value)
      @saved[name] = value
    end

    def read(name)
      @saved[name]
    end

    def delete(name)
      @saved.delete(name)
      true
    end
  end
end
