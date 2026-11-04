# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"

class TestConfigLayers < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik-layers-root-")
    @temp_home = Dir.mktmpdir("rubik-layers-home-")
  end

  def teardown
    FileUtils.remove_entry_secure(@temp_root) if @temp_root && File.directory?(@temp_root)
    FileUtils.remove_entry_secure(@temp_home) if @temp_home && File.directory?(@temp_home)
  end

  def test_layer_isolation_and_no_cross_scope_bleed
    config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)

    # 1. Mutate Project Layer
    config.set("project_only_key", "project_val", persist: :project)
    assert_equal "project_val", config.fetch("project_only_key")
    assert_equal "project_val", config.project_layer["project_only_key"]
    assert_nil config.global_layer["project_only_key"]

    # 2. Mutate Global Layer
    config.set("global_only_key", "global_val", persist: :global)
    assert_equal "global_val", config.fetch("global_only_key")
    assert_equal "global_val", config.global_layer["global_only_key"]
    assert_nil config.project_layer["global_only_key"]

    # 3. Verify Disk Files
    project_store = config.store_for(:project)
    global_store = config.store_for(:global)

    project_store.transaction(true) do
      assert_equal "project_val", project_store["project_only_key"]
      assert_nil project_store["global_only_key"]
    end

    global_store.transaction(true) do
      assert_equal "global_val", global_store["global_only_key"]
      assert_nil global_store["project_only_key"]
    end
  end

  def test_layer_precedence_hierarchy
    # Set default is 3 for repair.max_attempts
    config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    assert_equal 3, config.fetch("repair.max_attempts")

    # Global override (Layer 1) -> 4
    config.set("repair.max_attempts", 4, persist: :global)
    assert_equal 4, config.fetch("repair.max_attempts")

    # Project override (Layer 2) -> 5
    config.set("repair.max_attempts", 5, persist: :project)
    assert_equal 5, config.fetch("repair.max_attempts")

    # Session override (Layer 4) -> 6
    config.set("repair.max_attempts", 6, persist: nil)
    assert_equal 6, config.fetch("repair.max_attempts")

    # Deleting session override should fall back to project layer (5)
    config.delete("repair.max_attempts", persist: nil)
    assert_equal 5, config.fetch("repair.max_attempts")

    # Deleting project override should fall back to global layer (4)
    config.delete("repair.max_attempts", persist: :project)
    assert_equal 4, config.fetch("repair.max_attempts")

    # Deleting global override should fall back to defaults layer (3)
    config.delete("repair.max_attempts", persist: :global)
    assert_equal 3, config.fetch("repair.max_attempts")
  end
end
