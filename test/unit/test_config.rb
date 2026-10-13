# frozen_string_literal: true

require_relative "../test_helper"

class TestConfig < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @temp_home = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
    FileUtils.remove_entry(@temp_home)
  end

  def test_default_config_when_no_files_exist
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    assert_equal "ollama", config.fetch("model.provider")
    assert_equal 3, config.fetch("repair.max_attempts")
    assert_equal false, config.fetch("network.allow")
    assert_equal true, config.fetch("llm.stream")
    assert_equal true, Rubik::Config::DEFAULT_CONFIG.dig("llm", "stream")
  end

  def test_fetch_existing_key
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    assert_equal "ollama", config.fetch("model.provider")
  end

  def test_fetch_non_existent_key
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    assert_nil config.fetch("nonexistent.key")
  end

  def test_fetch_with_default
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    assert_equal "default_val", config.fetch("nonexistent.key", "default_val")
  end

  def test_fetch_nested_key
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    assert_equal "qwen2.5-coder:7b", config.fetch("models.default.name")
    assert_equal "qwen2.5-coder:1.5b", config.fetch("models.fast.name")
  end

  def test_project_config_overrides_global_and_default
    global_dir = File.join(@temp_home, ".rubik")
    FileUtils.mkdir_p(global_dir)
    File.write(File.join(global_dir, "config.yml"), YAML.dump("model" => { "provider" => "openai" }))

    File.write(File.join(@temp_dir, "rubik.yml"), YAML.dump("model" => { "provider" => "anthropic", "name" => "claude-3" }))

    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    assert_equal "anthropic", config.fetch("model.provider")
    assert_equal "claude-3", config.fetch("model.name")
  end

  def test_corrupted_yaml_produces_warning_and_uses_defaults
    File.write(File.join(@temp_dir, "rubik.yml"), "invalid: yaml: [")
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)

    assert(config.warnings.any? { |w| w.include?("Cannot load config because") })
    assert_equal "ollama", config.fetch("model.provider")
  end

  def test_unknown_key_produces_warning
    File.write(File.join(@temp_dir, "rubik.yml"), YAML.dump("unknown_setting" => "val"))
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)

    assert(config.warnings.any? { |w| w.include?("Unknown config key 'unknown_setting'") })
  end

  def test_validate_schema_strict_with_fuzzy_suggestions
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    bad_hash = { "llm" => { "stram" => true } }

    err = assert_raises(ArgumentError) do
      config.send(:validate_schema, bad_hash, strict: true)
    end

    assert_includes err.message, "Unknown config key 'llm.stram'"
    assert_includes err.message, "Did you mean 'llm.stream'?"
  end

  def test_validate_schema_raises_argument_error_for_non_hash_input
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)

    [nil, "not_a_hash", 123, ["array_item"], :symbol, true, Object.new].each do |non_hash|
      err = assert_raises(ArgumentError) do
        config.send(:validate_schema, non_hash)
      end

      assert_equal "Configuration must be a Hash, got #{non_hash.class}", err.message
    end
  end

  def test_model_persistence_and_restart_without_stale_host
    config1 = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    config1.set("providers.cline", {
                  "type" => "openai_compatible",
                  "endpoint" => "https://api.cline.bot/api/v1/chat/completions",
                  "api_key" => "sk-test",
                  "models" => [{ "name" => "cline-pass/deepseek-v4-flash", "context_limit" => 64_000 }]
                }, persist: :global)

    config1.set_model_spec(:default, provider: "cline", name: "cline-pass/deepseek-v4-flash", persist: :global)

    # Verify session 1 in memory
    spec1 = config1.model_spec(:default)
    assert_equal "cline", spec1["provider"]
    assert_equal "cline-pass/deepseek-v4-flash", spec1["name"]
    assert_nil spec1["host"]

    # Simulate fresh process restart (Session 2)
    config2 = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    spec2 = config2.model_spec(:default)
    assert_equal "cline", spec2["provider"]
    assert_equal "cline-pass/deepseek-v4-flash", spec2["name"]
    assert_nil spec2["host"]

    # Router should route directly to cline provider
    router = Rubik::LLM::Router.new(config: config2)
    routed = router.route(task_type: :default)
    assert_equal "cline", routed[:provider].name
    assert_equal "cline-pass/deepseek-v4-flash", routed[:model]
  end

  def test_on_change_without_block_is_a_callable_noop_and_registers_no_listener
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    noop = config.on_change("model")

    assert_kind_of Proc, noop
    assert_nil noop.call, "the block-less unsubscribe must be callable and do nothing"

    _out, err = capture_io { config.set("model.provider", "openai") }
    assert_empty err, "no listener may be registered without a block (a nil callback would warn here)"
  end
end
