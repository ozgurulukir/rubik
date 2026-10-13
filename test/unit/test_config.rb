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

  def test_on_change_with_nil_prefix_receives_all_key_updates
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    changes = []
    config.on_change(nil) do |key, new_val, old_val|
      changes << [key, new_val, old_val]
    end

    config.set("model.provider", "anthropic")
    config.set("repair.max_attempts", 5)

    assert_equal 2, changes.size
    assert_equal ["model.provider", "anthropic", "ollama"], changes[0]
    assert_equal ["repair.max_attempts", 5, 3], changes[1]
  end

  def test_on_change_with_specific_prefix_filters_keys
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    llm_changes = []
    config.on_change("llm") do |key, new_val, old_val|
      llm_changes << [key, new_val, old_val]
    end

    config.set("llm.stream", false)
    config.set("repair.max_attempts", 10)

    assert_equal 1, llm_changes.size
    assert_equal ["llm.stream", false, true], llm_changes[0]
  end

  def test_on_change_unsubscribe_stops_callbacks
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    calls = []
    unsubscribe = config.on_change { |key, new_val, _old_val| calls << [key, new_val] }

    config.set("repair.max_attempts", 4)
    assert_equal 1, calls.size

    unsubscribe.call
    config.set("repair.max_attempts", 5)
    assert_equal 1, calls.size
  end

  def test_on_change_without_block_returns_proc
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    res = config.on_change("llm")
    assert_kind_of Proc, res

    # Modifying key should succeed without errors
    config.set("llm.stream", false)
  end

  def test_on_change_handles_callback_exception
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    calls = []
    config.on_change do |_key, _new_val, _old_val|
      raise "callback failure"
    end
    config.on_change do |key, new_val, _old_val|
      calls << [key, new_val]
    end

    res = config.set("repair.max_attempts", 9)

    assert res[:ok]
    assert_equal 9, config.fetch("repair.max_attempts")
    assert_equal [["repair.max_attempts", 9]], calls
  end
end
