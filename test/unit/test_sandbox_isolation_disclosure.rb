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
    assert_includes res[:isolation], "🔍 Isolation: process"
    assert_includes res[:isolation], "weak"
  end

  def test_run_command_tool_appends_isolation_when_present
    guard = Rubik::Security::Guard.new
    runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir)
    tool = Rubik::Tools::RunCommandTool.new(guard: guard, runner: runner, root_dir: @temp_dir)

    out = tool.execute(command: "echo test_isolation")
    assert_includes out, "test_isolation"
    assert_includes out, "🔍 Isolation: process (advisory-only network guard) — weak"
  end

  def test_run_command_tool_omits_isolation_when_nil_in_mock
    guard = Rubik::Security::Guard.new
    mock_runner = Object.new
    def mock_runner.run(_cmd, **_opts)
      { ok: true, exit_code: 0, output: "plain output without isolation" }
    end

    tool = Rubik::Tools::RunCommandTool.new(guard: guard, runner: mock_runner, root_dir: @temp_dir)
    out = tool.execute(command: "echo test")

    assert_equal "[OK] plain output without isolation", out
    refute_includes out, "🔍 Isolation"
  end

  def test_runner_handles_frozen_driver_result
    runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir)
    frozen_res = { ok: true, exit_code: 0, output: "frozen driver output" }.freeze
    runner.instance_variable_get(:@driver).stub(:run, frozen_res) do
      res = runner.run("echo test")
      assert res[:ok]
      assert_includes res[:isolation], "🔍 Isolation:"
    end
  end
end
