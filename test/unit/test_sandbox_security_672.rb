# frozen_string_literal: true

require_relative "../test_helper"
require "minitest/mock"

# Issue #672: fail closed on an unavailable requested sandbox, keep the
# upstream gate as the single approval/audit decision point, align the shell
# vocabulary, and stop the spurious docker force-remove on successful runs.
class TestSandboxSecurity672 < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rubik_sandbox_security_672")
    @home = Dir.mktmpdir("rubik_sandbox_security_672_home")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
    FileUtils.remove_entry(@home) if @home && Dir.exist?(@home)
  end

  def test_runner_fails_closed_when_requested_sandbox_has_no_driver
    cfg = Rubik::Config.new(root_dir: @root, home_dir: @home)
    cfg.set("sandbox.enabled", true)
    cfg.set("sandbox.driver", "auto")

    Rubik::Sandbox::Driver.stub(:best_available, nil) do
      _out, err = capture_io do
        runner = Rubik::Sandbox::Runner.new(root_dir: @root, config: cfg)
        error = assert_raises(Rubik::Security::BlockedWriteError) { runner.run("echo hi") }
        assert_match(/sandbox requested but unavailable/i, error.message)
        assert_includes runner.isolation_disclosure, "sandbox requested but unavailable"
        assert_includes runner.isolation_level, "unavailable"
      end
      assert_includes err, "sandbox requested but unavailable"
    end
  end

  def test_upstream_gate_is_the_single_decision_point
    audit_file = File.join(@root, "audit.log")
    real_guard = Rubik::Security::Guard.new(audit_log_path: audit_file)
    calls = []
    guard = Object.new
    guard.define_singleton_method(:verify_command_safety!) do |cmd, **kw|
      calls << [cmd, kw]
      real_guard.verify_command_safety!(cmd, **kw)
    end

    ast = Struct.new(:classification, :commands, :parse_warnings).new(:unknown, [], [])
    shell = Object.new
    shell.define_singleton_method(:interactive_input?) { true }
    real_guard.shell = shell
    prompts = 0
    approval = lambda do |_sh, _q, **_kw|
      prompts += 1
      "y"
    end

    Rubik::Security::Classifier.stub(:classify, ast) do
      Rubik::UI::Approvals.stub(:keypress_yes_no, approval) do
        runner = Rubik::Sandbox::Runner.new(root_dir: @root, guard: guard)
        tool = Rubik::Tools::RunCommandTool.new(guard: guard, runner: runner, root_dir: @root)
        tool.execute(command: "echo single_gate")
      end
    end

    assert_equal 1, calls.size, "the upstream gate must be the only decision point"
    assert_equal 1, prompts, "the operator must be prompted once for one execution"
    assert_equal 1, File.readlines(audit_file).size, "one execution must produce one audit record"
  end

  def test_direct_driver_callers_still_reverify_command_safety
    guard = Object.new
    def guard.verify_command_safety!(cmd, shell: nil) # rubocop:disable Lint/UnusedMethodArgument
      raise Rubik::Security::BlockedWriteError, "blocked by injected guard: #{cmd}"
    end
    driver = Rubik::Sandbox::Driver::ProcessDriver.new(guard: guard)

    error = assert_raises(Rubik::Security::BlockedWriteError) do
      driver.run("echo hi", chdir: @root)
    end
    assert_match(/blocked by injected guard/, error.message)
  end

  def test_verified_commands_still_get_the_cmd_exe_specific_guard
    driver = Rubik::Sandbox::Driver::ProcessDriver.new
    resolved = { shell: "cmd", argv: ["cmd", "/c", "start calc"] }

    Rubik::Platform.stub(:windows?, true) do
      assert_raises(Rubik::Security::BlockedWriteError) do
        driver.send(:spawn_args_for, resolved, "start calc", verified: true)
      end
      assert_equal ["echo hi"], driver.send(:spawn_args_for, resolved, "echo hi", verified: true)
    end
  end

  def test_shell_schema_alignment_rejects_powershell_and_accepts_resolver_values
    schema = Rubik::Config::Schema
    assert schema.validate_value!("sandbox.shell", "pwsh")
    assert schema.validate_value!("sandbox.shell", "cmd")
    refute schema.validate_value!("sandbox.shell", "powershell"),
           "the schema must not accept a preference the resolver normalizes away"
  end

  def test_verb_noun_fingerprint_ignores_non_command_arguments
    resolver = Rubik::Sandbox::ShellResolver
    assert_equal "bash", resolver.gate('git commit -m "Fix Foo-Bar"', :linux)
    # A cmdlet that is an actual pipeline command still routes to pwsh.
    assert_equal "pwsh", resolver.gate('git branch -r | Select-String "fix"', :windows)
    assert_equal "pwsh", resolver.gate("Get-Content log.txt | Sort-Object", :windows)
  end

  def test_powershell_preference_spawns_the_binary_actually_found
    found = "C:/Program Files/PowerShell/7/pwsh.exe"
    Rubik::Platform.stub(:which, ->(bin) { bin == "powershell" ? found : nil }) do
      resolved = Rubik::Sandbox::ShellResolver.resolve("Get-Date", platform: :windows, preference: "pwsh")
      assert_equal found, resolved[:argv][0], "spawn must use the discovered binary"
      assert_equal "pwsh", resolved[:shell]
    end
  end

  def test_docker_cleanup_runs_only_when_the_container_may_survive
    driver = Rubik::Sandbox::Driver::DockerDriver.new
    rm_calls = []
    success = { ok: true, exit_code: 0, stdout: "ok", stderr: "", timed_out: false }

    Rubik::Platform.stub(:popen_capture, success) do
      driver.stub(:system, lambda { |*args, **_kw|
        rm_calls << args
        true
      }) do
        res = driver.run("echo hi", chdir: @root)
        assert res[:ok]
      end
    end

    assert_empty rm_calls, "a --rm container that completed normally needs no force-remove"
  end
end
