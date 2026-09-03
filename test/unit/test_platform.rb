# frozen_string_literal: true

require_relative "../test_helper"

class TestPlatform < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_platform_test")
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  def test_os_detection
    # At least one OS must match
    assert Rubik::Platform.windows? || Rubik::Platform.macos? || Rubik::Platform.linux?
    refute_empty Rubik::Platform.host_os
    refute_empty Rubik::Platform.ruby_platform
    assert_includes [:windows, :macos, :linux, :unknown], Rubik::Platform.os_family

    if Rubik::Platform.windows?
      assert_equal :windows, Rubik::Platform.os_family
      refute Rubik::Platform.unix?
      refute Rubik::Platform.linux?
      refute Rubik::Platform.macos?
    else
      assert Rubik::Platform.unix?
    end
  end

  def test_host_os_and_ruby_platform
    assert_equal RUBY_PLATFORM, Rubik::Platform.ruby_platform
    assert_equal (RbConfig::CONFIG["host_os"] || ""), Rubik::Platform.host_os

    RbConfig::CONFIG.stub(:[], nil) do
      assert_equal "", Rubik::Platform.host_os
    end
  end

  def test_host_os_windows_detection_branches
    ["mswin32", "mingw32", "cygwin", "bccwin", "wince"].each do |os_str|
      Rubik::Platform.stub(:host_os, os_str) do
        assert Rubik::Platform.windows?, "Expected #{os_str} to be recognized as windows"
        refute Rubik::Platform.macos?, "Expected #{os_str} not to be recognized as macos"
        refute Rubik::Platform.linux?, "Expected #{os_str} not to be recognized as linux"
        refute Rubik::Platform.unix?, "Expected #{os_str} not to be recognized as unix"
        assert_equal :windows, Rubik::Platform.os_family
      end
    end
  end

  def test_host_os_macos_detection_branches
    Gem.stub(:win_platform?, false) do
      ["darwin", "darwin20.0", "DARWIN21"].each do |os_str|
        Rubik::Platform.stub(:host_os, os_str) do
          refute Rubik::Platform.windows?, "Expected #{os_str} not to be recognized as windows"
          assert Rubik::Platform.macos?, "Expected #{os_str} to be recognized as macos"
          refute Rubik::Platform.linux?, "Expected #{os_str} not to be recognized as linux"
          assert Rubik::Platform.unix?, "Expected #{os_str} to be recognized as unix"
          assert_equal :macos, Rubik::Platform.os_family
        end
      end
    end
  end

  def test_host_os_linux_detection_branches
    Gem.stub(:win_platform?, false) do
      ["linux-gnu", "linux-musl", "linux"].each do |os_str|
        Rubik::Platform.stub(:host_os, os_str) do
          refute Rubik::Platform.windows?, "Expected #{os_str} not to be recognized as windows"
          refute Rubik::Platform.macos?, "Expected #{os_str} not to be recognized as macos"
          assert Rubik::Platform.linux?, "Expected #{os_str} to be recognized as linux"
          assert Rubik::Platform.unix?, "Expected #{os_str} to be recognized as unix"
          assert_equal :linux, Rubik::Platform.os_family
        end
      end
    end
  end

  def test_dev_null
    assert_equal File::NULL, Rubik::Platform.dev_null
  end

  def test_home_dir_and_tmp_dir
    home = Rubik::Platform.home_dir
    refute_nil home
    refute_empty home

    tmp = Rubik::Platform.tmp_dir
    refute_nil tmp
    refute_empty tmp
    assert File.directory?(tmp)
  end

  def test_which_basic
    ruby_bin = Rubik::Platform.which("ruby")
    refute_nil ruby_bin
    assert File.exist?(ruby_bin)

    refute Rubik::Platform.which("non_existent_binary_xyz_12345")
    assert_nil Rubik::Platform.which(nil)
    assert_nil Rubik::Platform.which("")
    assert_nil Rubik::Platform.which("   ")
  end

  def test_which_windows_builtins
    return unless Rubik::Platform.windows?

    assert_equal "echo", Rubik::Platform.which("echo")
    assert_equal "dir", Rubik::Platform.which("dir")
    assert_equal "cls", Rubik::Platform.which("cls")
  end

  def test_to_file_uri_and_from_file_uri
    if Rubik::Platform.windows?
      uri = Rubik::Platform.to_file_uri("C:/project/main.rb")
      assert_equal "file:///C:/project/main.rb", uri

      back_path = Rubik::Platform.from_file_uri("file:///C:/project/main.rb")
      assert_equal "C:/project/main.rb", back_path

      two_slash_path = Rubik::Platform.from_file_uri("file://C:/project/main.rb")
      assert_equal "C:/project/main.rb", two_slash_path

      escaped_path = Rubik::Platform.from_file_uri("file:///C:/my%20project/main.rb")
      assert_equal "C:/my project/main.rb", escaped_path
    else
      uri = Rubik::Platform.to_file_uri("/project/main.rb")
      assert_equal "file:///project/main.rb", uri

      back_path = Rubik::Platform.from_file_uri("file:///project/main.rb")
      assert_equal "/project/main.rb", back_path
    end
  end

  def test_path_normalization_and_comparison
    if Rubik::Platform.windows?
      assert_equal "c:/foo/bar", Rubik::Platform.normalize_path("C:\\FOO\\bar")
      assert Rubik::Platform.path_equal?("C:/Foo/Bar", "c:/foo/bar")
      assert Rubik::Platform.path_under?("C:/Foo/Bar/baz.rb", "c:/foo/bar")
      assert Rubik::Platform.path_under?("C:/Foo/Bar", "c:/foo/bar")
      refute Rubik::Platform.path_under?("C:/Other/baz.rb", "c:/foo/bar")
    else
      assert Rubik::Platform.path_equal?("/foo/bar", "/foo/bar")
      assert Rubik::Platform.path_under?("/foo/bar/baz.rb", "/foo/bar")
      refute Rubik::Platform.path_under?("/other/baz.rb", "/foo/bar")
    end
  end

  def test_dangerous_system_roots_and_drive_root
    roots = Rubik::Platform.dangerous_system_roots
    assert_kind_of Array, roots
    assert_includes roots, Rubik::Platform.normalize_path(Rubik::Platform.home_dir)

    if Rubik::Platform.windows?
      assert Rubik::Platform.drive_root?("C:/")
      assert Rubik::Platform.drive_root?("c:\\")
      assert Rubik::Platform.drive_root?("D:")
      refute Rubik::Platform.drive_root?("C:/Windows/System32")
      assert_includes roots, "c:/"
    else
      refute Rubik::Platform.drive_root?("/etc")
      assert_includes roots, "/etc"
    end
  end

  def test_atomic_write
    target = File.join(@temp_dir, "nested", "sub", "test.txt")

    # Initial write
    Rubik::Platform.atomic_write(target, "initial content")
    assert File.exist?(target)
    assert_equal "initial content", File.read(target)

    # Overwrite existing file
    Rubik::Platform.atomic_write(target, "updated content")
    assert_equal "updated content", File.read(target)
  end

  def test_normalize_newlines
    crlf_text = "line1\r\nline2\r\nline3"
    lf_text = "line1\nline2\nline3"

    assert_equal lf_text, Rubik::Platform.normalize_newlines(crlf_text)
    assert_equal lf_text, Rubik::Platform.normalize_newlines(lf_text)
  end

  def test_kill_tree_windows_uses_array_form_system
    captured = nil
    recorder = lambda do |*args, **kwargs|
      captured = [args, kwargs]
      true
    end

    Rubik::Platform.stub(:windows?, true) do
      Rubik::Platform.stub(:system, recorder) do
        Rubik::Platform.kill_tree(4321)
      end
    end

    refute_nil captured
    assert_equal ["taskkill", "/F", "/T", "/PID", "4321"], captured[0]
    assert_equal({ out: File::NULL, err: File::NULL }, captured[1])
  end

  def test_kill_tree_swallows_system_errors
    boom = lambda do |*_args, **_kwargs|
      raise "boom"
    end

    Rubik::Platform.stub(:windows?, true) do
      Rubik::Platform.stub(:system, boom) do
        assert_nil Rubik::Platform.kill_tree(4321)
      end
    end
  end

  def test_kill_tree_unix_sends_term_then_kill
    signals = []
    recorder = lambda do |sig, pid|
      signals << [sig, pid]
      pid
    end

    Process.stub(:kill, recorder) do
      Rubik::Platform.stub(:windows?, false) do
        Rubik::Platform.kill_tree(1234)
      end
    end

    assert_equal [["TERM", 1234], ["KILL", 1234]], signals
  end

  def test_kill_tree_noop_for_invalid_pids
    called = false
    recorder = lambda do |*_args, **_kwargs|
      called = true
      true
    end

    Rubik::Platform.stub(:windows?, true) do
      Rubik::Platform.stub(:system, recorder) do
        assert_nil Rubik::Platform.kill_tree(nil)
        assert_nil Rubik::Platform.kill_tree(0)
        assert_nil Rubik::Platform.kill_tree(-1)
      end
    end

    refute called
  end
end
