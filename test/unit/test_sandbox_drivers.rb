# frozen_string_literal: true

require_relative "../test_helper"

class TestSandboxDrivers < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_process_driver_execution
    driver = Rubik::Sandbox::Driver::ProcessDriver.new
    assert driver.available?
    assert_equal "process", driver.name

    res = driver.run("echo 'hello from sandbox'", chdir: @temp_dir)
    assert res[:ok]
    assert_equal 0, res[:exit_code]
    assert_includes res[:stdout], "hello from sandbox"
    assert_equal "process", res[:driver]
  end

  def test_process_driver_timeout
    driver = Rubik::Sandbox::Driver::ProcessDriver.new
    res = driver.run("sleep 2", timeout: 0.1, chdir: @temp_dir)
    refute res[:ok]
    assert_equal 124, res[:exit_code]
    assert_includes res[:stderr], "timed out"
  end

  def test_docker_driver_argument_construction
    driver = Rubik::Sandbox::Driver::DockerDriver.new(image: "custom-sandbox:v1")
    assert_equal "docker", driver.name

    # Mock Open3.popen3 to inspect arguments without actually running docker daemon
    captured_args = nil
    Open3.stub :popen3, ->(*args, &block) {
      captured_args = args
      mock_thr = Struct.new(:value).new(Struct.new(:exitstatus).new(0))
      mock_io = StringIO.new("docker ok")
      mock_err = StringIO.new("")
      block.call(StringIO.new, mock_io, mock_err, mock_thr)
    } do
      res = driver.run("ls -la", chdir: @temp_dir, allow_network: false, memory_limit_mb: 256, cpus: "0.5")
      assert res[:ok]
      assert_equal "docker", res[:driver]
    end

    assert_includes captured_args, "docker"
    assert_includes captured_args, "run"
    assert_includes captured_args, "--rm"
    assert_includes captured_args, "--network"
    assert_includes captured_args, "none"
    assert_includes captured_args, "--memory"
    assert_includes captured_args, "256m"
    assert_includes captured_args, "--cpus"
    assert_includes captured_args, "0.5"
    assert_includes captured_args, "custom-sandbox:v1"
  end

  def test_podman_driver_argument_construction
    driver = Rubik::Sandbox::Driver::PodmanDriver.new(image: "podman-sandbox:v1")
    assert_equal "podman", driver.name

    captured_args = nil
    Open3.stub :popen3, ->(*args, &block) {
      captured_args = args
      mock_thr = Struct.new(:value).new(Struct.new(:exitstatus).new(0))
      mock_io = StringIO.new("podman ok")
      mock_err = StringIO.new("")
      block.call(StringIO.new, mock_io, mock_err, mock_thr)
    } do
      res = driver.run("cargo test", chdir: @temp_dir, allow_network: true)
      assert res[:ok]
      assert_equal "podman", res[:driver]
    end

    assert_includes captured_args, "podman"
    assert_includes captured_args, "podman-sandbox:v1"
    refute_includes captured_args, "--network"
  end

  def test_wasm_driver_execution_arguments
    driver = Rubik::Sandbox::Driver::WasmDriver.new(runtime: "wasmtime")
    assert_equal "wasm", driver.name

    captured_args = nil
    Open3.stub :popen3, ->(*args, &block) {
      captured_args = args
      mock_thr = Struct.new(:value).new(Struct.new(:exitstatus).new(0))
      mock_io = StringIO.new("wasm ok")
      mock_err = StringIO.new("")
      block.call(StringIO.new, mock_io, mock_err, mock_thr)
    } do
      res = driver.run("app.wasm --arg1", chdir: @temp_dir)
      assert res[:ok]
      assert_equal "wasm", res[:driver]
    end

    assert_includes captured_args, "wasmtime"
    assert_includes captured_args, "--dir"
    assert_includes captured_args, "app.wasm"
  end

  def test_driver_resolver_and_best_available_fallback
    proc_driver = Rubik::Sandbox::Driver.resolve("process")
    assert_instance_of Rubik::Sandbox::Driver::ProcessDriver, proc_driver

    docker_driver = Rubik::Sandbox::Driver.resolve("docker")
    assert_instance_of Rubik::Sandbox::Driver::DockerDriver, docker_driver

    # Auto fallback when docker/podman is not available
    best = Rubik::Sandbox::Driver.best_available("auto")
    assert best.is_a?(Rubik::Sandbox::Driver::Base)
  end

  def test_runner_with_config_and_isolation_level
    config = Rubik::Config.new(root_dir: @temp_dir)
    runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir, config: config)

    assert_includes ["process (env_proxy)", "container (docker oci)", "container (podman rootless)", "wasm / wasi sandbox"], runner.isolation_level

    res = runner.run("echo 'runner test'")
    assert res[:ok]
    assert_includes res[:output], "runner test"
  end

  # --- Plan 55: platform-gated shell selection ---

  def test_process_driver_routes_posix_syntax_to_bash
    skip "bash not available" unless Rubik::Platform.which("bash")

    driver = Rubik::Sandbox::Driver::ProcessDriver.new
    res = driver.run("echo inner=$(echo value)", chdir: @temp_dir)
    assert res[:ok]
    assert_equal "bash", res[:shell]
    assert_includes res[:stdout], "inner=value"
  end

  def test_process_driver_process_substitution_transcript_scenario
    skip "bash not available" unless Rubik::Platform.which("bash")

    driver = Rubik::Sandbox::Driver::ProcessDriver.new
    res = driver.run("echo \"=== x ===\" && grep \"sort\" <(echo sort-line) ", chdir: @temp_dir)
    assert res[:ok]
    assert_equal "bash", res[:shell]
    assert_includes res[:stdout], "=== x ==="
    assert_includes res[:stdout], "sort-line"
  end

  def test_process_driver_devnull_redirect_is_silent_under_bash
    skip "bash not available" unless Rubik::Platform.which("bash")

    driver = Rubik::Sandbox::Driver::ProcessDriver.new
    res = driver.run("grep nomatch *.rb 2>/dev/null || echo SILENT_OK", chdir: @temp_dir)
    assert res[:ok]
    assert_includes res[:stdout], "SILENT_OK"
  end

  def test_process_driver_pwsh_fingerprint_routing
    skip "pwsh not available" unless Rubik::Platform.which("pwsh")

    driver = Rubik::Sandbox::Driver::ProcessDriver.new
    res = driver.run("Get-Date -Format yyyy", chdir: @temp_dir)
    assert res[:ok]
    assert_equal "pwsh", res[:shell]
    assert_includes res[:stdout], "20"
  end

  def test_process_driver_plain_command_uses_platform_default
    driver = Rubik::Sandbox::Driver::ProcessDriver.new
    res = driver.run("echo plain", chdir: @temp_dir)
    assert res[:ok]
    expected = if Rubik::Platform.windows?
                 "cmd"
               else
                 Rubik::Platform.which("bash") ? "bash" : "sh"
               end
    assert_equal expected, res[:shell]
  end

  def test_process_driver_posix_single_quotes_reach_bash_untouched
    skip "bash not available" unless Rubik::Platform.which("bash")

    driver = Rubik::Sandbox::Driver::ProcessDriver.new
    res = driver.run("echo 'quoted value'", chdir: @temp_dir)
    assert_equal "bash", res[:shell]
    # cmd would pass the quotes through literally: "'quoted value'".
    assert_includes res[:stdout], "quoted value"
    refute_includes res[:stdout], "'"
  end

  def test_process_driver_explicit_shell_preference
    skip "bash not available" unless Rubik::Platform.which("bash")

    driver = Rubik::Sandbox::Driver::ProcessDriver.new(shell: "bash")
    res = driver.run("echo via=bash", chdir: @temp_dir)
    assert_equal "bash", res[:shell]
    assert_includes res[:stdout], "via=bash"

    # powershell (5.1) is outside the closed set -> auto behavior
    invalid = Rubik::Sandbox::Driver::ProcessDriver.new(shell: "powershell")
    res2 = invalid.run("echo plain", chdir: @temp_dir)
    assert_nil res2[:note]
    assert_equal "cmd", res2[:shell] if Rubik::Platform.windows?
  end

  def test_process_driver_prepends_fallback_note_when_shell_missing
    Rubik::Platform.stub :which, proc {} do
      driver = Rubik::Sandbox::Driver::ProcessDriver.new(shell: "bash")
      res = driver.run("echo still-runs", chdir: @temp_dir)
      assert res[:ok]
      assert_includes res[:stderr], "not found"
      assert_includes res[:stdout], "still-runs"
    end
  end
end
