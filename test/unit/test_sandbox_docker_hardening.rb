# frozen_string_literal: true

require_relative "../test_helper"
require "open3"

class TestSandboxDockerHardening < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
  end

  def teardown
    remove_temp_dir(@temp_dir)
  end

  def test_docker_security_arguments_and_unique_name
    driver = Rubik::Sandbox::Driver::DockerDriver.new(image: "rubik-sandbox:latest")
    captured_args = nil

    mock_thr = Struct.new(:value, :pid).new(Struct.new(:exitstatus, :signaled?).new(0, false), 12_345)
    mock_io = StringIO.new("test output")
    mock_err = StringIO.new("")

    Open3.stub :popen3, lambda { |*args, &block|
      captured_args = args
      block.call(StringIO.new, mock_io, mock_err, mock_thr)
    } do
      res = driver.run("echo hi", chdir: @temp_dir)
      assert res[:ok]
    end

    assert_includes captured_args, "--read-only"
    assert_includes captured_args, "--cap-drop"
    cap_drop_idx = captured_args.index("--cap-drop")
    assert_equal "ALL", captured_args[cap_drop_idx + 1]

    assert_includes captured_args, "--security-opt"
    sec_opt_idx = captured_args.index("--security-opt")
    assert_equal "no-new-privileges", captured_args[sec_opt_idx + 1]

    assert_includes captured_args, "--tmpfs"
    tmpfs_idx = captured_args.index("--tmpfs")
    assert_equal "/tmp:rw,noexec,nosuid", captured_args[tmpfs_idx + 1]

    assert_includes captured_args, "--name"
    name_idx = captured_args.index("--name")
    container_name = captured_args[name_idx + 1]
    assert_match(/\Arubik-box-[0-9a-f]{12}\z/, container_name)
  end

  def test_docker_driver_timeout_cleanup
    driver = Rubik::Sandbox::Driver::DockerDriver.new
    killed_pid = nil
    docker_rm_args = nil
    docker_rm_kwargs = nil

    mock_thr = Struct.new(:value, :pid).new(Struct.new(:exitstatus, :signaled?).new(0, false), 99_999)

    Rubik::Platform.stub :kill_tree, lambda { |pid|
      killed_pid = pid
    } do
      driver.stub :system, lambda { |*args, **kwargs|
        if args.first == "docker" && args[1] == "rm"
          docker_rm_args = args
          docker_rm_kwargs = kwargs
        end
        true
      } do
        Open3.stub :popen3, lambda { |*_args, &block|
          block.call(StringIO.new, StringIO.new, StringIO.new, mock_thr)
          raise Timeout::Error, "execution timed out"
        } do
          res = driver.run("sleep 10", timeout: 0.1, chdir: @temp_dir)
          refute res[:ok]
          assert_equal 124, res[:exit_code]
          assert_includes res[:stderr], "timed out"
        end
      end
    end

    assert_equal 99_999, killed_pid
    refute_nil docker_rm_args
    assert_equal ["docker", "rm", "-f"], docker_rm_args[0..2]
    assert_match(/\Arubik-box-[0-9a-f]{12}\z/, docker_rm_args[3])
    assert_equal File::NULL, docker_rm_kwargs[:out]
    assert_equal File::NULL, docker_rm_kwargs[:err]
  end

  def test_docker_driver_available_uses_array_system_invocation
    driver = Rubik::Sandbox::Driver::DockerDriver.new
    system_args = nil
    system_kwargs = nil

    Rubik::Platform.stub :which, "/usr/bin/docker" do
      driver.stub :system, lambda { |*args, **kwargs|
        system_args = args
        system_kwargs = kwargs
        true
      } do
        assert driver.available?
      end
    end

    assert_equal ["docker", "ps"], system_args
    assert_equal File::NULL, system_kwargs[:out]
    assert_equal File::NULL, system_kwargs[:err]
  end

  def test_docker_driver_rm_prevents_command_injection
    driver = Rubik::Sandbox::Driver::DockerDriver.new
    docker_rm_args = nil

    mock_thr = Struct.new(:value, :pid).new(Struct.new(:exitstatus, :signaled?).new(0, false), 101)

    # Simulate container name generation with potential shell metacharacters
    SecureRandom.stub :hex, "123456; echo injected" do
      driver.stub :system, lambda { |*args, **_kwargs|
        docker_rm_args = args if args.first == "docker" && args[1] == "rm"
        true
      } do
        Open3.stub :popen3, lambda { |*_args, &block|
          block.call(StringIO.new, StringIO.new, StringIO.new, mock_thr)
        } do
          driver.run("echo test", chdir: @temp_dir)
        end
      end
    end

    refute_nil docker_rm_args
    # Array form passes the metacharacter string as a single literal argument
    assert_equal "rubik-box-123456; echo injected", docker_rm_args[3]
  end
end
