# frozen_string_literal: true

require_relative "../test_helper"

class TestAutonomousDiagnosticAndRepair < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_repair_test")
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
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  def test_diagnostic_engine_classifications
    # Missing binary
    d1 = Rubik::Runtime::DiagnosticEngine.diagnose(
      cmd: "unknown_lsp_server --stdio",
      exit_code: 127,
      stderr: "sh: 1: unknown_lsp_server: not found"
    )
    assert_equal :missing_binary, d1.category
    assert_includes d1.suggestion, "not found"
    assert_includes d1.format_for_llm, "MISSING_BINARY"

    # Timeout
    d2 = Rubik::Runtime::DiagnosticEngine.diagnose(
      cmd: "slow_test_runner",
      exit_code: 124,
      stderr: "Execution timed out after 15 seconds"
    )
    assert_equal :timeout, d2.category
    assert_includes d2.suggestion, "timeout"

    # Missing flags
    d3 = Rubik::Runtime::DiagnosticEngine.diagnose(
      cmd: "typeprof",
      exit_code: 1,
      stderr: "typeprof: unrecognized option '--invalid'\nrequires stdio"
    )
    assert_equal :missing_flag_or_option, d3.category

    # Dependency missing
    d4 = Rubik::Runtime::DiagnosticEngine.diagnose(
      cmd: "bundle exec rspec",
      exit_code: 1,
      stderr: "Could not find gem 'rspec' in locally installed gems. Run `bundle install`."
    )
    assert_equal :dependency_missing, d4.category

    # Syntax error
    d5 = Rubik::Runtime::DiagnosticEngine.diagnose(
      cmd: "ruby -c bad.rb",
      exit_code: 1,
      stderr: "bad.rb:1: syntax error, unexpected end-of-input"
    )
    assert_equal :syntax_or_compile_error, d5.category

    # Test failure
    d6 = Rubik::Runtime::DiagnosticEngine.diagnose(
      cmd: "rake test",
      exit_code: 1,
      stdout: "10 runs, 20 assertions, 2 failures, 0 errors, 0 skips"
    )
    assert_equal :test_failure, d6.category
  end

  def test_repair_service_preflight_failure_rollback
    res = @tool.execute(
      "target" => "test_runner",
      "language_or_type" => "ruby",
      "proposed_command" => "non_existent_runner_binary_xyz_123",
      "auto_probe" => false
    )

    assert_includes res, "Verification failed"
    assert_includes res, "MISSING_BINARY"
    # Ensure context was not polluted
    refute @runtime_manager.context.has?("runner:ruby")
  end

  def test_repair_test_runner_success_and_hot_swap
    res = @tool.execute(
      "target" => "test_runner",
      "language_or_type" => "ruby",
      "proposed_command" => "ruby -v",
      "auto_probe" => false
    )

    assert_includes res, "Successfully verified and promoted"
    assert @runtime_manager.context.has?("runner:ruby")
    assert_equal "ruby -v", @adapter_registry.get("ruby").custom_test_cmd
  end

  def test_repair_linter_success
    res = @tool.execute(
      "target" => "linter",
      "language_or_type" => "ruby",
      "proposed_command" => "ruby -c",
      "auto_probe" => false
    )

    assert_includes res, "Successfully verified and promoted"
    assert @runtime_manager.context.has?("linter:ruby")
    assert_equal "ruby -c", @adapter_registry.get("ruby").custom_format_cmd
  end

  def test_repair_with_auto_probe
    FileUtils.touch(File.join(@temp_dir, "Gemfile"))
    res = @tool.execute(
      "target" => "test_runner",
      "language_or_type" => "ruby",
      "auto_probe" => true
    )

    assert_includes res, "Successfully verified and promoted"
    assert @runtime_manager.context.has?("runner:ruby")
  end

  def test_diagnostic_engine_permission_denied_and_process_result_analysis
    res_mock = {
      ok: false,
      cmd: "/bin/restricted_script.sh",
      exit_code: 126,
      output: "bash: /bin/restricted_script.sh: Permission denied",
      duration: 0.05
    }
    failure = Rubik::Runtime::DiagnosticEngine.analyze_process_result(res_mock)
    assert_equal :permission_denied, failure.category
    assert_includes failure.suggestion, "Permission denied"
    assert_equal 126, failure.exit_code
    assert_in_delta 0.05, failure.duration, 0.001
  end

  def test_diagnostic_engine_success_analysis
    res_mock = {
      ok: true,
      cmd: "echo 'hello'",
      exit_code: 0,
      stdout: "hello\n",
      duration: 0.01
    }
    diag = Rubik::Runtime::DiagnosticEngine.analyze_process_result(res_mock)
    assert_equal :success, diag.category
    assert_includes diag.suggestion, "successfully"
  end

  def test_repair_lsp_start_failure_rolls_back_configuration
    @config.set("lsp.servers.ruby", "solargraph stdio")
    start_stub = ->(_lang) { { ok: false, error: "stub handshake failure" } }
    res = nil
    @lsp_manager.stub(:start_client, start_stub) do
      res = @tool.execute(
        "target" => "lsp",
        "language_or_type" => "ruby",
        "proposed_command" => "ruby -v", # valid binary, but not an LSP server
        "auto_probe" => false
      )
    end

    assert_includes res, "Failed to start LSP server"
    assert_includes res, "previous configuration restored"
    # In-memory rollback to the previous configured command; no service promoted
    assert_equal "solargraph stdio", @config.fetch("lsp.servers.ruby")
    refute @runtime_manager.context.has?("lsp:ruby")
  end

  def test_repair_lsp_success_persists_only_after_verified_start
    start_stub = ->(_lang) { { ok: true, message: "stubbed start" } }
    res = nil
    @lsp_manager.stub(:start_client, start_stub) do
      res = @tool.execute(
        "target" => "lsp",
        "language_or_type" => "ruby",
        "proposed_command" => "ruby -v", # real binary passes preflight; start is stubbed
        "auto_probe" => false
      )
    end

    assert_includes res, "Successfully verified and promoted"
    # Config is set (and persisted to the temp project dir) only on success
    assert_equal "ruby -v", @config.fetch("lsp.servers.ruby")
    assert @runtime_manager.context.has?("lsp:ruby")
  end

  def test_repair_command_target
    res = @tool.execute(
      "target" => "command",
      "language_or_type" => "echo",
      "proposed_command" => "echo 'ok'",
      "auto_probe" => false
    )
    assert_includes res, "Successfully verified and promoted"
    assert @runtime_manager.context.has?("command:echo")
  end

  def test_repair_invalid_target_type
    res = @tool.execute(
      "target" => "unsupported_target_type",
      "language_or_type" => "ruby",
      "proposed_command" => "ruby -v"
    )
    assert_includes res, "Verification failed"
    assert_includes res, "Unknown target component type"
  end
end
