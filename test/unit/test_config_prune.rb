# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"
require "yaml"

class TestConfigPrune < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik-prune-test-")
    @temp_home = Dir.mktmpdir("rubik-home-test-")
  end

  def teardown
    FileUtils.remove_entry_secure(@temp_dir) if @temp_dir && File.directory?(@temp_dir)
    FileUtils.remove_entry_secure(@temp_home) if @temp_home && File.directory?(@temp_home)
  end

  def test_prune_empty_and_default_hashes
    assert_equal({}, Rubik::Config::Pruner.prune({}))
    assert_equal({}, Rubik::Config::Pruner.prune(Rubik::Config::DEFAULT_CONFIG))
  end

  def test_prune_retains_overrides_and_drops_defaults
    target = {
      "llm" => {
        "stream" => true, # default is true -> pruned
        "stream_timeout" => 90 # default is 60 -> kept
      },
      "repair" => {
        "max_attempts" => 7 # default is 3 -> kept
      }
    }

    pruned = Rubik::Config::Pruner.prune(target)
    expected = {
      "llm" => { "stream_timeout" => 90 },
      "repair" => { "max_attempts" => 7 }
    }
    assert_equal(expected, pruned)
  end

  def test_prune_handles_nil_defaults_correctly
    # In DEFAULT_CONFIG, "llm" -> "thinking_budget_ratio" is nil
    ref_default = Rubik::Config::DEFAULT_CONFIG["llm"]["thinking_budget_ratio"]
    assert_nil ref_default

    # Setting it to nil should prune it away
    target_nil = { "llm" => { "thinking_budget_ratio" => nil } }
    pruned_nil = Rubik::Config::Pruner.prune(target_nil)
    assert_equal({}, pruned_nil)

    # Setting it to a non-nil override should keep it
    target_override = { "llm" => { "thinking_budget_ratio" => 0.4 } }
    pruned_override = Rubik::Config::Pruner.prune(target_override)
    assert_equal({ "llm" => { "thinking_budget_ratio" => 0.4 } }, pruned_override)
  end

  def test_prune_preserves_custom_unmanaged_keys
    target = {
      "custom_plugin" => {
        "api_key" => "secret-token",
        "nested" => { "enabled" => true }
      }
    }

    pruned = Rubik::Config::Pruner.prune(target)
    assert_equal(target, pruned)
  end

  def test_disk_save_prunes_redundant_defaults_and_maintains_observational_equivalence
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    config.set("repair.max_attempts", 7, persist: :project)

    project_file = config.project_config_path
    assert File.exist?(project_file)

    # Verify disk content line count is minimal delta (not 200+ lines)
    raw_yaml = File.read(project_file)
    lines = raw_yaml.lines.map(&:strip).reject(&:empty?)
    assert lines.size <= 5, "Expected project config to contain only delta, got #{lines.size} lines: #{raw_yaml}"

    # Reload from disk into a fresh instance
    reloaded = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    assert_equal 7, reloaded.fetch("repair.max_attempts")
    # Inherited defaults must still be transparently accessible
    assert_equal true, reloaded.fetch("llm.stream")
    assert_equal 120, reloaded.fetch("llm.stream_timeout")
    assert_equal "qwen2.5-coder:7b", reloaded.fetch("model.name")
  end
end
