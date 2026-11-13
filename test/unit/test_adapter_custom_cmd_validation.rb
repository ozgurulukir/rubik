# frozen_string_literal: true

require_relative "../test_helper"

# Pins the execution-time validation of operator-supplied custom adapter
# commands (#405): custom_format_cmd / custom_test_cmd must pass the shared
# validate_custom_command! gate (Security::Guard) before they are ever
# interpolated into a shell string, and the RepairRuntimeTool promotion must
# apply the same gate before the post-ctor setter.
class TestAdapterCustomCmdValidation < Minitest::Test
  DANGEROUS_CMD = "rm -rf /"

  # =========================================================================
  # 1. BaseAdapter#format_code / resolve_format_cmd gate
  # =========================================================================

  def test_format_code_rejects_dangerous_custom_format_cmd
    adapter = Rubik::Adapter::BaseAdapter.new("base", "base_bin")
    adapter.custom_format_cmd = DANGEROUS_CMD

    # If this stub is ever hit, a command leaked past validation into the
    # process runner.
    Rubik::Adapter::ProcessRunner.stub :run, ->(*) { raise "ProcessRunner.run must not be reached" } do
      assert_raises(Rubik::Security::BlockedWriteError) do
        adapter.format_code("lib/sample.rb")
      end
    end
  end

  def test_resolve_format_cmd_rejects_unclassifiable_custom_cmd
    adapter = Rubik::Adapter::BaseAdapter.new("base", "base_bin")
    adapter.custom_format_cmd = "nonexistent_formatter_cmd_xyz --write"

    assert_raises(Rubik::Security::BlockedWriteError) do
      adapter.resolve_format_cmd("lib/sample.rb")
    end
  end

  def test_format_code_still_runs_safe_custom_format_cmd
    adapter = Rubik::Adapter::BaseAdapter.new("base", "base_bin")
    adapter.custom_format_cmd = "rubocop -a %s"
    dummy_result = { ok: true, exit_code: 0, stdout: "formatted", stderr: "", output: "formatted", duration: 0.01 }

    Rubik::Runtime::Discovery.stub :binary_available?, true do
      Rubik::Adapter::ProcessRunner.stub :run, dummy_result do
        result = adapter.format_code("lib/sample.rb")

        assert result[:ok]
        assert_equal "formatted", result[:output]
      end
    end
  end

  # =========================================================================
  # 2. NodeAdapter resolve paths
  # =========================================================================

  def test_node_resolve_format_cmd_rejects_dangerous_custom_cmd
    adapter = Rubik::Adapter::NodeAdapter.new
    adapter.custom_format_cmd = DANGEROUS_CMD

    assert_raises(Rubik::Security::BlockedWriteError) do
      adapter.resolve_format_cmd("src/index.js")
    end
  end

  def test_node_resolve_test_cmd_rejects_dangerous_custom_test_cmd
    adapter = Rubik::Adapter::NodeAdapter.new
    adapter.custom_test_cmd = DANGEROUS_CMD

    assert_raises(Rubik::Security::BlockedWriteError) do
      adapter.resolve_test_cmd
    end
  end

  def test_node_resolve_test_cmd_still_resolves_safe_custom_test_cmd
    adapter = Rubik::Adapter::NodeAdapter.new
    adapter.custom_test_cmd = "npm run test:all"

    assert_equal "npm run test:all", adapter.resolve_test_cmd
    assert_equal "npm run test:all -- #{Shellwords.escape('src/foo.test.js')}", adapter.resolve_test_cmd(path: "src/foo.test.js")
  end

  # =========================================================================
  # 3. RepairRuntimeTool promotion gate (execution-time, TOCTOU closure)
  # =========================================================================

  def setup
    @temp_dir = Dir.mktmpdir("rubik_custom_cmd_test")
    @config = Rubik::Config.new(root_dir: @temp_dir)
    @runtime_manager = Rubik::Runtime::Manager.new
    @adapter_registry = Rubik::Adapter::Registry.new
    @lsp_manager = Rubik::LSP::Manager.new(config: @config, root_dir: @temp_dir, runtime_manager: @runtime_manager)
    @overlay_storage = Rubik::Runtime::OverlayStorage.new(root_dir: @temp_dir)
    @tool = Rubik::Tools::RepairRuntimeTool.new(
      runtime_manager: @runtime_manager,
      lsp_manager: @lsp_manager,
      adapter_registry: @adapter_registry,
      overlay_storage: @overlay_storage,
      config: @config,
      root_dir: @temp_dir
    )
  end

  def teardown
    @runtime_manager.context.dispose
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  # The pre-flight probe is stubbed to pass so the attempt reaches the
  # promotion phase: the adapter's own gate must then reject the dangerous
  # command and the previous value must survive the rollback.
  def test_promotion_rejects_dangerous_test_runner_cmd_and_keeps_previous_value
    adapter = @adapter_registry.get("ruby")
    adapter.custom_test_cmd = "rubocop -a"

    result = promote_with_passing_probe(target: "test_runner", proposed: DANGEROUS_CMD)

    assert_includes result, "Promotion failed"
    assert_includes result, "Dangerous command execution blocked"
    assert_equal "rubocop -a", adapter.custom_test_cmd
    refute @runtime_manager.context.has?("runner:ruby")
  end

  def test_promotion_rejects_dangerous_format_cmd_and_keeps_previous_value
    adapter = @adapter_registry.get("ruby")
    adapter.custom_format_cmd = "rubocop -a"

    result = promote_with_passing_probe(target: "linter", proposed: DANGEROUS_CMD)

    assert_includes result, "Promotion failed"
    assert_includes result, "Dangerous command execution blocked"
    assert_equal "rubocop -a", adapter.custom_format_cmd
    refute @runtime_manager.context.has?("linter:ruby")
  end

  private

  # Bypass only the pre-flight functional probe; everything downstream (the
  # promotion-time validation, setter, rollback) stays real.
  def promote_with_passing_probe(target:, proposed:)
    passing_probe = Object.new
    passing_probe.define_singleton_method(:verify) { |*| [true, nil] }
    result = nil
    Rubik::Runtime::RepairProbe.stub :new, passing_probe do
      result = @tool.execute(
        "target" => target,
        "language_or_type" => "ruby",
        "proposed_command" => proposed,
        "auto_probe" => false
      )
    end
    result
  end
end
