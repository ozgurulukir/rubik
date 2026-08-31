# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../../lib/rubik/plugin/storage"

class TestPluginStorage < Minitest::Test
  def setup
    @tmp_root = Dir.mktmpdir
    @tmp_home = Dir.mktmpdir
    ENV["RUBIK_TRUST_OVERLAYS"] = nil
    @storage = Rubik::Plugin::Storage.new(root_dir: @tmp_root, home_dir: @tmp_home)
  end

  def teardown
    FileUtils.rm_rf(@tmp_root)
    FileUtils.rm_rf(@tmp_home)
  end

  def test_ensure_directories
    assert Dir.exist?(@storage.project_plugins_dir)
    assert Dir.exist?(@storage.global_plugins_dir)
  end

  def test_add_and_remove_file_plugin
    dummy_plugin = File.join(@tmp_root, "my_plugin.rb")
    File.write(dummy_plugin, "puts 'hello'")

    res = @storage.add_plugin(dummy_plugin, scope: :project)
    assert res[:ok]
    assert_equal "my_plugin", res[:name]

    plugins = @storage.discover_plugins(scope: :project)
    assert_equal 1, plugins.size
    assert_equal "my_plugin", plugins.first[:name]

    assert_equal :verified, @storage.verify_integrity(res[:path], scope: :project)

    # Tampering test
    File.write(res[:path], "puts 'hacked'")
    assert_equal :rejected, @storage.verify_integrity(res[:path], scope: :project)

    # Trust overlays test
    ENV["RUBIK_TRUST_OVERLAYS"] = "1"
    assert_equal :trusted, @storage.verify_integrity(res[:path], scope: :project)
    ENV["RUBIK_TRUST_OVERLAYS"] = nil

    res = @storage.remove_plugin("my_plugin", scope: :project)
    assert res[:ok]
    assert_empty @storage.discover_plugins(scope: :project)
  end

  def test_add_and_remove_directory_plugin
    dummy_dir = File.join(@tmp_root, "my_pack")
    FileUtils.mkdir_p(File.join(dummy_dir, "lib"))
    File.write(File.join(dummy_dir, "lib", "my_pack.rb"), "puts 'pack'")

    res = @storage.add_plugin(dummy_dir, scope: :global)
    assert res[:ok]
    assert_equal "my_pack", res[:name]
    assert_equal :directory, res[:type]

    plugins = @storage.discover_plugins(scope: :global)
    assert_equal 1, plugins.size
    assert_equal "my_pack", plugins.first[:name]

    res = @storage.remove_plugin("my_pack", scope: :global)
    assert res[:ok]
    assert_empty @storage.discover_plugins(scope: :global)
  end
end
