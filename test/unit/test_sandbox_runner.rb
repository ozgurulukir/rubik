# frozen_string_literal: true

require_relative "../test_helper"

class TestSandboxRunner < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_timeout_kills_long_running_command
    res = @runner.run("sleep 5", timeout: 1)
    refute res[:ok]
    assert_equal 124, res[:exit_code]
    assert_includes res[:stderr], "timed out"
  end

  def test_successful_command_execution
    res = @runner.run("echo 'hello sandbox'", timeout: 5)
    assert res[:ok]
    assert_includes res[:stdout], "hello sandbox"
  end

  def test_isolation_level_report
    assert_equal "direct (safe host)", @runner.isolation_level
  end

  def test_verify_chdir_safety_rejects_symlink_escaping_workspace
    outside = Dir.mktmpdir
    escape = File.join(@temp_dir, "escape")
    File.symlink(outside, escape)

    err = assert_raises(Rubik::Security::BlockedWriteError) do
      @runner.verify_chdir_safety!(escape)
    end
    assert_equal :chdir_outside_root, err.kind

    sub = File.join(@temp_dir, "sub")
    FileUtils.mkdir_p(sub)
    assert @runner.verify_chdir_safety!(sub)
  ensure
    FileUtils.remove_entry(outside) if outside && Dir.exist?(outside)
  end
end
