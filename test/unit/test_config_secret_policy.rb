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

    res = nil
    _out, err = capture_io do
      res = @config.set("providers.openai.api_key", FAKE, persist: :global)
    end

    assert res[:ok] # gh-style: write proceeds
    refute res[:secret][:stored]
    assert_includes res[:secret][:warning], "plaintext kept"
    assert_equal FAKE, @config.fetch("providers.openai.api_key")
    assert_includes @config.warnings.join("\n"), "OS secret store unavailable"
    # Visible at runtime without RUBIK_DEBUG, and never echoes the secret.
    assert_includes err, "OS secret store unavailable"
    refute_includes err, FAKE
  end

  def test_store_success_emits_no_fallback_warning
    _out, err = capture_io do
      @config.set("providers.healthy.api_key", FAKE, persist: :global)
    end

    assert @config.fetch("providers.healthy.api_key").start_with?("rubik-secret:")
    refute_includes err, "OS secret store unavailable"
    refute_includes @config.warnings.join("\n"), "OS secret store unavailable"
  end

  def test_redact_secret_value_masks_nested_api_keys_without_mutating_source
    policy = Rubik::Config::SecretPolicy
    source = { "type" => "openai", "api_key" => FAKE,
               "nested" => { "api_key" => FAKE, "name" => "keep" } }

    out = policy.redact_secret_value("providers.openai", source)
    redacted = policy::REDACTED_VALUE

    assert_equal redacted, out["api_key"]
    assert_equal redacted, out["nested"]["api_key"]
    assert_equal "openai", out["type"]
    assert_equal "keep", out["nested"]["name"]
    assert_equal FAKE, source["api_key"], "redaction must not mutate the source"
    assert_equal FAKE, source["nested"]["api_key"]
  end

  def test_secret_values_are_redacted_in_events_and_dmesg
    secret = "sk-leak-SECRET123"
    dmesg = Rubik::Kernel::Dmesg.new(capacity: 64)
    dispatcher = Rubik::Kernel::Dispatcher.new(dmesg: dmesg)
    bus = Rubik::EventBus.new(dispatcher: dispatcher)
    @config.event_bus = bus
    captured = []
    bus.subscribe(:config_changed) { |payload| captured << payload.dup }
    bus.subscribe(:config_deleted) { |payload| captured << payload.dup }

    # Session scope keeps the plaintext in memory, so it reaches the emitter.
    @config.set("providers.leaky.api_key", secret, persist: nil)
    @config.delete("providers.leaky.api_key", persist: nil)

    refute_includes captured.map(&:inspect).join("\n"), secret,
                    "plaintext secret leaked into a captured event payload"
    refute_includes dmesg.formatted, secret, "plaintext secret leaked into dmesg"
    redacted = Rubik::Config::SecretPolicy::REDACTED_VALUE
    assert(captured.any? { |p| p[:key] == "providers.leaky.api_key" && p[:value] == redacted })
    assert(captured.any? { |p| p[:key] == "providers.leaky.api_key" && p[:old_val] == redacted })

    # Non-secret config events must keep their real values.
    @config.set("ui.verbosity", "verbose", persist: nil)
    assert_equal "verbose", captured.last[:value]
  ensure
    bus&.stop
  end

  def test_listener_error_quoting_a_secret_is_redacted
    secret = "sk-listener-SECRET123"
    dmesg = Rubik::Kernel::Dmesg.new(capacity: 64)
    dispatcher = Rubik::Kernel::Dispatcher.new(dmesg: dmesg)
    bus = Rubik::EventBus.new(dispatcher: dispatcher)
    @config.event_bus = bus
    errors = []
    bus.subscribe(:config_listener_error) { |payload| errors << payload[:error] }
    @config.on_change("providers.secure.api_key") { raise "listener failed with #{secret}" }

    _out, err = capture_io { @config.set("providers.secure.api_key", secret, persist: nil) }

    redacted = Rubik::Config::SecretPolicy::REDACTED_VALUE
    assert_equal [redacted], errors
    refute_includes dmesg.formatted, secret
    refute_includes err, secret
  ensure
    bus&.stop
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
    # Project-scoped store names carry the ".project" suffix (scope
    # isolation — see test_scoped_secret_names_do_not_collide).
    assert_equal "rubik-secret:providers.local.api_key.project", @config.fetch("providers.local.api_key")
  end

  def test_project_layer_override_is_ignored
    # A repo-shipped project config must not be able to re-enable
    # plaintext-in-project for itself; only operator domains (global/env)
    # count. This project-layer value is inert for the guard.
    @config.set("security.allow_project_secrets", true, persist: :project)

    res = @config.set("providers.openai.api_key", FAKE, persist: :project)

    refute res[:ok]
    assert_includes res[:error], "refusing to store plaintext secret"
    assert_empty @backend.saved
  end

  def test_scoped_secret_names_do_not_collide
    @config.set("security.allow_project_secrets", true, persist: :global) # operator override: project writes route like global
    @config.set("providers.acme.api_key", "sk-test-global-scope-value", persist: :global)
    @config.set("providers.acme.api_key", "sk-test-project-scope-value", persist: :project)

    assert_equal "sk-test-global-scope-value", @backend.read("providers.acme.api_key")
    assert_equal "sk-test-project-scope-value", @backend.read("providers.acme.api_key.project")
    # Each layer's pointer resolves through its own store entry.
    assert_equal "rubik-secret:providers.acme.api_key", @config.global_layer.dig("providers", "acme", "api_key")
    assert_equal "rubik-secret:providers.acme.api_key.project", @config.project_layer.dig("providers", "acme", "api_key")
  end

  def test_delete_drops_only_the_target_scope_name
    @config.set("security.allow_project_secrets", true, persist: :global) # operator override: allow project plaintext
    @config.set("providers.acme.api_key", "sk-test-global-scope-value", persist: :global)
    @config.set("providers.acme.api_key", "sk-test-project-scope-value", persist: :project)

    res = @config.delete("providers.acme.api_key", persist: :global)

    assert res[:ok]
    # Only the removed scope's keyring entry is dropped.
    assert_nil @backend.read("providers.acme.api_key")
    # The sibling scope's entry survives, so its config pointer still resolves.
    assert_equal "sk-test-project-scope-value", @backend.read("providers.acme.api_key.project")
    assert_equal "rubik-secret:providers.acme.api_key.project",
                 @config.project_layer.dig("providers", "acme", "api_key")
  end

  def test_deleting_project_scope_leaves_global_reference_intact
    @config.set("security.allow_project_secrets", true, persist: :global)
    @config.set("providers.acme.api_key", "sk-test-global-scope-value", persist: :global)
    @config.set("providers.acme.api_key", "sk-test-project-scope-value", persist: :project)

    res = @config.delete("providers.acme.api_key", persist: :project)

    assert res[:ok]
    assert_equal "sk-test-global-scope-value", @backend.read("providers.acme.api_key")
    assert_nil @backend.read("providers.acme.api_key.project")
    assert_equal "rubik-secret:providers.acme.api_key",
                 @config.global_layer.dig("providers", "acme", "api_key")
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

  def test_remove_provider_deletes_stored_keyring_secret
    res = @config.set("providers.openai.api_key", "sk-test-secret", persist: :global)
    assert res[:ok]
    assert_equal "sk-test-secret", @backend.read("providers.openai.api_key")

    del_res = @config.remove_provider("openai", persist: :global)
    assert del_res[:ok]
    assert_nil @backend.read("providers.openai.api_key")
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
