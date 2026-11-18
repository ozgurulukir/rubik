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

    captured_args = capture_bwrap_args(driver, "echo 'hello bwrap'", chdir: @temp_dir, allow_network: false)

    assert_includes captured_args, "bwrap"
    assert_includes captured_args, "--dev"
    assert_includes captured_args, "/dev"
    assert_includes captured_args, "--proc"
    assert_includes captured_args, "/proc"
    assert_includes captured_args, "--tmpfs"
    assert_includes captured_args, "--bind"
    assert_includes captured_args, File.expand_path(@temp_dir)
    assert_includes captured_args, "--chdir"
    assert_includes captured_args, "--unshare-net"
    assert_includes captured_args, "--unshare-pid"
    assert_includes captured_args, "--die-with-parent"
    assert_includes captured_args, "--new-session"
    assert_includes captured_args, "--unshare-ipc"
    assert_includes captured_args, "--unshare-uts"
    assert_includes captured_args, "echo 'hello bwrap'"

    # The whole host root must never be bind-mounted; only the explicit
    # minimal system tree is exposed read-only.
    ro_sources = bind_sources(captured_args, "--ro-bind")
    refute_includes ro_sources, "/", "the whole host root must not be bind-mounted"
    ["/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc"].each do |path|
      assert_includes ro_sources, path if File.directory?(path)
    end

    # tmpfs gets noexec,nosuid where the installed bwrap supports it, otherwise
    # a plain /tmp. Either way it is a tmpfs, never a host path.
    tmpfs_index = captured_args.index("--tmpfs")
    refute_nil tmpfs_index
    assert_includes ["/tmp", "/tmp:rw,noexec,nosuid"], captured_args[tmpfs_index + 1]
  end

  def test_bubblewrap_driver_allows_network_when_requested
    driver = Rubik::Sandbox::Driver::BubblewrapDriver.new

    captured_args = capture_bwrap_args(driver, "curl https://example.com", chdir: @temp_dir, allow_network: true)

    refute_includes captured_args, "--unshare-net"
  end

  def test_bubblewrap_tmpfs_uses_hardened_options_when_supported
    Rubik::Sandbox::Driver::BubblewrapDriver.stub :tmpfs_supports_options?, true do
      driver = Rubik::Sandbox::Driver::BubblewrapDriver.new
      captured_args = capture_bwrap_args(driver, "echo ok", chdir: @temp_dir)
      index = captured_args.index("--tmpfs")
      assert_equal "/tmp:rw,noexec,nosuid", captured_args[index + 1]
    end
  end

  def test_bubblewrap_tmpfs_falls_back_when_options_unsupported
    Rubik::Sandbox::Driver::BubblewrapDriver.stub :tmpfs_supports_options?, false do
      driver = Rubik::Sandbox::Driver::BubblewrapDriver.new
      captured_args = capture_bwrap_args(driver, "echo ok", chdir: @temp_dir)
      index = captured_args.index("--tmpfs")
      assert_equal "/tmp", captured_args[index + 1]
    end
  end

  def test_bubblewrap_does_not_expose_host_home_directory
    driver = Rubik::Sandbox::Driver::BubblewrapDriver.new
    skip "bwrap unavailable" unless driver.available?

    probe = driver.run("true", chdir: @temp_dir)
    skip "bwrap cannot run in this environment: #{probe[:stderr]}" unless probe[:ok]

    res = driver.run("if [ -d /home ] || [ -d /root ]; then echo LEAK; else echo HIDDEN; fi", chdir: @temp_dir)
    assert res[:ok], "bwrap run failed: #{res[:stderr]}"
    assert_includes res[:stdout], "HIDDEN"
  end

  private

  def capture_bwrap_args(driver, cmd, chdir:, allow_network: false)
    captured = nil
    Open3.stub :popen3, lambda { |*args, &block|
      captured = args
      mock_thr = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 1234)
      block.call(StringIO.new, StringIO.new("bwrap ok"), StringIO.new(""), mock_thr)
    } do
      res = driver.run(cmd, chdir: chdir, allow_network: allow_network)
      assert res[:ok]
      assert_equal "bwrap", res[:driver]
    end
    captured
  end

  def bind_sources(args, kind)
    args.each_with_index.filter_map { |arg, i| args[i + 1] if arg == kind }
  end
end
