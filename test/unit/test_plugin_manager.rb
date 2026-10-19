# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestPluginManager < Minitest::Test
  def setup
    @log_output = StringIO.new
    @logger = Logger.new(@log_output)
    @manager = Rubik::Plugin::Manager.new(logger: @logger)
  end

  def test_alias_resolution_and_circular_alias_prevention
    @manager.register_alias("rt", "!test")
    assert_equal "test", @manager.resolve_alias("rt")

    # Attempt circular alias rt -> !test and !test -> rt
    refute @manager.register_alias("!test", "rt")
  end

  def test_alias_normalization_and_mixed_case
    @manager.register_alias("!MyCmd", "!TARGET_CMD")
    assert_equal "target_cmd", @manager.resolve_alias("mycmd")
    assert_equal "target_cmd", @manager.resolve_alias("!mycmd")
  end

  def test_alias_chain_length_exceeded
    @manager.register_alias("a1", "a2")
    @manager.register_alias("a2", "a3")
    @manager.register_alias("a3", "a4")
    @manager.register_alias("a4", "a5")
    @manager.register_alias("a5", "a6")
    @manager.register_alias("a6", "a7")
    @manager.register_alias("a7", "a8")
    @manager.register_alias("a8", "a9")
    @manager.register_alias("a9", "a10")

    # 8'den uzun zincirde uyarip sonlandirmali
    # The chain will go: a1 -> a2 -> a3 -> a4 -> a5 -> a6 -> a7 -> a8 -> a9
    # a9 is the 8th visited node. The limit is 8.
    result = @manager.resolve_alias("a1")
    assert_equal "a9", result
  end

  def test_load_plugin_gem_handles_load_failure_gracefully
    success = @manager.load_plugin_gem("non_existent_plugin_xyz_123")
    refute success
    refute_includes @manager.registered_plugins, "non_existent_plugin_xyz_123"
  end

  def test_load_example_plugin_from_fixture_path
    $:.unshift File.expand_path("../fixtures/plugins/rubik-plugin-example/lib", __dir__)
    success = @manager.load_plugin_gem("rubik-plugin-example")

    assert success
    assert_includes @manager.registered_plugins, "rubik-plugin-example"
  end

  def test_load_plugin_with_runtime_manager
    $:.unshift File.expand_path("../fixtures/plugins/rubik-plugin-example/lib", __dir__)
    runtime_manager = Rubik::Runtime::Manager.new

    success = @manager.load_plugin_gem("rubik-plugin-example", runtime_manager: runtime_manager)

    assert success
    assert_includes @manager.registered_plugins, "rubik-plugin-example"
    assert runtime_manager.fibers.key?("plugin_rubik-plugin-example")
  end

  def test_load_plugin_with_runtime_manager_handles_failure
    runtime_manager = Rubik::Runtime::Manager.new

    # Should catch LoadError inside the component block and fail the component
    success = @manager.load_plugin_gem("non_existent_plugin_abc", runtime_manager: runtime_manager)

    assert success # The registration method itself returns true, the failure happens when the fiber runs

    # Check component state
    fiber = runtime_manager.fibers["plugin_non_existent_plugin_abc"]
    assert fiber
    assert_equal :failed, fiber.state
  end

  def test_empty_or_nil_alias_rejected
    refute @manager.register_alias("", "test")
    refute @manager.register_alias("rt", "")
    refute @manager.register_alias("!", "test")
  end

  def test_dispose_cleans_up_registered_plugins
    $:.unshift File.expand_path("../fixtures/plugins/rubik-plugin-example/lib", __dir__)
    runtime_manager = Rubik::Runtime::Manager.new
    @manager.load_plugin_gem("rubik-plugin-example", runtime_manager: runtime_manager)

    assert_includes @manager.registered_plugins, "rubik-plugin-example"
    runtime_manager.unregister_component("plugin_rubik-plugin-example")
    refute_includes @manager.registered_plugins, "rubik-plugin-example"
  end
end
