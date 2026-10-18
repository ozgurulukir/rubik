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
    @extra_plugin_paths = []
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
    @extra_plugin_paths.each { |p| FileUtils.rm_f(p) }
    Rubik::Plugin::Registry.clear!
  end

  def write_plugin(name, code)
    path = File.join(Dir.pwd, "#{name}.rb")
    File.write(path, code)
    @extra_plugin_paths << path
    { name: name, path: path, load_path: Dir.pwd }
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

  # Documented plugin contract (docs/explanation/self-evolution.md §3.C): a plugin declares
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

  # ── Plan 86 D-3: requires: DAG bildirimi ─────────────────────────────

  def test_dsl_stores_requires_and_defaults_to_empty
    meta = { name: "dummy_plugin", path: @tmp_plugin_path, load_path: Dir.pwd }
    @manager.load_plugin_file(meta, runtime_manager: @runtime)
    assert_equal [], Rubik::Plugin::Registry.get("dummy_plugin").requires

    write_plugin("req_plugin", <<~RUBY)
      Rubik.plugin(:req_plugin, requires: ["tool_registry", :shell]) { |_ctx| true }
    RUBY
    @manager.load_plugin_file({ name: "req_plugin", path: File.join(Dir.pwd, "req_plugin.rb"), load_path: Dir.pwd },
                              runtime_manager: @runtime)
    definition = Rubik::Plugin::Registry.get("req_plugin")
    refute_nil definition
    assert_equal ["tool_registry", :shell], definition.requires
  ensure
    Rubik::Plugin::Registry.definitions.delete("req_plugin")
  end

  def test_cyclic_requires_rejects_second_plugin_load
    @manager.load_plugin_file(
      write_plugin("plug_a", "Rubik.plugin(:plug_a, requires: ['plug_b']) { |_ctx| true }"),
      runtime_manager: @runtime
    )
    assert @runtime.fibers["plugin_plug_a"], "plugin A must register (cycle not yet closed)"

    result = @manager.load_plugin_file(
      write_plugin("plug_b", "Rubik.plugin(:plug_b, requires: ['plug_a']) { |_ctx| true }"),
      runtime_manager: @runtime
    )

    refute result, "closing the requires: cycle must reject the load"
    assert_nil @runtime.fibers["plugin_plug_b"]
    assert_nil Rubik::Plugin::Registry.get("plug_b")
  end

  def test_acyclic_requires_chain_and_external_coeffects_load_fine
    @manager.load_plugin_file(
      write_plugin("plug_leaf", "Rubik.plugin(:plug_leaf) { |_ctx| true }"),
      runtime_manager: @runtime
    )
    @manager.load_plugin_file(
      write_plugin("plug_mid", "Rubik.plugin(:plug_mid, requires: ['plug_leaf', :shell]) { |_ctx| true }"),
      runtime_manager: @runtime
    )

    assert @runtime.fibers["plugin_plug_leaf"]
    assert @runtime.fibers["plugin_plug_mid"], "acyclic chain + external coeffect (:shell) must load"
  end

  def test_direct_self_cycle_rejected
    result = @manager.load_plugin_file(
      write_plugin("plug_self", "Rubik.plugin(:plug_self, requires: ['plug_self']) { |_ctx| true }"),
      runtime_manager: @runtime
    )

    refute result, "a self-referential requires: must be rejected"
    assert_nil @runtime.fibers["plugin_plug_self"]
  end
end
