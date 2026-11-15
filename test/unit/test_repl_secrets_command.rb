# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/repl/commands/secrets"
require "rubik/repl/commands/workspace"
require "rubik/repl/commands/agent_providers"
require "stringio"

# !secrets command surface + secret display masking. No values are ever
# printed: the inventory shows statuses only, and display masks plaintext.
class TestReplSecretsCommand < Minitest::Test
  FAKE = "sk-test-not-a-real-credential"

  def setup
    @temp_root = Dir.mktmpdir("rubik_project")
    @temp_home = Dir.mktmpdir("rubik_home")
    Rubik::Security::SecretStore.backend = MemoryBackend.new
    @config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    @out = StringIO.new
    @ctx = CtxDouble.new(@config, @out)
  end

  def teardown
    Rubik::Security::SecretStore.reset!
    FileUtils.remove_entry(@temp_root)
    FileUtils.remove_entry(@temp_home)
  end

  def test_backend_reports_active_store
    dispatch("backend")

    assert_includes @out.string, "Secret store backend:"
  end

  def test_list_reports_statuses_without_values
    @config.set("providers.acme",
                { "type" => "openai_compatible", "endpoint" => "https://acme.test/v1", "api_key" => FAKE },
                persist: :global)
    @out.truncate(0)
    @out.rewind

    dispatch("list")

    assert_includes @out.string, "providers.acme.api_key: stored in secret store"
    refute_includes @out.string, FAKE
  end

  def test_list_flags_plaintext_for_migration
    @config.set("providers.legacy",
                { "type" => "openai_compatible", "endpoint" => "https://legacy.test/v1",
                  "api_key_env" => "LEGACY_API_KEY" },
                persist: :global)
    @config.data["providers"]["legacy"]["api_key"] = FAKE # bypass routing
    @out.truncate(0)
    @out.rewind

    dispatch("list")

    assert_includes @out.string, "PLAINTEXT — migrate this key"
    refute_includes @out.string, FAKE
  end

  def test_migrate_moves_plaintext_layers_to_the_store
    @config.set("providers.acme",
                { "type" => "openai_compatible", "endpoint" => "https://acme.test/v1",
                  "api_key_env" => "ACME_API_KEY" },
                persist: :global)
    @config.data["providers"]["acme"]["api_key"] = FAKE # bypass routing
    @config.global_layer["providers"]["acme"]["api_key"] = FAKE
    @out.truncate(0)
    @out.rewind

    dispatch("migrate")

    assert_includes @out.string, "migrated"
    assert_equal "rubik-secret:providers.acme.api_key", @config.fetch("providers.acme.api_key")
    assert_equal FAKE, Rubik::Security::SecretStore.fetch("providers.acme.api_key")
    refute_includes @out.string, FAKE
  end

  def test_has_and_delete_roundtrip
    Rubik::Security::SecretStore.set("providers.acme.api_key", FAKE)

    dispatch("has providers.acme.api_key")
    assert_includes @out.string, "providers.acme.api_key: stored"

    @out.truncate(0)
    @out.rewind
    dispatch("delete providers.acme.api_key")
    assert_includes @out.string, "Deleted stored secret"
    assert_nil Rubik::Security::SecretStore.fetch("providers.acme.api_key")
  end

  def test_unknown_subcommand_shows_usage
    dispatch("nonsense")

    assert_includes @out.string, "Usage: !secrets"
  end

  # --- display masking ---

  def test_config_display_masks_plaintext_but_shows_references
    display = Rubik::REPL::Commands::Workspace.method(:display_value)

    assert_equal Rubik::Security::Redactor::MASK_STRING,
                 display.call("providers.acme.api_key", FAKE)
    assert_equal "rubik-secret:providers.acme.api_key",
                 display.call("providers.acme.api_key", "rubik-secret:providers.acme.api_key")
    assert_equal "https://acme.test/v1",
                 display.call("providers.acme.endpoint", "https://acme.test/v1")
  end

  def test_provider_key_echo_is_masked
    res = { ok: true, secret: { stored: true, backend: :memory_test, names: ["providers.acme.api_key"] } }
    ctx_out = StringIO.new
    ctx = CtxDouble.new(@config, ctx_out)

    Rubik::REPL::Commands::AgentProviders.send(:render_secret_stored_line, res, ctx)

    assert_includes ctx_out.string, "stored via memory_test"
  end

  def dispatch(line)
    Rubik::REPL::Commands::Secrets.send(:dispatch, line.split, @ctx)
  end

  CtxDouble = Struct.new(:config, :out) do
    def refresh_llm_registry!
      @refreshed = true
    end

    def refreshed?
      @refreshed
    end
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
