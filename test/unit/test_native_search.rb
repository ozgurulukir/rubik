# frozen_string_literal: true

require_relative "../test_helper"

# Plan 52 Faz B1/C: ripgrep shellout contract and GrepSearchTool gating.
class TestNativeSearch < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    File.write(File.join(@temp_dir, "app.rb"), "def alpha\n  beta\nend\n")
    File.write(File.join(@temp_dir, "notes.md"), "alpha here too\n")
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
    Rubik::Tools::NativeSearch.reset_memoization!
    ENV.delete("RUBIK_RG_PATH")
    ENV.delete("RUBIK_NATIVE")
  end

  def test_search_returns_matches_with_normalized_paths
    res = Rubik::Tools::NativeSearch.search("alpha", root_dir: @temp_dir, max_results: 10)
    skip "rg not installed" if res.nil?

    files = res.map { |m| m[:file] }
    assert_includes files, "app.rb"
    assert_includes files, "notes.md"
    refute files.any? { |f| f.start_with?("./") || f.include?("\\") }, "paths must be relative POSIX"
    assert_equal({ file: "app.rb", line: 1, content: "def alpha" }, res.find { |m| m[:file] == "app.rb" })
  end

  def test_search_empty_result_is_empty_array_not_nil
    res = Rubik::Tools::NativeSearch.search("zzz_never_here", root_dir: @temp_dir)
    skip "rg not installed" if res.nil?

    assert_equal [], res
  end

  def test_case_sensitivity_flag
    insensitive = Rubik::Tools::NativeSearch.search("ALPHA", root_dir: @temp_dir)
    skip "rg not installed" if insensitive.nil?
    assert_equal 2, insensitive.size

    sensitive = Rubik::Tools::NativeSearch.search("ALPHA", root_dir: @temp_dir, case_sensitive: true)
    assert_equal [], sensitive
  end

  def test_max_results_caps_and_signals_trust
    20.times { |i| File.write(File.join(@temp_dir, "f#{i}.rb"), "alpha #{i}") }
    res = Rubik::Tools::NativeSearch.search("alpha", root_dir: @temp_dir, max_results: 5)
    skip "rg not installed" if res.nil?

    assert_equal 5, res.size
  end

  def test_invalid_regex_is_untrusted_nil_not_wrong_result
    # An unbalanced group is a valid Ruby RegexpError→escape in the tool, but
    # a bare "(" is also invalid for rg: rg exits 2 → untrusted → nil.
    assert_nil Rubik::Tools::NativeSearch.search("(", root_dir: @temp_dir)
  end

  def test_unavailable_rg_falls_to_nil_and_path_override
    with_env("RUBIK_RG_PATH", "definitely-not-a-binary-xyz") do
      Rubik::Tools::NativeSearch.reset_memoization!
      # The override is trusted at resolution time, but a bogus binary must
      # degrade: spawn fails → untrusted → nil (caller falls back).
      assert_nil Rubik::Tools::NativeSearch.search("x", root_dir: @temp_dir)
    end
  end

  def test_runner_injection_and_explicit_path_stdin_guard
    captured = {}
    runner = lambda do |argv, root|
      captured[:argv] = argv
      captured[:root] = root
      ["app.rb:1:def alpha"]
    end

    res = Rubik::Tools::NativeSearch.search("alpha", root_dir: @temp_dir, runner: runner, max_results: 1)
    assert_equal [{ file: "app.rb", line: 1, content: "def alpha" }], res

    # Windows stdin trap regression (Plan 52 §2.4): the search target must be
    # an explicit path argument — never omitted, or rg searches stdin and
    # silently returns nothing.
    assert_equal @temp_dir, captured[:root]
    assert_equal ".", captured[:argv].last
    assert_includes captured[:argv], "-e"
    assert_equal "alpha", captured[:argv][captured[:argv].index("-e") + 1]
  end

  def test_parse_line_keeps_colons_in_path_and_content
    m = Rubik::Tools::NativeSearch.parse_line("we:ird/dir.rb:12:a:b: c", root_dir: @temp_dir)
    assert_equal "we:ird/dir.rb", m[:file]
    assert_equal 12, m[:line]
    assert_equal "a:b: c", m[:content]
    assert_nil Rubik::Tools::NativeSearch.parse_line("garbage without colons")
  end

  # A matched CONTENT line containing ":digits:" (timestamps!) must not
  # hijack the line number: the first :digits: boundary after a REAL file
  # wins over a greedy split.
  def test_parse_line_timestamp_in_content_does_not_hijack_line_number
    FileUtils.mkdir_p(File.join(@temp_dir, "log"))
    File.write(File.join(@temp_dir, "log", "app.rb"), "ignored")
    m = Rubik::Tools::NativeSearch.parse_line("log/app.rb:10:ts = 12:34:56", root_dir: @temp_dir)
    assert_equal "log/app.rb", m[:file]
    assert_equal 10, m[:line]
    assert_equal "ts = 12:34:56", m[:content]
  end

  def test_parse_line_backslash_paths_normalized
    m = Rubik::Tools::NativeSearch.parse_line("lib\\util.rb:3:content")
    assert_equal "lib/util.rb", m[:file]
  end

  def test_blank_rg_path_override_treated_as_unset
    with_env("RUBIK_RG_PATH", "") do
      Rubik::Tools::NativeSearch.reset_memoization!
      # An empty override must not be memoized as a bogus binary.
      res = Rubik::Tools::NativeSearch.search("alpha", root_dir: @temp_dir)
      skip "rg not installed" if res.nil? && !Rubik::Tools::NativeSearch.available?
      assert res.is_a?(Array)
    end
  end

  def test_enabled_switch
    assert Rubik::Tools::NativeSearch.enabled?(nil)
    assert Rubik::Tools::NativeSearch.enabled?("auto")
    refute Rubik::Tools::NativeSearch.enabled?("off")
    refute Rubik::Tools::NativeSearch.enabled?("auto", env: { "RUBIK_NATIVE" => "off" })
  end

  private

  def with_env(key, value)
    old = ENV.fetch(key, nil)
    ENV[key] = value
    yield
  ensure
    old.nil? ? ENV.delete(key) : ENV[key] = old
  end
