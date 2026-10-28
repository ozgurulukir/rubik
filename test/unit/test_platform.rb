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

  def test_macos_predicate
    darwin_variants = [
      "darwin",
      "darwin20.0",
      "DARWIN21",
      "darwin22.6.0",
      "x86_64-darwin20",
      "arm64-darwin23.1.0"
    ]

    darwin_variants.each do |os_str|
      Rubik::Platform.stub(:host_os, os_str) do
        assert_equal true, Rubik::Platform.macos?, "Expected macos? to return true for #{os_str}"
      end
    end

    non_darwin_variants = [
      "linux",
      "linux-gnu",
      "linux-musl",
      "mswin32",
      "mingw32",
      "cygwin",
      "bccwin",
      "wince",
      "freebsd13.0",
      "openbsd6.8",
      "netbsd",
      "solaris2.11",
      "sunos5.11",
      ""
    ]

    non_darwin_variants.each do |os_str|
      Rubik::Platform.stub(:host_os, os_str) do
        assert_equal false, Rubik::Platform.macos?, "Expected macos? to return false for #{os_str}"
      end
    end

    expected = !(Rubik::Platform.host_os =~ /darwin/i).nil?
    assert_equal expected, Rubik::Platform.macos?
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

  def test_atomic_write_retries_transient_rename_failures
    # G13: the Windows transient-lock retry arm — rename fails twice with a
    # SystemCallError, then the real rename succeeds on attempt three.
    target = File.join(@temp_dir, "retry.txt")
    calls = 0
    real_rename = File.method(:rename)
    File.stub(:rename, lambda { |src, dst|
      calls += 1
      raise Errno::EACCES if calls <= 2

      real_rename.call(src, dst)
    }) do
      capture_io do
        Rubik::Platform.atomic_write(target, "retry-body")
      end
    end

    assert_equal "retry-body", File.read(target)
    assert_equal 3, calls
    assert_empty Dir.glob("#{target}.tmp.*"), "temp file must be cleaned up after success"
  end

  def test_atomic_write_falls_back_to_binwrite_when_rename_always_fails
    # G13: rename exhausts all retries -> debug_warn + direct binwrite; the
    # content still lands and no temp file is left behind.
    target = File.join(@temp_dir, "fallback.txt")
    File.stub(:rename, ->(*, **) { raise Errno::EACCES }) do
      capture_io do
        Rubik::Platform.atomic_write(target, "fallback-body")
      end
    end

    assert_equal "fallback-body", File.read(target)
    assert_empty Dir.glob("#{target}.tmp.*")
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

  def test_kill_tree_terminates_descendant_processes_on_unix
    return if Rubik::Platform.windows?

    parent_pid = spawn("bash", "-c", "sleep 30 & wait")
    sleep 0.15
    children = Rubik::Platform.descendant_pids(parent_pid)
    Rubik::Platform.kill_tree(parent_pid)
    begin
      Process.wait(parent_pid)
    rescue StandardError
      nil
    end
    sleep 0.1

    refute system("kill -0 #{parent_pid} 2>/dev/null"), "parent #{parent_pid} must be terminated"
    children.each do |cpid|
      alive = system("kill -0 #{cpid} 2>/dev/null")
      if alive
        begin
          Process.kill("KILL", cpid)
        rescue StandardError
          nil
        end
      end
      refute alive, "descendant process #{cpid} must be terminated by kill_tree"
    end
  end

  # ------------------------------------------------------------------
  # Pin tests for previously uncovered methods (Plan 86 D-4)
  # ------------------------------------------------------------------

  def test_debug_warn
    # Default: silent
    begin
      Rubik::Platform.debug_warn("silent")
    rescue => e
      flunk("debug_warn raised: #{e.message}")
    end

    # With RUBIK_DEBUG set, emits to $stderr
    ENV["RUBIK_DEBUG"] = "1"
    begin
      captured = nil
      old_stderr = $stderr
      $stderr = StringIO.new
      Rubik::Platform.debug_warn("test warning")
      captured = $stderr.string
    ensure
      $stderr = old_stderr
      ENV.delete("RUBIK_DEBUG")
    end

    assert_includes captured, "[WARN] test warning"
  end

  def test_debug_warn_survives_verbose_nil
    # Kernel#warn is silenced when $VERBOSE is nil (bundler/rake -W0); the
    # RUBIK_DEBUG channel must stay audible there. Regression pin.
    old_verbose = $VERBOSE
    $VERBOSE = nil
    ENV["RUBIK_DEBUG"] = "1"
    captured = nil
    old_stderr = $stderr
    begin
      $stderr = StringIO.new
      Rubik::Platform.debug_warn("verbose-nil warning")
      captured = $stderr.string
    ensure
      $stderr = old_stderr
      ENV.delete("RUBIK_DEBUG")
      $VERBOSE = old_verbose
    end

    assert_includes captured, "[WARN] verbose-nil warning"
  end

  def test_pathext
    original = ENV.fetch("PATHEXT", nil)
    begin
      ENV["PATHEXT"] = ".EXE;.BAT;.CMD"
      assert_equal [".exe", ".bat", ".cmd"], Rubik::Platform.pathext
    ensure
      if original
        ENV["PATHEXT"] = original
      else
        ENV.delete("PATHEXT")
      end
    end
  end

  def test_pathext_default
    original = ENV.fetch("PATHEXT", nil)
    begin
      ENV.delete("PATHEXT")
      expected = [".com", ".exe", ".bat", ".cmd", ".vbs", ".js", ".ws", ".msc", ".ps1"]
      assert_equal expected, Rubik::Platform.pathext
    ensure
      ENV["PATHEXT"] = original if original
    end
  end

  def test_executable_file?
    # Non-existent file returns false
    refute Rubik::Platform.executable_file?("/nonexistent/path/to/file_xyz_12345")

    # A directory is not a file
    refute Rubik::Platform.executable_file?(Dir.pwd)
  end

  def test_normalize_path_raw
    # Backslashes become forward slashes (relative to current dir)
    assert_equal "#{Dir.pwd}/home/user/project", Rubik::Platform.normalize_path_raw("home\\user\\project")
    # Expands relative paths
    assert_equal Dir.pwd, Rubik::Platform.normalize_path_raw(".")
    # Already-normalized stays the same (root-relative resolves onto the
    # CURRENT drive's root — D: on GH runners, C: locally)
    if Rubik::Platform.windows?
      assert_equal "#{Dir.pwd[0, 1]}:/foo/bar", Rubik::Platform.normalize_path_raw("/foo/bar")
    else
      assert_equal "/foo/bar", Rubik::Platform.normalize_path_raw("/foo/bar")
    end
  end

  # Sanitize family tests

  def test_xml_escape
    assert_equal "a &amp; b", Rubik::Platform.xml_escape("a & b")
    assert_equal "&lt;div&gt;", Rubik::Platform.xml_escape("<div>")
    assert_equal "plain", Rubik::Platform.xml_escape("plain")
    assert_equal "", Rubik::Platform.xml_escape(nil)
  end

  def test_clean_utf8
    # Valid UTF-8 passes through unchanged
    assert_equal "hello world", Rubik::Platform.clean_utf8("hello world")

    # Invalid byte sequence is scrubbed
    result = Rubik::Platform.clean_utf8("hello\xffworld")
    assert_equal "helloworld", result

    # Non-string input passes through unchanged
    assert_equal 42, Rubik::Platform.clean_utf8(42)
    assert_nil Rubik::Platform.clean_utf8(nil)
  end

  def test_safe_utf8
    # Valid UTF-8 passes through unchanged
    assert_equal "merhaba dünya", Rubik::Platform.safe_utf8("merhaba dünya")

    # Binary-tagged UTF-8 bytes are re-tagged with multibyte content kept
    # (clean_utf8 would strip them as undefined when converting from binary)
    binary = "geçersiz istek 🎉".b
    result = Rubik::Platform.safe_utf8(binary)
    assert_equal Encoding::UTF_8, result.encoding
    assert_equal "geçersiz istek 🎉", result
    assert_equal Encoding::ASCII_8BIT, binary.encoding

    # Invalid byte sequences are scrubbed to a valid string
    result = Rubik::Platform.safe_utf8("hata:\xFF".b)
    assert_equal Encoding::UTF_8, result.encoding
    assert_predicate result, :valid_encoding?
    assert_equal "hata:", result

    # Non-string input passes through unchanged
    assert_equal 42, Rubik::Platform.safe_utf8(42)
    assert_nil Rubik::Platform.safe_utf8(nil)
  end

  def test_clean_utf8_deep
    data = {
      "name" => "test\xff",
      "nested" => { "key" => "value\xff" },
      "array" => ["a\xff", "b"],
      "symbol" => :test,
      "number" => 42
    }

    cleaned = Rubik::Platform.clean_utf8_deep(data)

    assert_equal "test", cleaned["name"]
    assert_equal "value", cleaned["nested"]["key"]
    assert_equal ["a", "b"], cleaned["array"]
    assert_equal :test, cleaned["symbol"]
    assert_equal 42, cleaned["number"]
  end

  def test_clean_utf8_deep_circular
    obj = {}
    obj[:self] = obj
    result = Rubik::Platform.clean_utf8_deep(obj)
    assert_equal "{...}", result[:self]
  end

  def test_clean_utf8_deep_circular_array
    arr = [1, 2]
    arr << arr
    result = Rubik::Platform.clean_utf8_deep(arr)
    assert_equal "[...]", result.last
  end

  def test_clean_utf8_deep_binary_symbols_are_stripped_like_strings
    # ASCII-8BIT names always report valid_encoding?; the symbol fast path
    # must not let them through raw — high bytes are stripped exactly like
    # the string path (clean_utf8) would.
    bin_sym = "caf\xE9".b.to_sym
    cleaned = Rubik::Platform.clean_utf8_deep({ bin_sym => [bin_sym] })

    key = cleaned.keys.first
    assert_equal :caf, key
    assert_equal [:caf], cleaned[key]

    # UTF-8 symbols keep the fast path's zero-allocation pass-through.
    valid_sym = :café
    assert_same valid_sym, Rubik::Platform.clean_utf8_deep(valid_sym)
  end

  def test_safe_json_generate
    # Normal data works
    assert_equal '{"a":1}', Rubik::Platform.safe_json_generate({ "a" => 1 })

    # Invalid UTF-8 is cleaned before JSON generation
    result = Rubik::Platform.safe_json_generate({ "key" => "bad\xff" })
    parsed = JSON.parse(result)
    assert_equal "bad", parsed["key"]
  end

  def test_safe_json_generate_fallback
    # Unencodable object falls back gracefully
    unencodable = Object.new
    result = Rubik::Platform.safe_json_generate({ "obj" => unencodable })
    parsed = JSON.parse(result)
    assert parsed["obj"].is_a?(String)
  end

  def test_safe_json_dump
    result = Rubik::Platform.safe_json_dump({ "a" => 1 })
    assert_equal '{"a":1}', result.chomp
  end

  def test_safe_json_dump_fallback
    unencodable = Object.new
    result = Rubik::Platform.safe_json_dump({ "obj" => unencodable })
    parsed = JSON.parse(result)
    assert parsed["obj"].is_a?(String)
  end

  # Fake target for File.open whose fsync explodes mid-atomic-write.
  class FsyncBoomIO
    def write(*) = 1

    def flush = true

    def fsync = raise IOError, "fsync boom"

    def close = true
  end

  def test_atomic_write_survives_fsync_failure
    target = File.join(@temp_dir, "fsync_target.txt")
    File.stub(:open, ->(*, **, &blk) { blk.call(FsyncBoomIO.new) }) do
      Rubik::Platform.atomic_write(target, "payload")
    end

    assert_equal "payload", File.read(target), "the rename must still land the content"
  end

  def test_atomic_write_survives_cleanup_rm_f_failure
    target = File.join(@temp_dir, "rmf_target.txt")

    FileUtils.stub(:rm_f, ->(*) { raise IOError, "rm boom" }) do
      Rubik::Platform.atomic_write(target, "kept")
    end

    assert_equal "kept", File.read(target)
  end

  def test_kill_tree_unix_branch_survives_missing_pid
    capture_io do
      Rubik::Platform.stub(:windows?, false) do
        Rubik::Platform.kill_tree(999_999_999_999)
      end
    end
  end

  def test_direct_child_pids_basic
    pids = Rubik::Platform.send(:direct_child_pids, Process.pid)
    assert_kind_of Array, pids
    assert(pids.all? { |p| p.is_a?(Integer) && p.positive? })
  end

  def test_direct_child_pids_command_injection_prevention
    sentinel = File.join(@temp_dir, "injected_sentinel.txt")
    payload = "1; touch #{sentinel}"

    pids = Rubik::Platform.send(:direct_child_pids, payload)
    assert_equal [], pids
    refute File.exist?(sentinel), "Command injection payload must not be executed by shell"
  end
end
