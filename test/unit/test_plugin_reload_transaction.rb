# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/plugin"
require_relative "../../lib/rubik/runtime/manager"

# Issue #144: reload must be transactional. Discovery, whole-package
# integrity verification, and definition preparation happen BEFORE the
# running component is touched; an activation failure rolls the swap back
# and restores the previous version. These tests pin the lifecycle contract
# against a real Runtime::Manager: exactly one active version after every
# reload, LIFO inverses of the retired version, and no replacement traces
# (fiber / registry entry / side effects) after a failed rollback.
class TestPluginReloadTransaction < Minitest::Test
  PLUGIN = "pack_a"

  def setup
    Rubik::Plugin::Registry.clear!
    @tmp = Dir.mktmpdir("rubik_reload_tx")
    @storage = Rubik::Plugin::Storage.new(root_dir: @tmp, home_dir: File.join(@tmp, "home"))
    @manager = Rubik::Plugin::Manager.new(logger: Logger.new(StringIO.new))
    @runtime = Rubik::Runtime::Manager.new
    @log = []
    @runtime.provide(:test_log, @log)
    @seq = 0
    ENV["RUBIK_TRUST_OVERLAYS"] = nil
  end

  def teardown
    @runtime.dispose!
    remove_temp_dir(@tmp) if @tmp && File.directory?(@tmp)
    Rubik::Plugin::Registry.clear!
    ENV["RUBIK_TRUST_OVERLAYS"] = nil
  end

  def write_source(name, entry_body, helpers: {})
    @seq += 1
    dir = File.join(@tmp, "staging_#{@seq}", name)
    FileUtils.mkdir_p(File.join(dir, "lib"))
    File.write(File.join(dir, "lib", "#{name}.rb"), entry_body)
    helpers.each do |rel, body|
      path = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end
    dir
  end

  def install(name, entry_body, helpers: {})
    res = @storage.add_plugin(write_source(name, entry_body, helpers: helpers), scope: :project)
    assert res[:ok], res[:error]
    res
  end

  def discovered(name)
    @storage.discover_plugins(scope: :project).find { |p| p[:name] == name }
  end

  def load_now(name)
    @manager.load_plugin_file(discovered(name), runtime_manager: @runtime)
  end

  def reload(name)
    @manager.reload_plugin(name, storage: @storage, runtime_manager: @runtime)
  end

  def fiber_state(name)
    @runtime.fibers["plugin_#{name}"]&.state
  end

  def valid_body(name, version, tag)
    <<~RUBY
      Rubik.plugin(:#{name}, version: "#{version}", inject: [:test_log]) do |ctx|
        log = ctx.require(:test_log)
        log << "#{tag}-init"
        ctx.on_dispose { log << "#{tag}-dispose" }
      end
    RUBY
  end

  def broken_body(name, version, tag)
    <<~RUBY
      Rubik.plugin(:#{name}, version: "#{version}", inject: [:test_log]) do |ctx|
        log = ctx.require(:test_log)
        log << "#{tag}-init"
        ctx.on_dispose { log << "#{tag}-dispose" }
        raise "activation boom (#{tag})"
      end
    RUBY
  end

  def test_helper_drift_blocks_reload_before_unload
    install(PLUGIN, valid_body(PLUGIN, "1.0.0", "a1"), helpers: { "lib/helper.rb" => "V = 1" })
    assert load_now(PLUGIN)
    assert_equal :active, fiber_state(PLUGIN)
    assert_equal ["a1-init"], @log

    # Helper drift is package drift: the replacement is never activated and
    # the old version is never unloaded.
    installed = discovered(PLUGIN)
    File.write(File.join(installed[:dir], "lib", "helper.rb"), "V = 2")

    refute reload(PLUGIN)
    assert_equal :active, fiber_state(PLUGIN)
    assert_equal ["a1-init"], @log, "old version must keep running untouched"
    assert_equal "1.0.0", Rubik::Plugin::Registry.get(PLUGIN).version
  end

  def test_missing_replacement_keeps_old_version
    install(PLUGIN, valid_body(PLUGIN, "1.0.0", "a1"))
    assert load_now(PLUGIN)

    assert @storage.remove_plugin(PLUGIN, scope: :project)[:ok]
    refute reload(PLUGIN)
    assert_equal :active, fiber_state(PLUGIN)
    assert_equal ["a1-init"], @log
  end

  def test_syntax_error_replacement_fails_prepare_and_keeps_old
    install(PLUGIN, valid_body(PLUGIN, "1.0.0", "a1"))
    assert load_now(PLUGIN)

    # Re-consent a syntactically broken replacement: integrity passes, the
    # prepare phase (real `load`) fails, and the running version survives.
    install(PLUGIN, "Rubik.plugin(:#{PLUGIN}) do |ctx|\n")

    refute reload(PLUGIN)
    assert_equal :active, fiber_state(PLUGIN)
    assert_equal ["a1-init"], @log
    assert_equal "1.0.0", Rubik::Plugin::Registry.get(PLUGIN).version
  end

  def test_activation_error_rolls_back_to_previous_version
    install(PLUGIN, valid_body(PLUGIN, "1.0.0", "a1"))
    assert load_now(PLUGIN)

    install(PLUGIN, broken_body(PLUGIN, "2.0.0", "a2"))
    refute reload(PLUGIN)

    # The failed replacement's partial inverse ran (LIFO inside its own
    # context), the old version's inverse ran once, and the old version was
    # re-activated — so subsequent calls hit the old version only.
    assert_equal ["a1-init", "a1-dispose", "a2-init", "a2-dispose", "a1-init"], @log
    assert_equal :active, fiber_state(PLUGIN)
    assert_equal "1.0.0", Rubik::Plugin::Registry.get(PLUGIN).version
    assert_equal 1, @manager.registered_plugins.count(PLUGIN)
    active_versions = @runtime.active_fibers.count { |f| f.name == "plugin_#{PLUGIN}" }
    assert_equal 1, active_versions
  end

  def test_activation_error_without_previous_version_leaves_no_trace
    install(PLUGIN, broken_body(PLUGIN, "2.0.0", "a2"))
    refute reload(PLUGIN)

    assert_equal ["a2-init", "a2-dispose"], @log
    assert_nil fiber_state(PLUGIN)
    assert_nil Rubik::Plugin::Registry.get(PLUGIN)
    assert_empty @manager.registered_plugins
  end

  def test_repeated_reload_keeps_single_active_version_and_lifo_inverses
    install(PLUGIN, valid_body(PLUGIN, "1.0.0", "a1"))
    assert load_now(PLUGIN)

    [["2.0.0", "a2"], ["3.0.0", "a3"]].each do |version, tag|
      install(PLUGIN, valid_body(PLUGIN, version, tag))
      assert reload(PLUGIN), "reload to #{version} must succeed"
      assert_equal :active, fiber_state(PLUGIN)
      assert_equal version, Rubik::Plugin::Registry.get(PLUGIN).version
      assert_equal 1, @runtime.active_fibers.count { |f| f.name == "plugin_#{PLUGIN}" },
                   "exactly one active version after reload #{version}"
      assert_equal 1, @manager.registered_plugins.count(PLUGIN)
    end

    assert_equal ["a1-init", "a1-dispose", "a2-init", "a2-dispose", "a3-init"], @log
    load_path = discovered(PLUGIN)[:load_path]
    assert_equal 1, $LOAD_PATH.count(load_path), "load-path refcount must not leak across reloads"
  end

  def test_reload_of_unloaded_plugin_loads_and_activates_it
    install(PLUGIN, valid_body(PLUGIN, "1.0.0", "a1"))
    assert reload(PLUGIN)
    assert_equal :active, fiber_state(PLUGIN)
    assert_equal ["a1-init"], @log
  end

  def test_pending_unload_and_reactivation_release_load_path_claims
    body = valid_body(PLUGIN, "1.0.0", "a1").sub("inject: [:test_log]", "inject: [:test_log, :late_service]")
    install(PLUGIN, body)
    load_path = discovered(PLUGIN)[:load_path]
    assert load_now(PLUGIN)
    assert_equal :pending, fiber_state(PLUGIN)
    refute_includes $LOAD_PATH, load_path
    assert @manager.unload_plugin(PLUGIN, runtime_manager: @runtime)
    refute_includes $LOAD_PATH, load_path

    assert load_now(PLUGIN)
    @runtime.provide(:late_service, Object.new)
    assert_equal :active, fiber_state(PLUGIN)
    assert_includes $LOAD_PATH, load_path
    @runtime.unprovide(:late_service)
    refute_includes $LOAD_PATH, load_path
    @runtime.provide(:late_service, Object.new)
    assert_includes $LOAD_PATH, load_path
    assert @manager.unload_plugin(PLUGIN, runtime_manager: @runtime)
    refute_includes $LOAD_PATH, load_path
    assert_empty @manager.instance_variable_get(:@load_path_refs)
  end

  def test_reload_result_propagates_to_repl_output
    install(PLUGIN, broken_body(PLUGIN, "2.0.0", "a2"))
    ctx = Struct.new(:out, :runtime_manager).new(StringIO.new, @runtime)
    Rubik::REPL::Commands::Plugins.reload_plugin(ctx, @manager, @storage, PLUGIN)
    assert_includes ctx.out.string, "❌ Hata"

    install(PLUGIN, valid_body(PLUGIN, "3.0.0", "a3"))
    ctx = Struct.new(:out, :runtime_manager).new(StringIO.new, @runtime)
    Rubik::REPL::Commands::Plugins.reload_plugin(ctx, @manager, @storage, PLUGIN)
    assert_includes ctx.out.string, "başarıyla yeniden yüklendi"
  end

  def test_load_plugin_file_with_broken_replacement_does_not_destroy_running_plugin
    # Issue #309: re-adding/loading a broken replacement must not brick the live plugin
    install(PLUGIN, valid_body(PLUGIN, "1.0.0", "a1"))
    assert load_now(PLUGIN)
    assert_equal :active, fiber_state(PLUGIN)
    assert_equal "1.0.0", Rubik::Plugin::Registry.get(PLUGIN).version

    # Now create a broken syntax file
    broken_dir = write_source(PLUGIN, "def syntax_error_in_plugin(;;; end")
    broken_meta = {
      name: PLUGIN,
      path: File.join(broken_dir, "lib", "#{PLUGIN}.rb"),
      scope: :project,
      type: :directory,
      load_path: File.join(broken_dir, "lib")
    }

    refute @manager.load_plugin_file(broken_meta, runtime_manager: @runtime)
    assert_equal :active, fiber_state(PLUGIN), "Old fiber must remain active after failed load_plugin_file"
    assert_equal "1.0.0", Rubik::Plugin::Registry.get(PLUGIN).version
  end

  def test_reload_plugin_when_new_version_is_pending_rolls_back_to_active
    # Issue #310: new version stuck in :pending when old was :active must roll back
    install(PLUGIN, valid_body(PLUGIN, "1.0.0", "a1"))
    assert load_now(PLUGIN)
    assert_equal :active, fiber_state(PLUGIN)

    unsatisfied_body = <<~RUBY
      Rubik.plugin(:#{PLUGIN}, version: "2.0.0", requires: [:missing_service_never_satisfied]) do |ctx|
        ctx.require(:missing_service_never_satisfied)
      end
    RUBY
    install(PLUGIN, unsatisfied_body)

    refute reload(PLUGIN), "Reloading into an unsatisfied coeffect version must fail and roll back"
    assert_equal :active, fiber_state(PLUGIN), "Old version must be restored to active"
    assert_equal "1.0.0", Rubik::Plugin::Registry.get(PLUGIN).version
  end
end
