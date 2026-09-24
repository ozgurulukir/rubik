# frozen_string_literal: true

require_relative "../test_helper"

class TestPathContainment < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
  end

  def teardown
    remove_temp_dir(@temp_dir)
  end

  def test_resolved_path_matches_realpath_for_existing_paths
    assert Rubik::Platform.path_equal?(File.realpath(@temp_dir), Rubik::Platform.resolved_path(@temp_dir))
  end

  def test_resolved_path_appends_missing_tail_lexically
    resolved = Rubik::Platform.resolved_path(File.join(@temp_dir, "brand", "new", "file.rb"))

    assert Rubik::Platform.path_under?(resolved, @temp_dir),
           "a missing tail cannot be a symlink; the deepest existing ancestor carries the verdict"
  end

  def test_resolved_path_under_detects_symlink_escape_that_lexical_prefix_misses
    outside = Dir.mktmpdir
    begin
      link = File.join(@temp_dir, "escape")
      try_symlink(outside, link)

      assert Rubik::Platform.path_under?(File.join(link, "x.rb"), @temp_dir),
             "lexical check is prefix-only — the documented blindness"
      refute Rubik::Platform.resolved_path_under?(File.join(link, "x.rb"), @temp_dir)
    ensure
      remove_temp_dir(outside)
    end
  end

  def test_symlinked_root_itself_produces_no_false_positive
    outside = Dir.mktmpdir
    begin
      real_root = File.join(outside, "project")
      Dir.mkdir(real_root)
      link_root = File.join(@temp_dir, "linkedroot")
      try_symlink(real_root, link_root)

      manager = Rubik::Buffer::Manager.new(root_dir: link_root)
      manager.write("file.rb", "ok")
      manager.apply!

      assert File.exist?(File.join(real_root, "file.rb")),
             "resolving BOTH sides means a symlinked workspace root keeps working"
    ensure
      remove_temp_dir(outside)
    end
  end
end
