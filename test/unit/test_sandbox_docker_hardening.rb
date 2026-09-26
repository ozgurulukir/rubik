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
    docker_rm_cmd = nil

    mock_thr = Struct.new(:value, :pid).new(Struct.new(:exitstatus, :signaled?).new(0, false), 99_999)

    Rubik::Platform.stub :kill_tree, lambda { |pid|
      killed_pid = pid
    } do
      driver.stub :system, lambda { |cmd|
        docker_rm_cmd = cmd if cmd.to_s.include?("docker rm -f")
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
    assert docker_rm_cmd&.include?("docker rm -f rubik-box-")
  end
end
