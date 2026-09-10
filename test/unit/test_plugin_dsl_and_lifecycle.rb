# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/rubik/plugin"
require_relative "../../lib/rubik/runtime/manager"
require_relative "../../lib/rubik/runtime/context"

class TestPluginDslAndLifecycle < Minitest::Test
  def setup
    Rubik::Plugin::Registry.clear!
    @runtime = Rubik::Runtime::Manager.new
    @manager = Rubik::Plugin::Manager.new

    @tmp_plugin_path = File.join(Dir.pwd, "dummy_plugin.rb")
    File.write(@tmp_plugin_path, <<~RUBY)
      Rubik.plugin(:dummy_plugin, version: "1.0.0", inject: [:test_dep]) do |ctx|
        dep = ctx.require(:test_dep)
        dep << "init"
        ctx.on_dispose { dep << "dispose" }
      end
    RUBY
  end

  def teardown
    FileUtils.rm_f(@tmp_plugin_path)
    Rubik::Plugin::Registry.clear!
  end

  def test_dsl_and_lifecycle
    # Simulate loading plugin file
    meta = { name: "dummy_plugin", path: @tmp_plugin_path, load_path: Dir.pwd }
    @manager.load_plugin_file(meta, runtime_manager: @runtime)

    fiber = @runtime.fibers["plugin_dummy_plugin"]
    refute_nil fiber
    assert_equal :pending, fiber.state

    # Provide dependency
    log = []
    @runtime.provide(:test_dep, log)

    assert_equal :active, fiber.state
    assert_equal ["init"], log

    # Unload
    @manager.unload_plugin("dummy_plugin", runtime_manager: @runtime)
    assert_nil @runtime.fibers["plugin_dummy_plugin"]
    assert_equal ["init", "dispose"], log
  end

  # Documented plugin contract (SELF_EVOLUTION.md §3.C): a plugin declares
  # inject: [:tools] and requires :tools, while the runtime publishes only
  # the canonical :tool_registry key (Rubik::Coeffects SSOT bridge).
  def test_plugin_with_legacy_tools_inject_activates_on_canonical_provide
    File.write(@tmp_plugin_path, <<~RUBY)
      Rubik.plugin(:legacy_tools_plugin, version: "1.0.0", inject: [:tools, :shell]) do |ctx|
        tools = ctx.require(:tools)
        shell = ctx.require(:shell)
        ctx.on_dispose { shell << "dispose" }
        tools << "init"
      end
    RUBY

    meta = { name: "legacy_tools_plugin", path: @tmp_plugin_path, load_path: Dir.pwd }
    @manager.load_plugin_file(meta, runtime_manager: @runtime)

    fiber = @runtime.fibers["plugin_legacy_tools_plugin"]
    refute_nil fiber
    assert_equal :pending, fiber.state

    log = []
    shell_log = []
    @runtime.provide(:tool_registry, log) # canonical key only — no :tools alias
    @runtime.provide(:shell, shell_log)

    assert_equal :active, fiber.state
    assert_equal ["init"], log

    @manager.unload_plugin("legacy_tools_plugin", runtime_manager: @runtime)
    assert_equal ["dispose"], shell_log
  end
end
