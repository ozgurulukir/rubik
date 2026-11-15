# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/security/secret_store"

# SecretPolicy behavior lock: routing plaintext provider keys into
# SecretStore, refusing :project plaintext, honest fallbacks, and the
# schema-backed escape hatch. Every test runs against an injected memory
# backend — no host keyring is touched.
class TestConfigSecretPolicy < Minitest::Test
  FAKE = "sk-test-not-a-real-credential"

  def setup
    @temp_root = Dir.mktmpdir("rubik_project")
    @temp_home = Dir.mktmpdir("rubik_home")
    @backend = MemoryBackend.new
    Rubik::Security::SecretStore.backend = @backend
    @config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
  end

  def teardown
    Rubik::Security::SecretStore.reset!
    FileUtils.remove_entry(@temp_root)
    FileUtils.remove_entry(@temp_home)
  end

  def test_project_plaintext_is_refused
    res = @config.set("providers.openai.api_key", FAKE, persist: :project)

    refute res[:ok]
    assert_includes res[:error], "refusing to store plaintext secret"
    assert_includes res[:error], "security.allow_project_secrets"
    # Nothing leaked: neither the config layer nor the store holds it,
    # and no project config file was created.
    assert_nil @config.fetch("providers.openai.api_key")
    assert_empty @backend.saved
    refute File.exist?(File.join(@temp_root, ".rubik", "config.yml"))
  end

  def test_global_plaintext_is_routed_to_the_store
    res = @config.set("providers.openai.api_key", FAKE, persist: :global)

    assert res[:ok]
    assert res[:secret][:stored]
    ref = @config.fetch("providers.openai.api_key")
    assert_equal "rubik-secret:providers.openai.api_key", ref
    assert_equal FAKE, @backend.read("providers.openai.api_key")

    disk = File.read(File.join(@temp_home, ".rubik", "config.yml"))
    refute_includes disk, FAKE
    assert_includes disk, "rubik-secret:"
  end

  def test_session_scope_keeps_value_in_memory
    res = @config.set("providers.openai.api_key", FAKE, persist: nil)

    assert res[:ok]
    assert_nil res[:secret]
    assert_equal FAKE, @config.fetch("providers.openai.api_key")
    assert_empty @backend.instance_variable_get(:@saved)
  end

  def test_references_are_allowed_in_project_scope
    ref = Rubik::Security::SecretStore.set("providers.openai.api_key", FAKE)
    res = @config.set("providers.openai.api_key", ref, persist: :project)

    assert res[:ok]
    assert_nil res[:secret] # nothing newly stored
    assert_equal ref, @config.fetch("providers.openai.api_key")
  end

  def test_whole_provider_hash_writes_route_the_api_key_leaf
    res = @config.set("providers.anthropic",
                      { "type" => "anthropic", "endpoint" => "https://api.test/v1", "api_key" => FAKE },
                      persist: :global)

    assert res[:ok]
    ref = @config.fetch("providers.anthropic.api_key")
    assert_equal "rubik-secret:providers.anthropic.api_key", ref
    # The rest of the spec survives untouched.
    assert_equal "anthropic", @config.fetch("providers.anthropic.type")
    assert_equal FAKE, @backend.read("providers.anthropic.api_key")
  end

  def test_project_store_failure_still_refuses_without_override
    Rubik::Security::SecretStore.backend = FailingBackend.new

    res = @config.set("providers.openai.api_key", FAKE, persist: :project)

    refute res[:ok]
    # The scope guard refuses up front; the failing store is irrelevant.
    assert_includes res[:error], "refusing to store plaintext secret"
  end

  def test_global_store_failure_degrades_with_loud_warning
    Rubik::Security::SecretStore.backend = FailingBackend.new

    res = @config.set("providers.openai.api_key", FAKE, persist: :global)

    assert res[:ok] # gh-style: write proceeds
    refute res[:secret][:stored]
    assert_includes res[:secret][:warning], "plaintext kept"
    assert_equal FAKE, @config.fetch("providers.openai.api_key")
    assert_includes @config.warnings.join("\n"), "OS secret store unavailable"
  end

  def test_override_restores_legacy_project_plaintext_on_store_failure
    Rubik::Security::SecretStore.backend = FailingBackend.new
    @config.set("security.allow_project_secrets", true, persist: :global)

    res = @config.set("providers.local.api_key", FAKE, persist: :project)

    assert res[:ok]
    refute res[:secret][:stored]
    disk = File.read(File.join(@temp_root, ".rubik", "config.yml"))
    assert_includes disk, FAKE
  end

  def test_override_still_prefers_the_store_when_it_works
    @config.set("security.allow_project_secrets", true, persist: :global)

    res = @config.set("providers.local.api_key", FAKE, persist: :project)

    assert res[:ok]
    assert res[:secret][:stored]
    assert_equal "rubik-secret:providers.local.api_key", @config.fetch("providers.local.api_key")
  end

  def test_deleting_secret_path_also_drops_stored_secret
    @config.set("providers.openai.api_key", FAKE, persist: :global)
    assert_equal FAKE, @backend.read("providers.openai.api_key")

    res = @config.delete("providers.openai.api_key", persist: :global)

    assert res[:ok]
    assert_nil @config.fetch("providers.openai.api_key")
    assert_nil @backend.read("providers.openai.api_key")
  end

  def test_boot_warns_on_plaintext_project_secrets
    project_cfg = File.join(@temp_root, ".rubik", "config.yml")
    FileUtils.mkdir_p(File.dirname(project_cfg))
    File.write(project_cfg, <<~YAML)
      providers:
        legacy:
          type: openai_compatible
          endpoint: https://legacy.test/v1
          api_key: #{FAKE}
    YAML

    config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)

    assert_includes config.warnings.join("\n"), "plaintext API key"
    assert_includes config.warnings.join("\n"), "!secrets migrate"
  end

  def test_secret_key_predicate
    policy = Rubik::Config::SecretPolicy

    assert policy.secret_key?("providers.openai.api_key")
    assert policy.secret_key?("api_key")
    refute policy.secret_key?("providers.openai.endpoint")
    refute policy.secret_key?("model.api_key_ttl") # api_key must be the leaf
    refute policy.secret_key?("max_tokens")
  end

  def test_env_var_flips_project_secrets_escape_hatch
    resolved = Rubik::Config::EnvLoader.load_env(
      { "RUBIK_SECURITY_ALLOW_PROJECT_SECRETS" => "true" },
      Rubik::Config::DEFAULT_CONFIG,
      []
    )

    assert_equal true, resolved.dig("security", "allow_project_secrets")
  end

  FailingBackend = Class.new do
    def write(_name, _value)
      raise Rubik::Security::SecretStore::Error, "backend down (test)"
    end

    def read(_name) = nil

    def delete(_name) = true
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

    attr_reader :saved
  end
end
