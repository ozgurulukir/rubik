# frozen_string_literal: true

require_relative "../test_helper"

class TestPluginManager < Minitest::Test
  def setup
    @manager = Rubik::Plugin::Manager.new
  end

  def test_alias_resolution_and_circular_alias_prevention
    @manager.register_alias("rt", "!test")
    assert_equal "!test", @manager.resolve_alias("rt")

    # Attempt circular alias rt -> !test and !test -> rt
    refute @manager.register_alias("!test", "rt")
  end

  def test_load_plugin_gem_handles_load_failure_gracefully
    success = @manager.load_plugin_gem("non_existent_plugin_xyz_123")
    refute success
    refute_includes @manager.registered_plugins, "non_existent_plugin_xyz_123"
  end

  def test_load_example_plugin_from_fixture_path
    $LOAD_PATH.unshift File.expand_path("../fixtures/plugins/rubik-plugin-example/lib", __dir__)
    success = @manager.load_plugin_gem("rubik-plugin-example")

    assert success
    assert_includes @manager.registered_plugins, "rubik-plugin-example"
  end
end
