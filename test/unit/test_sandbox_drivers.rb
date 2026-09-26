# frozen_string_literal: true

require_relative "../test_helper"

class TestSandboxDrivers < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
  end

  def teardown
    remove_temp_dir(@temp_dir)
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
    Open3.stub :popen3, lambda { |*args, &block|
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
    Open3.stub :popen3, lambda { |*args, &block|
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

  def test_bwrap_driver_registration
    bwrap_driver = Rubik::Sandbox::Driver.resolve("bwrap")
    assert_instance_of Rubik::Sandbox::Driver::BubblewrapDriver, bwrap_driver
    assert_equal "bwrap", bwrap_driver.name

    bubblewrap_alias = Rubik::Sandbox::Driver.resolve("bubblewrap")
    assert_instance_of Rubik::Sandbox::Driver::BubblewrapDriver, bubblewrap_alias
  end

  def test_driver_resolver_and_best_available_fallback
    # Process is no longer a sandbox driver; resolves to nil
    assert_nil Rubik::Sandbox::Driver.resolve("process")
    assert_nil Rubik::Sandbox::Driver.resolve("none")
    assert_nil Rubik::Sandbox::Driver.resolve(nil)

    docker_driver = Rubik::Sandbox::Driver.resolve("docker")
    assert_instance_of Rubik::Sandbox::Driver::DockerDriver, docker_driver

    # Auto fallback
    best = Rubik::Sandbox::Driver.best_available("auto")
    assert best.nil? || best.is_a?(Rubik::Sandbox::Driver::Base)
  end

  def test_dynamic_driver_registration_and_unregistration
    mock_firejail_class = Class.new(Rubik::Sandbox::Driver::Base) do
      def name
        "firejail"
      end

      def available?
        true
      end
    end

    Rubik::Sandbox::Driver.register("firejail", mock_firejail_class)
    assert Rubik::Sandbox::Driver.registered_drivers.key?("firejail")
    resolved = Rubik::Sandbox::Driver.resolve("firejail")
    assert_equal "firejail", resolved.name

    Rubik::Sandbox::Driver.unregister("firejail")
    refute Rubik::Sandbox::Driver.registered_drivers.key?("firejail")
    assert_nil Rubik::Sandbox::Driver.resolve("firejail")
  end

  def test_dynamic_driver_revertible_inverse_with_context
    mock_driver_class = Class.new(Rubik::Sandbox::Driver::Base) do
      def name
        "ephemeral"
      end

      def available?
        true
      end
    end

    ctx = Rubik::Runtime::Context.new
    Rubik::Sandbox::Driver.register("ephemeral", mock_driver_class, ctx: ctx)
    assert Rubik::Sandbox::Driver.registered_drivers.key?("ephemeral")

    ctx.dispose
    refute Rubik::Sandbox::Driver.registered_drivers.key?("ephemeral")
    assert_nil Rubik::Sandbox::Driver.resolve("ephemeral")
  end

  def test_ctx_registration_over_builtin_restores_builtin_on_dispose
    mock_driver_class = Class.new(Rubik::Sandbox::Driver::Base) do
      def name
        "docker"
      end

      def available?
        true
      end
    end

    ctx = Rubik::Runtime::Context.new
    Rubik::Sandbox::Driver.register("docker", mock_driver_class, ctx: ctx)
    assert_equal mock_driver_class, Rubik::Sandbox::Driver.registered_drivers["docker"]

    ctx.dispose

    assert_equal Rubik::Sandbox::Driver::DockerDriver, Rubik::Sandbox::Driver.registered_drivers["docker"],
                 "disposing an overlay must restore the built-in underneath, not evict it"
    assert_instance_of Rubik::Sandbox::Driver::DockerDriver, Rubik::Sandbox::Driver.resolve("docker")
  ensure
    # Restore the built-in even if an assertion above aborted mid-flight.
    Rubik::Sandbox::Driver.register("docker", Rubik::Sandbox::Driver::DockerDriver) unless
      Rubik::Sandbox::Driver.registered_drivers["docker"] == Rubik::Sandbox::Driver::DockerDriver
  end

  def test_dispose_does_not_clobber_later_registration_of_same_key
    klass_a = Class.new(Rubik::Sandbox::Driver::Base) do
      def name
        "overlay-a"
      end

      def available?
        true
      end
    end
    klass_b = Class.new(Rubik::Sandbox::Driver::Base) do
      def name
        "overlay-b"
      end

      def available?
        true
      end
    end

    ctx_a = Rubik::Runtime::Context.new
    Rubik::Sandbox::Driver.register("overlay-key", klass_a, ctx: ctx_a)
    Rubik::Sandbox::Driver.register("overlay-key", klass_b) # newer registration, no ctx

    ctx_a.dispose

    assert_equal klass_b, Rubik::Sandbox::Driver.registered_drivers["overlay-key"],
                 "an older context's dispose must not clobber a newer registration"
  ensure
    Rubik::Sandbox::Driver.unregister("overlay-key")
  end

  def test_runner_with_config_and_isolation_level
    config = Rubik::Config.new(root_dir: @temp_dir)
    runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir, config: config)

    assert_equal "direct (safe host)", runner.isolation_level

    res = runner.run("echo 'runner test'")
    assert res[:ok]
    assert_includes res[:output], "runner test"
    assert_includes res[:isolation], "direct"

    mock_driver_class = Class.new(Rubik::Sandbox::Driver::Base) do
      def name
        "mockbox"
      end

      def available?
        true
      end
    end
    Rubik::Sandbox::Driver.register("mockbox", mock_driver_class)

    config.set("sandbox.enabled", true)
    config.set("sandbox.driver", "mockbox")
    assert_equal "sandbox (mockbox)", runner.isolation_level
  ensure
    Rubik::Sandbox::Driver.unregister("mockbox")
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
