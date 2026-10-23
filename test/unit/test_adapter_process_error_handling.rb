# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require_relative "../../lib/rubik/adapter/process"

class TestAdapterProcessErrorHandling < Minitest::Test
  def test_process_runner_successful_execution
    res = Rubik::Adapter::ProcessRunner.run("echo hello", timeout: 5)
    assert res[:ok]
    assert_equal 0, res[:exit_code]
    assert_includes res[:stdout], "hello"
  end

  def test_process_runner_handles_non_existent_binary
    res = Rubik::Adapter::ProcessRunner.run("non_existent_binary_xyz_123", timeout: 5)
    refute res[:ok]
    assert_equal 127, res[:exit_code]
    assert_includes res[:stderr], "Binary not found"
  end

  def test_process_runner_handles_stdin_close_error
    # We can mock Open3.popen3 to yield pipe stubs that raise on close/read
    stdin_stub = Object.new
    def stdin_stub.close; raise IOError, "closed stream"; end

    stdout_stub = Object.new
    def stdout_stub.read; "stdout content"; end

    stderr_stub = Object.new
    def stderr_stub.read; ""; end

    wait_thr_stub = Object.new
    def wait_thr_stub.pid; 12345; end
    def wait_thr_stub.value; Struct.new(:exitstatus).new(0); end

    Open3.stub :popen3, ->(_cmd, **_opts, &block) { block.call(stdin_stub, stdout_stub, stderr_stub, wait_thr_stub) } do
      res = Rubik::Adapter::ProcessRunner.run("some_command")
      assert res[:ok]
      assert_equal "stdout content", res[:stdout]
    end
  end
end
