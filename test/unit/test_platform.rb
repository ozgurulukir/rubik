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
    if Rubik::Platform.windows?
      refute Rubik::Platform.unix?
      refute Rubik::Platform.linux?
      refute Rubik::Platform.macos?
    else
      assert Rubik::Platform.unix?
    end
  end

  def test_dev_null
    if Rubik::Platform.windows?
      assert_equal "NUL", Rubik::Platform.dev_null
    else
      assert_equal "/dev/null", Rubik::Platform.dev_null
    end
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
    if Rubik::Platform.windows?
      assert_equal "echo", Rubik::Platform.which("echo")
      assert_equal "dir", Rubik::Platform.which("dir")
      assert_equal "cls", Rubik::Platform.which("cls")
    end
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
end
