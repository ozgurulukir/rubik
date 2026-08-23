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
end
