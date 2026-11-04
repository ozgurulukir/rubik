# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"

class TestConfigUniversalEnv < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik-env-root-")
    @temp_home = Dir.mktmpdir("rubik-env-home-")
  end

  def teardown
    FileUtils.remove_entry_secure(@temp_root) if @temp_root && File.directory?(@temp_root)
    FileUtils.remove_entry_secure(@temp_home) if @temp_home && File.directory?(@temp_home)
  end

  def test_universal_env_loader_resolves_dotted_keys
    simulated_env = {
      "RUBIK_LLM_STREAM" => "false",
      "RUBIK_AGENT_MAX_STEPS" => "55",
      "RUBIK_TOOLS_TIMEOUT_SECONDS" => "90"
    }

    warnings = []
    loaded = Rubik::Config::EnvLoader.load_env(simulated_env, Rubik::Config::DEFAULT_CONFIG, warnings)

    assert_equal false, loaded.dig("llm", "stream")
    assert_equal 55, loaded.dig("agent", "max_steps")
    assert_equal 90, loaded.dig("tools", "timeout_seconds")
    assert_empty warnings
  end

  def test_legacy_env_variables_bridge_with_deprecation_warnings
    simulated_env = {
      "RUBIK_NATIVE" => "off",
      "RUBIK_LOG_LEVEL" => "debug"
    }

    warnings = []
    loaded = Rubik::Config::EnvLoader.load_env(simulated_env, Rubik::Config::DEFAULT_CONFIG, warnings)

    assert_equal "off", loaded.dig("tools", "native")
    assert_equal "debug", loaded.dig("ui", "verbosity")

    assert_equal 2, warnings.size
    assert(warnings.any? { |w| w.include?("RUBIK_NATIVE") && w.include?("deprecated") })
    assert(warnings.any? { |w| w.include?("RUBIK_LOG_LEVEL") && w.include?("deprecated") })
  end

  def test_canonical_env_takes_precedence_over_legacy_variable
    simulated_env = {
      "RUBIK_TOOLS_NATIVE" => "on",
      "RUBIK_NATIVE" => "off"
    }

    warnings = []
    loaded = Rubik::Config::EnvLoader.load_env(simulated_env, Rubik::Config::DEFAULT_CONFIG, warnings)

    # Canonical must win
    assert_equal "on", loaded.dig("tools", "native")
    # No legacy warning since canonical was already satisfied
    assert_empty warnings
  end

  def test_legacy_map_targets_are_real_config_keys
    # Every legacy variable must map to a key that actually exists in
    # DEFAULT_CONFIG — a phantom target deep-sets a value no consumer reads
    # and trips "Unknown config key" warnings at boot.
    Rubik::Config::EnvLoader::LEGACY_MAP.each_value do |dot_key|
      keys = dot_key.split(".")
      node = Rubik::Config::DEFAULT_CONFIG
      keys.each do |k|
        assert_instance_of Hash, node, "LEGACY_MAP target '#{dot_key}' has no parent section in DEFAULT_CONFIG"
        assert node.key?(k), "LEGACY_MAP target '#{dot_key}' is absent from DEFAULT_CONFIG"
        node = node[k]
      end
    end
  end
end
