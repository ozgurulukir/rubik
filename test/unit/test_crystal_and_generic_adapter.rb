# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/adapter/crystal"
require_relative "../../lib/rubik/adapter/generic"
require_relative "../../lib/rubik/adapter/registry"
require_relative "../../lib/rubik/tools/builtins/exec"
require_relative "../../lib/rubik/tools/builtins/lifecycle"
require_relative "../../lib/rubik/config"
require_relative "../../lib/rubik/runtime/manager"

class TestCrystalAndGenericAdapter < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("rubik_adapter_test")
    @config = Rubik::Config.new(root_dir: @tmpdir, home_dir: @tmpdir)
  end

  def teardown
    remove_temp_dir(@tmpdir)
  end

  # =========================================================================
  # 1. CrystalAdapter Unit Tests
  # =========================================================================

  def test_crystal_adapter_attributes_and_defaults
    adapter = Rubik::Adapter::CrystalAdapter.new
    assert_equal "crystal", adapter.name
    assert_equal "crystal", adapter.binary_name
    assert_equal "crystal spec", adapter.send(:default_test_cmd)
    assert_equal "crystal tool format app.cr", adapter.send(:default_format_cmd, "app.cr")
  end

  def test_crystal_adapter_registered_in_registry
    registry = Rubik::Adapter::Registry.new
    adapter = registry.get("crystal")
    assert_kind_of Rubik::Adapter::CrystalAdapter, adapter
    assert_equal "crystal", adapter.name
  end

  def test_crystal_in_discovery_constants
    assert_includes Rubik::Runtime::Discovery::FORMATTER_CANDIDATES["crystal"], "crystal tool format"
    assert_equal "crystal spec", Rubik::Runtime::Discovery::DEFAULT_TEST_RUNNERS["crystal"]
    markers = Rubik::Runtime::Discovery::TEST_RUNNER_MARKERS["crystal"]
    assert(markers.any? { |m| m[:marker] == "shard.yml" && m[:candidates].include?("crystal spec") })
    assert(markers.any? { |m| m[:marker] == "shard.lock" && m[:candidates].include?("crystal spec") })
  end

  def test_crystal_discovery_with_shard_yml
    File.write(File.join(@tmpdir, "shard.yml"), "name: my_shard\n")
    candidates = Rubik::Runtime::Discovery.test_runner_candidates("crystal", root_dir: @tmpdir)
    assert_includes candidates, "crystal spec"
  end

  def test_crystal_compile_selection
    adapter = Rubik::Adapter::CrystalAdapter.new
    shard_yml_path = File.join(@tmpdir, "shard.yml")

    # Stub available? to true for testing compile selection
    adapter.stub :available?, true do
      Rubik::Adapter::ProcessRunner.stub :run, ->(cmd, **kwargs) { { ok: true, cmd: cmd, chdir: kwargs[:chdir] } } do
        # When shard.yml exists (mocking File.exist?)
        exist_stub = ->(path) { path == shard_yml_path ? true : File.method(:exist?).call(path) }
        File.stub :exist?, exist_stub do
          res = adapter.compile(@tmpdir)
          assert_equal "shards build", res[:cmd]
          assert_equal @tmpdir, res[:chdir]
        end

        # When shard.yml does not exist (fallback to crystal build, mocking File.exist?)
        no_exist_stub = ->(path) { path == shard_yml_path ? false : File.method(:exist?).call(path) }
        File.stub :exist?, no_exist_stub do
          res = adapter.compile(@tmpdir)
          assert_equal "crystal build", res[:cmd]
          assert_equal @tmpdir, res[:chdir]
        end
      end
    end
  end

  def test_crystal_compile_when_unavailable
    adapter = Rubik::Adapter::CrystalAdapter.new
    adapter.stub :available?, false do
      res = adapter.compile(@tmpdir)
      refute res[:ok]
      assert_equal 127, res[:exit_code]
      assert_includes res[:output], "crystal is unavailable"
    end
  end

  def test_crystal_check_syntax_command
    adapter = Rubik::Adapter::CrystalAdapter.new
    adapter.stub :available?, true do
      Rubik::Adapter::ProcessRunner.stub :run, ->(cmd) { { ok: true, cmd: cmd } } do
        res = adapter.check_syntax(File.join(@tmpdir, "main.cr"))
        assert_includes res[:cmd], "crystal build --no-codegen"
        assert_includes res[:cmd], "main.cr"
      end
    end
  end

  def test_crystal_unavailable_when_binary_missing
    adapter = Rubik::Adapter::CrystalAdapter.new
    Rubik::Platform.stub :which, nil do
      refute adapter.available?
      res = adapter.run_tests(@tmpdir)
      refute res[:ok]
      assert_equal 127, res[:exit_code]
      assert_includes res[:output], "crystal is unavailable"
    end
  end

  # =========================================================================
  # 2. GenericAdapter Unit Tests
  # =========================================================================

  def test_generic_adapter_initialization_and_derivation
    # Plan 111 F1: fixture binaries are database-less — allowlist them.
    adapter = Rubik::Adapter::GenericAdapter.new(
      "elixir", test_cmd: "mix test", format_cmd: "mix format",
                guard: Rubik::Security::Guard.new(audit_log_path: nil, command_allowlist: ["mix"])
    )
    assert_equal "elixir", adapter.name
    assert_equal "mix", adapter.binary_name
    assert_equal "mix test", adapter.resolve_test_cmd(@tmpdir)
    assert_equal "mix format foo.ex", adapter.resolve_format_cmd("foo.ex")
  end

  def test_generic_adapter_syntax_check
    adapter = Rubik::Adapter::GenericAdapter.new(
      "custom", test_cmd: "custom test",
                guard: Rubik::Security::Guard.new(audit_log_path: nil, command_allowlist: ["custom"])
    )
    # Without custom syntax cmd
    adapter.stub :available?, true do
      res1 = adapter.check_syntax("foo.txt")
      assert res1[:ok]
      assert_includes res1[:output], "Syntax check not configured"

      # With custom syntax cmd
      adapter.custom_syntax_cmd = "custom lint --check"
      Rubik::Adapter::ProcessRunner.stub :run, ->(cmd) { { ok: true, cmd: cmd } } do
        res2 = adapter.check_syntax("foo.txt")
        assert_equal "custom lint --check foo.txt", res2[:cmd]
      end
    end
  end

  # =========================================================================
  # 3. RepairRuntimeTool Dynamic Synthesis Tests
  # =========================================================================

  def test_repair_runtime_tool_synthesizes_generic_adapter_for_test_runner
    registry = Rubik::Adapter::Registry.new
    runtime_mgr = Rubik::Runtime::Manager.new
    tool = Rubik::Tools::RepairRuntimeTool.new(
      runtime_manager: runtime_mgr,
      adapter_registry: registry,
      config: @config,
      root_dir: @tmpdir,
      guard: Rubik::Security::Guard.new(audit_log_path: nil, command_allowlist: ["mix"])
    )

    # Elixir has no builtin adapter
    assert_nil registry.get("elixir")

    Rubik::Runtime::Discovery.stub :binary_available?, true do
      res = tool.execute(target: "test_runner", language_or_type: "elixir", proposed_command: "mix test")
      refute res.respond_to?(:error?) && res.error?
      assert_includes res.to_s, "Successfully verified and promoted"

      adapter = registry.get("elixir")
      refute_nil adapter
      assert_kind_of Rubik::Adapter::GenericAdapter, adapter
      assert_equal "mix test", adapter.custom_test_cmd
      assert_equal "mix test", @config.fetch("test.runners.elixir")
      assert_equal "mix test", runtime_mgr.context.require("runner:elixir")
    end
  end

  def test_repair_runtime_tool_synthesizes_generic_adapter_for_linter
    registry = Rubik::Adapter::Registry.new
    runtime_mgr = Rubik::Runtime::Manager.new
    tool = Rubik::Tools::RepairRuntimeTool.new(
      runtime_manager: runtime_mgr,
      adapter_registry: registry,
      config: @config,
      root_dir: @tmpdir,
      guard: Rubik::Security::Guard.new(audit_log_path: nil, command_allowlist: ["dart"])
    )

    assert_nil registry.get("dart")

    Rubik::Runtime::Discovery.stub :binary_available?, true do
      res = tool.execute(target: "linter", language_or_type: "dart", proposed_command: "dart format")
      refute res.respond_to?(:error?) && res.error?

      adapter = registry.get("dart")
      refute_nil adapter
      assert_kind_of Rubik::Adapter::GenericAdapter, adapter
      assert_equal "dart format", adapter.custom_format_cmd
      assert_equal "dart format", @config.fetch("linter.commands.dart")
      assert_equal "dart format", runtime_mgr.context.require("linter:dart")
    end
  end

  # =========================================================================
  # 4. RunTestsTool JIT Self-Healing & Elm Error Guidance
  # =========================================================================

  def test_run_tests_tool_jit_synthesizes_adapter_from_config
    registry = Rubik::Adapter::Registry.new
    @config.set("test.runners.haskell", "cabal test")

    tool = Rubik::Tools::RunTestsTool.new(
      registry, root_dir: @tmpdir, config: @config,
                guard: Rubik::Security::Guard.new(audit_log_path: nil, command_allowlist: ["cabal"])
    )

    assert_nil registry.get("haskell")

    Rubik::Adapter::ProcessRunner.stub :run, ->(cmd, **_kwargs) { { ok: true, output: "All tests passed", duration: 0.1, exit_code: 0, cmd: cmd } } do
      Rubik::Platform.stub :which, "/usr/bin/cabal" do
        res = tool.execute(language: "haskell")
        assert_includes res, "Test run [PASSED]"
        assert_includes res, "All tests passed"

        # Adapter was synthesized and registered in registry JIT
        adapter = registry.get("haskell")
        refute_nil adapter
        assert_kind_of Rubik::Adapter::GenericAdapter, adapter
        assert_equal "cabal test", adapter.custom_test_cmd
      end
    end
  end

  def test_run_tests_tool_jit_synthesizes_adapter_from_discovery
    registry = Rubik::Adapter::Registry.new
    # Remove crystal from registry to test JIT discovery synthesis
    registry.unregister("crystal")
    assert_nil registry.get("crystal")

    File.write(File.join(@tmpdir, "shard.yml"), "name: test_app\n")

    # Plan 111 F1: `crystal spec` is database-less and fail-closed at the
    # command gate — the fixture plays the operator allowlisting the runner.
    tool = Rubik::Tools::RunTestsTool.new(
      registry, root_dir: @tmpdir, config: @config,
                guard: Rubik::Security::Guard.new(audit_log_path: nil, command_allowlist: ["crystal"])
    )

    Rubik::Adapter::ProcessRunner.stub :run, ->(cmd, **_kwargs) { { ok: true, output: "3 specs, 0 failures", duration: 0.2, exit_code: 0, cmd: cmd } } do
      Rubik::Runtime::Discovery.stub :binary_available?, true do
        Rubik::Platform.stub :which, "/usr/bin/crystal" do
          res = tool.execute(language: "crystal")
          assert_includes res, "Test run [PASSED]"
          assert_includes res, "3 specs, 0 failures"

          adapter = registry.get("crystal")
          refute_nil adapter
          assert_equal "crystal spec", adapter.custom_test_cmd
        end
      end
    end
  end

  def test_run_tests_tool_returns_elm_guidance_when_no_adapter_found
    registry = Rubik::Adapter::Registry.new
    tool = Rubik::Tools::RunTestsTool.new(registry, root_dir: @tmpdir, config: @config)

    res = tool.execute(language: "unsupported_lang")
    assert res.respond_to?(:error?) && res.error?
    assert_includes res.to_s, "-- NO TEST ADAPTER CONFIGURED --"
    assert_includes res.to_s, "No test runner is configured for language 'unsupported_lang'."
    assert_includes res.to_s, "repair_runtime_service(target: \"test_runner\", language_or_type: \"unsupported_lang\""
    assert_includes res.to_s, "run_command(command: \"<command>\")"
  end

  def test_run_tests_tool_with_empty_or_whitespace_language_defaults_to_ruby
    registry = Rubik::Adapter::Registry.new
    ruby_adapter = registry.get("ruby")
    tool = Rubik::Tools::RunTestsTool.new(registry, root_dir: @tmpdir, config: @config)

    ruby_adapter.stub :run_tests, ->(_dir) { { ok: true, output: "Ruby tests OK", duration: 0.1, exit_code: 0 } } do
      res = tool.execute(language: "   ")
      assert_includes res, "Ruby tests OK"
    end
  end

  def test_repair_runtime_tool_updates_existing_adapter_config
    registry = Rubik::Adapter::Registry.new
    runtime_mgr = Rubik::Runtime::Manager.new
    tool = Rubik::Tools::RepairRuntimeTool.new(
      runtime_manager: runtime_mgr,
      adapter_registry: registry,
      config: @config,
      root_dir: @tmpdir
    )

    ruby_adapter = registry.get("ruby")
    ruby_adapter.config = nil

    Rubik::Runtime::Discovery.stub :binary_available?, true do
      res = tool.execute(target: "test_runner", language_or_type: "ruby", proposed_command: "bundle exec rake test")
      refute res.respond_to?(:error?) && res.error?
      assert_equal @config, ruby_adapter.config
      assert_equal "bundle exec rake test", ruby_adapter.custom_test_cmd
    end
  end

  def test_generic_adapter_initialization_and_validation
    adapter = Rubik::Adapter::GenericAdapter.new(
      "elixir",
      test_cmd: "mix test",
      format_cmd: "mix format",
      syntax_cmd: "elixirc %s",
      guard: Rubik::Security::Guard.new(audit_log_path: nil, command_allowlist: ["mix", "elixirc"])
    )
    assert_equal "elixir", adapter.name
    assert_equal "mix", adapter.binary_name
    assert_equal "mix test", adapter.custom_test_cmd
    assert_equal "mix format", adapter.custom_format_cmd
    assert_equal "elixirc %s", adapter.custom_syntax_cmd
  end

  def test_generic_adapter_rejects_dangerous_custom_command
    assert_raises(Rubik::Security::BlockedWriteError) do
      Rubik::Adapter::GenericAdapter.new("elixir", test_cmd: "rm -rf /")
    end
  end
end
