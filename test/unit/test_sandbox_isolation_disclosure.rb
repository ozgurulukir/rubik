# frozen_string_literal: true

require_relative "../test_helper"

class TestSandboxIsolationDisclosure < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_sandbox_disclosure_test")
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_runner_includes_isolation_in_run_result
    runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir)
    res = runner.run("echo hello")

    assert res[:ok]
    assert_includes res.keys, :isolation
    assert_includes res[:isolation], "🔍 Execution: direct"
    assert_includes res[:isolation], "safe execution guardrails active; sandbox disabled"
  end

  def test_run_command_tool_appends_isolation_when_present
    guard = Rubik::Security::Guard.new
    runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir)
    tool = Rubik::Tools::RunCommandTool.new(guard: guard, runner: runner, root_dir: @temp_dir)

    out = tool.execute(command: "echo test_isolation").to_s
    assert_includes out, "test_isolation"
    assert_includes out, "🔍 Execution: direct (safe execution guardrails active; sandbox disabled)"
  end

  def test_run_command_tool_omits_isolation_when_nil_in_mock
    guard = Rubik::Security::Guard.new
    mock_runner = Object.new
    def mock_runner.run(_cmd, **_opts)
      { ok: true, exit_code: 0, output: "plain output without isolation" }
    end

    tool = Rubik::Tools::RunCommandTool.new(guard: guard, runner: mock_runner, root_dir: @temp_dir)
    out = tool.execute(command: "echo test").to_s

    assert_equal "[OK] plain output without isolation", out
    refute_includes out, "🔍 Isolation"
  end

  def test_runner_handles_frozen_driver_result
    frozen_res = { ok: true, exit_code: 0, output: "frozen driver output" }.freeze
    mock_driver = Object.new
    mock_driver.define_singleton_method(:name) { "mockbox" }
    mock_driver.define_singleton_method(:run) { |_cmd, **_opts| frozen_res }

    runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir, driver: mock_driver)
    res = runner.run("echo test")
    assert res[:ok]
    assert_includes res[:isolation], "🔍 Isolation: sandbox"
  end

  def test_runner_includes_sandbox_isolation_when_enabled
    cfg = Rubik::Config.new(root_dir: @temp_dir)
    cfg.set("sandbox.enabled", true)
    mock_driver = Object.new
    mock_driver.define_singleton_method(:name) { "mockbox" }
    mock_driver.define_singleton_method(:run) do |_cmd, **_opts|
      { ok: true, exit_code: 0, output: "mock output" }
    end
    runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir, config: cfg, driver: mock_driver)
    res = runner.run("echo hello")
    assert_includes res[:isolation], "🔍 Isolation: sandbox (mockbox, network=none) — strong"
  end
end
