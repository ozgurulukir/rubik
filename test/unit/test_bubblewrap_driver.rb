# frozen_string_literal: true

require_relative "../test_helper"

class TestBubblewrapDriver < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_bwrap_test")
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_bubblewrap_driver_attributes_and_availability
    driver = Rubik::Sandbox::Driver::BubblewrapDriver.new
    assert_equal "bwrap", driver.name

    expected_avail = Rubik::Platform.linux? && !Rubik::Platform.which("bwrap").nil?
    assert_equal expected_avail, driver.available?
  end

  def test_bubblewrap_driver_argument_construction_isolated
    driver = Rubik::Sandbox::Driver::BubblewrapDriver.new(allowed_dirs: [@temp_dir])

    captured_args = nil
    Open3.stub :popen3, lambda { |*args, &block|
      captured_args = args
      mock_thr = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 1234)
      mock_io = StringIO.new("bwrap ok")
      mock_err = StringIO.new("")
      block.call(StringIO.new, mock_io, mock_err, mock_thr)
    } do
      res = driver.run("echo 'hello bwrap'", chdir: @temp_dir, allow_network: false)
      assert res[:ok]
      assert_equal "bwrap", res[:driver]
    end

    assert_includes captured_args, "bwrap"
    assert_includes captured_args, "--ro-bind"
    assert_includes captured_args, "/"
    assert_includes captured_args, "--dev"
    assert_includes captured_args, "/dev"
    assert_includes captured_args, "--proc"
    assert_includes captured_args, "/proc"
    assert_includes captured_args, "--tmpfs"
    assert_includes captured_args, "/tmp"
    assert_includes captured_args, "--bind"
    assert_includes captured_args, File.expand_path(@temp_dir)
    assert_includes captured_args, "--chdir"
    assert_includes captured_args, "--unshare-net"
    assert_includes captured_args, "--unshare-pid"
    assert_includes captured_args, "--die-with-parent"
    assert_includes captured_args, "echo 'hello bwrap'"
  end

  def test_bubblewrap_driver_allows_network_when_requested
    driver = Rubik::Sandbox::Driver::BubblewrapDriver.new

    captured_args = nil
    Open3.stub :popen3, lambda { |*args, &block|
      captured_args = args
      mock_thr = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 1234)
      mock_io = StringIO.new("network ok")
      mock_err = StringIO.new("")
      block.call(StringIO.new, mock_io, mock_err, mock_thr)
    } do
      res = driver.run("curl https://example.com", chdir: @temp_dir, allow_network: true)
      assert res[:ok]
    end

    refute_includes captured_args, "--unshare-net"
  end
end