end

class TestGrepSearchToolNativeGating < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    File.write(File.join(@temp_dir, "app.rb"), "needle one\ntwo\n")
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @index = Rubik::Context::Index.new(root_dir: @temp_dir)
    @index.full_scan
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
    ENV.delete("RUBIK_NATIVE")
    Rubik::Tools::NativeSearch.reset_memoization!
  end

  def test_off_switch_never_spawns_rg
    spy = SearchSpy.new
    tool = Rubik::Tools::GrepSearchTool.new(@buffer_manager, @index, root_dir: @temp_dir, config: FakeConfig.new("off"))
    stub_search(spy) do
      res = tool.execute({ "query" => "needle" })
      assert_includes res, "needle one"
      assert_empty spy.calls, "tools.native: off must never spawn rg"
    end
  end

  def test_native_results_exclude_dirty_buffer_stale_content
    @buffer_manager.write("app.rb", "fresh needle only\n")
    tool = Rubik::Tools::GrepSearchTool.new(@buffer_manager, @index, root_dir: @temp_dir, config: FakeConfig.new("auto"))
    stub_search(SearchSpy.new([{ file: "app.rb", line: 1, content: "stale needle from disk" }])) do
      res = tool.execute({ "query" => "needle" })
      assert_includes res, "fresh needle only"
      refute_includes res, "stale needle", "dirty files must be re-scanned from buffer, not disk"
    end
  end

  def test_additional_roots_gate_disables_native
    @index.additional_roots = [@temp_dir]
    spy = SearchSpy.new
    tool = Rubik::Tools::GrepSearchTool.new(@buffer_manager, @index, root_dir: @temp_dir, config: FakeConfig.new("auto"))
    stub_search(spy) do
      tool.execute({ "query" => "needle" })
      assert_empty spy.calls, "additional roots must force the pure-Ruby path"
    end
  end

  def test_untrusted_native_run_falls_back
    tool = Rubik::Tools::GrepSearchTool.new(@buffer_manager, @index, root_dir: @temp_dir, config: FakeConfig.new("auto"))
    stub_search(SearchSpy.new(nil)) do
      res = tool.execute({ "query" => "needle" })
      assert_includes res, "needle one", "fallback must render the result when rg is untrusted"
    end
  end

  private

  # Scripts NativeSearch.search so gating is tested without a real rg —
  # results acts as the return value (nil = untrusted run).
  def stub_search(spy)
    Rubik::Tools::NativeSearch.singleton_class.send(:alias_method, :orig_search, :search)
    Rubik::Tools::NativeSearch.singleton_class.send(:define_method, :search) do |*args|
      spy.calls << args
      spy.results
    end
    yield
  ensure
    Rubik::Tools::NativeSearch.singleton_class.send(:alias_method, :search, :orig_search)
    Rubik::Tools::NativeSearch.singleton_class.send(:remove_method, :orig_search)
  end

  class SearchSpy
    attr_reader :calls, :results

    def initialize(results = [])
      @calls = []
      @results = results
    end
  end

  class FakeConfig
    def initialize(value)
      @value = value
    end

    def fetch(_key, _default = nil)
      @value
    end
  end
end
