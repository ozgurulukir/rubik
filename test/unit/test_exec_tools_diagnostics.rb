# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/rubik/tools/builtins/exec"
require_relative "../../lib/rubik/tools/result"
require_relative "../../lib/rubik/adapter/base"
require_relative "../../lib/rubik/adapter/registry"
require_relative "../../lib/rubik/runtime/diagnostic_engine"
require_relative "../../lib/rubik/security/guard"

class TestExecToolsDiagnostics < Minitest::Test
  class MockAdapter < Rubik::Adapter::BaseAdapter
    attr_accessor :mock_run_tests_res, :mock_available, :mock_resolve_cmd

    def available?
      @mock_available
    end

    def run_tests(_root_dir)
      # Simüle edilmiş run_tests (BaseAdapter'dan gelen)
      cmd = @mock_resolve_cmd
      unless cmd
        reason = nil
        reason = "No test runner found for #{@name} (tried: mock_candidate). Install one or set custom_test_cmd." if available?
        return unavailable_result(reason: reason)
      end

      @mock_run_tests_res
    end
  end

  # Captures the timeout/path keyword arguments the tool forwards so the
  # 1..600 clamp can be asserted without running a real test suite.
  class TimeoutCapturingAdapter < Rubik::Adapter::BaseAdapter
    attr_reader :captured_timeout, :captured_path

    def available? = true

    def run_tests(_root_dir, path: nil, timeout: nil)
      @captured_path = path
      @captured_timeout = timeout
      { ok: true, output: "ok", duration: 0.1, exit_code: 0 }
    end
  end

  class MockRunner
    attr_accessor :mock_run_res

    def run(_cmd, timeout: 15, chdir: Dir.pwd, verified: false)
      _ = timeout
      _ = chdir
      _ = verified
      @mock_run_res
    end
  end

  def setup
    @registry = Rubik::Adapter::Registry.new
    @adapter = MockAdapter.new("ruby", "ruby")
    @registry.register("ruby", @adapter)
    @run_tests_tool = Rubik::Tools::RunTestsTool.new(@registry)

    @guard = Rubik::Security::Guard.new
    @runner = MockRunner.new
    @run_cmd_tool = Rubik::Tools::RunCommandTool.new(guard: @guard, runner: @runner)
  end

  def test_run_command_rejects_empty_command
    result = @run_cmd_tool.execute("command" => "   ")

    assert result.error?
    assert_includes result, "must not be empty"
  end

  def test_run_command_rejects_stringy_background_flag_instead_of_coercing_it
    @runner.mock_run_res = { ok: true, exit_code: 0, output: "foreground" }

    result = @run_cmd_tool.execute("command" => "echo hi", "background" => "false")

    assert result.error?
    assert_includes result, "background must be a boolean"
  end

  def test_run_command_accepts_typed_background_flag
    @runner.mock_run_res = { ok: true, exit_code: 0, output: "foreground" }
    task_manager = Object.new
    task_manager.define_singleton_method(:start) do |_cmd, **_kw|
      Struct.new(:id, :pid).new("task-1", 1234)
    end
    @run_cmd_tool.task_manager = task_manager

    result = @run_cmd_tool.execute("command" => "echo hi", "background" => false)

    assert result.ok?
    assert_includes result.output, "foreground"
  end

  # (1) fixture başarısız test çıktısı -> araç çıktısında :test_failure kategorisi + öneri satırı
  def test_run_tests_failure_includes_diagnostic
    @adapter.mock_resolve_cmd = "rake test"
    res = { ok: false, output: "1 failures, 0 errors\n", duration: 1.2, exit_code: 1, cmd: "rake test" }
    res[:diagnostic] = Rubik::Runtime::DiagnosticEngine.analyze_process_result(res)
    @adapter.mock_run_tests_res = res

    output = @run_tests_tool.execute(language: "ruby")

    assert_includes output, "Test run [FAILED]"
    assert_includes output, "=== Runtime Execution Diagnostic ==="
    assert_includes output, "Category    : TEST_FAILURE"
    assert_includes output, "Suggestion"
  end

  # (2) başarılı koşumda ek blok yok
  def test_run_tests_success_no_diagnostic
    @adapter.mock_resolve_cmd = "rake test"
    res = { ok: true, output: "0 failures, 0 errors", duration: 0.5, exit_code: 0, cmd: "rake test" }
    @adapter.mock_run_tests_res = res

    output = @run_tests_tool.execute(language: "ruby")

    assert_includes output, "Test run [PASSED]"
    refute_includes output, "=== Runtime Execution Diagnostic ==="
  end

  # (3) koşucu-yok senaryosunda adayları sayan mesaj
  def test_run_tests_unavailable_with_candidates
    @adapter.mock_resolve_cmd = nil
    @adapter.mock_available = true # Binary is available

    output = @run_tests_tool.execute(language: "ruby")
    assert_includes output, "Test run [FAILED]"
    assert_includes output, "No test runner found for ruby (tried: mock_candidate)"
  end

  def test_run_tests_unavailable_no_binary
    @adapter.mock_resolve_cmd = nil
    @adapter.mock_available = false # Binary missing

    output = @run_tests_tool.execute(language: "ruby")
    assert_includes output, "Test run [FAILED]"
    assert_includes output, "ruby is unavailable on system"
  end

  def test_run_tests_timeout_clamped_to_sibling_contract
    adapter = TimeoutCapturingAdapter.new("ruby", "ruby")
    registry = Rubik::Adapter::Registry.new
    registry.register("ruby", adapter)
    tool = Rubik::Tools::RunTestsTool.new(registry)

    tool.execute(language: "ruby", timeout: 86_400)
    assert_equal 600, adapter.captured_timeout, "oversized timeout must clamp to 600"

    tool.execute(language: "ruby", timeout: 45)
    assert_equal 45, adapter.captured_timeout, "in-range timeout passes through"
  end

  # (4) run_command başarısızlığında teşhis bloğu
  def test_run_command_failure_includes_diagnostic
    @guard.set_allowed_commands(["something_missing"])
    @runner.mock_run_res = { ok: false, output: "cannot find binary something", duration: 0.1, exit_code: 127 }

    output = @run_cmd_tool.execute(command: "something_missing").to_s

    assert_includes output, "[EXIT 127]"
    assert_includes output, "=== Runtime Execution Diagnostic ==="
    assert_includes output, "MISSING_BINARY"
  end

  def test_run_command_missing_binary_windows_exit9009
    @guard.set_allowed_commands(["foo"])
    @runner.mock_run_res = { ok: false, output: "'foo' is not recognized as an internal or external command", duration: 0.1, exit_code: 9009 }

    output = @run_cmd_tool.execute(command: "foo").to_s

    assert_includes output, "[EXIT 9009]"
    assert_includes output, "MISSING_BINARY"
  end

  def test_run_command_missing_binary_windows_exit_49_turkish
    @guard.set_allowed_commands(["python3"])
    @runner.mock_run_res = { ok: false, output: "Python bulunamadı; yüklemek için...", duration: 0.1, exit_code: 49 }

    output = @run_cmd_tool.execute(command: "python3 -c 'print(1)'").to_s

    assert_includes output, "[EXIT 49]"
    assert_includes output, "MISSING_BINARY"
  end

  def test_run_command_missing_binary_windows_exit_49_english
    @guard.set_allowed_commands(["python3"])
    @runner.mock_run_res = { ok: false, output: "Python was not found; run without arguments to install", duration: 0.1, exit_code: 49 }

    output = @run_cmd_tool.execute(command: "python3 -c 'print(1)'").to_s

    assert_includes output, "[EXIT 49]"
    assert_includes output, "MISSING_BINARY"
  end

  def test_run_command_success_no_diagnostic
    @runner.mock_run_res = { ok: true, output: "hello", duration: 0.1, exit_code: 0 }

    output = @run_cmd_tool.execute(command: "echo hello").to_s

    assert_includes output, "[OK]"
    refute_includes output, "=== Runtime Execution Diagnostic ==="
  end
end
