# frozen_string_literal: true

require_relative "../test_helper"

class TestBufferDiff < Minitest::Test
  def test_build_hunk_basic
    orig_lines = ["line 1\n", "line 2\n"]
    new_lines = ["line 1\n", "line 2 modified\n", "line 3\n"]

    hunk = Rubik::Buffer::Diff.build_hunk(orig_lines, new_lines)

    expected = [
      "@@ -1,2 +1,3 @@",
      "-line 1",
      "-line 2",
      "+line 1",
      "+line 2 modified",
      "+line 3"
    ]

    assert_equal expected, hunk
  end

  def test_build_hunk_empty_orig_lines
    orig_lines = []
    new_lines = ["added line\n"]

    hunk = Rubik::Buffer::Diff.build_hunk(orig_lines, new_lines)

    expected = [
      "@@ -1,0 +1,1 @@",
      "+added line"
    ]

    assert_equal expected, hunk
  end

  def test_build_hunk_empty_new_lines
    orig_lines = ["removed line\n"]
    new_lines = []

    hunk = Rubik::Buffer::Diff.build_hunk(orig_lines, new_lines)

    expected = [
      "@@ -1,1 +1,0 @@",
      "-removed line"
    ]

    assert_equal expected, hunk
  end

  def test_build_hunk_both_empty
    hunk = Rubik::Buffer::Diff.build_hunk([], [])

    expected = [
      "@@ -1,0 +1,0 @@"
    ]

    assert_equal expected, hunk
  end

  def test_build_hunk_lines_without_trailing_newline
    orig_lines = ["no newline orig"]
    new_lines = ["no newline new"]

    hunk = Rubik::Buffer::Diff.build_hunk(orig_lines, new_lines)

    expected = [
      "@@ -1,1 +1,1 @@",
      "-no newline orig",
      "+no newline new"
    ]

    assert_equal expected, hunk
  end

  def test_unified_diff_identical_content
    diff = Rubik::Buffer::Diff.unified_diff("file.txt", "same content\n", "same content\n")
    assert_equal "", diff
  end

  def test_unified_diff_nil_content_handling
    diff = Rubik::Buffer::Diff.unified_diff("file.txt", nil, "new content\n")
    assert_includes diff, "--- a/file.txt"
    assert_includes diff, "+++ b/file.txt"
    assert_includes diff, "@@ -1,0 +1,1 @@"
    assert_includes diff, "+new content"
  end
end
