# frozen_string_literal: true

require_relative "../test_helper"

class TestContextIndex < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    File.write(File.join(@temp_dir, "lib.rb"), "def hello; end")
    @index = Rubik::Context::Index.new(root_dir: @temp_dir)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_full_scan_and_status
    @index.full_scan
    summary = @index.status_summary

    assert_equal 1, summary[:file_count]
    assert_includes summary[:languages], "ruby"
  end

  def test_incremental_update
    @index.full_scan
    assert_equal "ruby", @index.files["lib.rb"][:language]

    File.write(File.join(@temp_dir, "lib.rb"), "def hello_v2; end")
    updated = @index.update_file("lib.rb")

    assert updated, "update_file should return true when file content changed"
  end

  def test_git_info_mock
    mock_runner = lambda do |cmd|
      if cmd.include?("status")
        [" M lib.rb\n", 0]
      else
        ["", 1]
      end
    end

    git_info = Rubik::Context::GitInfo.new(root_dir: @temp_dir, process_runner: mock_runner)
    FileUtils.mkdir_p(File.join(@temp_dir, ".git"))
    File.write(File.join(@temp_dir, ".git", "HEAD"), "ref: refs/heads/feature/test")

    status = git_info.status
    assert status[:git]
    assert_equal "feature/test", status[:branch]
    assert status[:dirty]
  end

  def test_clean_scan_flags_are_false_in_status_summary
    @index.full_scan

    summary = @index.status_summary

    assert_equal false, summary[:last_scan_aborted]
    assert_nil summary[:last_scan_error]
  end

  def test_aborted_scan_surfaces_in_status_summary_for_both_scan_kinds
    aborted_report = Rubik::Context::Scanner::ScanReport.new(
      aborted: true, reasons: ["directory walk failed under x: RuntimeError: boom"]
    )
    scanner = @index.scanner
    scanner.define_singleton_method(:scan) do |*_args|
      @last_scan_report = aborted_report
      { "lib.rb" => { size: 1, mtime: 1, hash: nil, language: "ruby" } }
    end

    @index.full_scan
    summary = @index.status_summary

    assert summary[:last_scan_aborted]
    assert_includes summary[:last_scan_error], "walk failed"

    @index.incremental_scan

    assert @index.status_summary[:last_scan_aborted], "incremental_scan records the same verdict"
  end

  def test_aborted_then_clean_scan_clears_the_flags
    scanner = @index.scanner
    scanner.define_singleton_method(:scan) do |*_args|
      @last_scan_report = Rubik::Context::Scanner::ScanReport.new(aborted: true, reasons: ["boom"])
      {}
    end
    @index.full_scan
    assert @index.status_summary[:last_scan_aborted]

    scanner.singleton_class.send(:remove_method, :scan)
    @index.full_scan

    assert_equal false, @index.status_summary[:last_scan_aborted]
    assert_nil @index.status_summary[:last_scan_error]
  end

  def test_scanner_without_report_reader_is_treated_as_clean
    bare = Object.new
    def bare.scan(_prev = {}) = {}
    def bare.detect_languages(_files) = []
    @index.instance_variable_set(:@bare_scanner, bare)
    def @index.scanner
      @bare_scanner
    end
    @index.full_scan

    assert_equal false, @index.status_summary[:last_scan_aborted]
  end
end
