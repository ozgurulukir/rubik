# frozen_string_literal: true

require_relative "../test_helper"

class TestConfigProviderModels < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik_project")
    @temp_home = Dir.mktmpdir("rubik_home")
    @config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    @config.set("providers.acme",
                { "type" => "openai_compatible", "endpoint" => "https://api.acme.dev/v1",
                  "models" => [{ "name" => "acme-small", "context_limit" => 8192 }] })
  end

  def teardown
    FileUtils.remove_entry(@temp_root)
    FileUtils.remove_entry(@temp_home)
  end

  def test_provider_spec_returns_live_hash_for_known_provider
    spec = @config.provider_spec("acme")

    assert_equal "openai_compatible", spec["type"]
    assert_same @config.fetch("providers.acme"), spec
  end

  def test_provider_spec_returns_nil_for_unknown_or_empty_provider
    assert_nil @config.provider_spec("ghost")

    @config.set("providers.hollow", {})
    assert_nil @config.provider_spec("hollow")
  end

  def test_upsert_appends_model_to_known_provider
    assert @config.upsert_provider_model("acme", "acme-large", context_limit: 131_072)

    models = @config.provider_spec("acme")["models"]
    assert_equal [{ "name" => "acme-small", "context_limit" => 8192 },
                  { "name" => "acme-large", "context_limit" => 131_072 }], models
  end

  def test_upsert_replaces_existing_entry_without_duplicates
    assert @config.upsert_provider_model("acme", "acme-small", context_limit: 32_768)

    assert_equal [{ "name" => "acme-small", "context_limit" => 32_768 }],
                 @config.provider_spec("acme")["models"]
  end

  def test_upsert_tolerates_legacy_string_model_entries
    @config.set("providers.legacy", { "type" => "ollama", "endpoint" => "http://localhost:11434",
                                      "models" => ["old-name"] })

    assert @config.upsert_provider_model("legacy", "new-name", context_limit: 4096)
    assert_equal ["old-name", { "name" => "new-name", "context_limit" => 4096 }],
                 @config.provider_spec("legacy")["models"]

    # Upserting the legacy name replaces the bare String with a proper entry
    assert @config.upsert_provider_model("legacy", "old-name", context_limit: 8192)
    assert_equal [{ "name" => "new-name", "context_limit" => 4096 },
                  { "name" => "old-name", "context_limit" => 8192 }],
                 @config.provider_spec("legacy")["models"]
  end

  def test_upsert_returns_false_for_unknown_provider_and_writes_nothing
    refute @config.upsert_provider_model("ghost", "some-model", context_limit: 4096)
    assert_nil @config.fetch("providers.ghost")
  end

  def test_remove_drops_entry_and_survives_absent_model
    assert @config.remove_provider_model("acme", "acme-small")
    assert_empty @config.provider_spec("acme")["models"]

    # Removing an absent model is a successful no-op
    assert @config.remove_provider_model("acme", "never-existed")
    assert_empty @config.provider_spec("acme")["models"]
  end

  def test_remove_returns_false_for_unknown_provider
    refute @config.remove_provider_model("ghost", "some-model")
  end

  def test_upsert_with_global_persistence_survives_reload
    @config.upsert_provider_model("acme", "acme-persisted", context_limit: 262_144, persist: :global)

    reloaded = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    assert_includes reloaded.provider_spec("acme")["models"],
                    { "name" => "acme-persisted", "context_limit" => 262_144 }
  end
end
