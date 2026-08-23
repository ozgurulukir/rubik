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

    assert config.warnings.any? { |w| w.include?("Cannot load config because") }
    assert_equal "ollama", config.fetch("model.provider")
  end

  def test_unknown_key_produces_warning
    File.write(File.join(@temp_dir, "rubik.yml"), YAML.dump("unknown_setting" => "val"))
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)

    assert config.warnings.any? { |w| w.include?("Unknown config key: unknown_setting") }
  end
end
