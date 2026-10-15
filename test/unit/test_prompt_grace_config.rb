# frozen_string_literal: true

require_relative "../test_helper"

class TestPromptGraceConfig < Minitest::Test
  KEY = "ui.prompt_grace_window_ms"

  def setup
    @root = Dir.mktmpdir
    @home = Dir.mktmpdir
    @config = Rubik::Config.new(root_dir: @root, home_dir: @home)
  end

  def teardown
    FileUtils.remove_entry(@root)
    FileUtils.remove_entry(@home)
  end

  def test_default_and_live_updates
    assert_equal 1000, @config.fetch(KEY)
    changes = []
    @config.on_change(KEY) { |*args| changes << args }
    [2000, 0, "1000"].each do |value|
      assert @config.set(KEY, value)[:ok]
      assert_equal value.to_i, @config.fetch(KEY)
    end
    assert_equal([2000, 0, 1000], changes.map { |change| change[1] })
  end

  def test_invalid_session_updates_are_atomic
    [-1, 1.5, "fast", nil, true].each do |value|
      error = assert_raises(ArgumentError) { @config.set(KEY, value) }
      assert_includes error.message, KEY
      assert_equal 1000, @config.fetch(KEY)
    end
  end

  def test_replacing_ui_section_validates_before_mutation
    error = assert_raises(ArgumentError) { @config.set("ui", { "prompt_grace_window_ms" => -1 }) }
    assert_includes error.message, KEY
    assert_equal 1000, @config.fetch(KEY)
  end

  def test_yaml_validation_and_persistence
    [0, 2000].each do |value|
      assert @config.set(KEY, value, persist: :project)[:ok]
      assert_equal value, Rubik::Config.new(root_dir: @root, home_dir: @home).fetch(KEY)
    end
    [-1, 0.5, "no", nil, false].each do |value|
      File.write(@config.project_config_path, YAML.dump("ui" => { "prompt_grace_window_ms" => value }))
      error = assert_raises(ArgumentError) { Rubik::Config.new(root_dir: @root, home_dir: @home) }
      assert_includes error.message, KEY
    end
  end
end
