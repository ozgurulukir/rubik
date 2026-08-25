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
    expected = [
      "--- a/file.txt",
      "+++ b/file.txt",
      "@@ -1,0 +1,1 @@",
      "+new content",
      ""
    ].join("\n")

    diff = Rubik::Buffer::Diff.unified_diff("file.txt", nil, "new content\n")
    assert_equal expected, diff
  end

  def test_unified_diff_nil_and_empty_content
    file_path = "lib/example.rb"

    # Both nil
    assert_equal "", Rubik::Buffer::Diff.unified_diff(file_path, nil, nil)

    # Both empty strings
    assert_equal "", Rubik::Buffer::Diff.unified_diff(file_path, "", "")

    # Original nil, new content empty string
    assert_equal "", Rubik::Buffer::Diff.unified_diff(file_path, nil, "")
  end

  def test_unified_diff_addition_from_nil_or_empty
    file_path = "lib/example.rb"
    new_content = "first line\nsecond line\n"

    expected = [
      "--- a/lib/example.rb",
      "+++ b/lib/example.rb",
      "@@ -1,0 +1,2 @@",
      "+first line",
      "+second line",
      ""
    ].join("\n")

    diff_from_nil = Rubik::Buffer::Diff.unified_diff(file_path, nil, new_content)
    assert_equal expected, diff_from_nil

    diff_from_empty = Rubik::Buffer::Diff.unified_diff(file_path, "", new_content)
    assert_equal expected, diff_from_empty
  end

  def test_unified_diff_deletion_to_nil_or_empty
    file_path = "lib/example.rb"
    original = "old line 1\nold line 2\n"

    expected = [
      "--- a/lib/example.rb",
      "+++ b/lib/example.rb",
      "@@ -1,2 +1,0 @@",
      "-old line 1",
      "-old line 2",
      ""
    ].join("\n")

    diff_to_nil = Rubik::Buffer::Diff.unified_diff(file_path, original, nil)
    assert_equal expected, diff_to_nil

    diff_to_empty = Rubik::Buffer::Diff.unified_diff(file_path, original, "")
    assert_equal expected, diff_to_empty
  end

  def test_unified_diff_standard_modification
    file_path = "lib/rubik/buffer/diff.rb"
    original = "line 1\nline 2\n"
    new_content = "line 1\nmodified line 2\nadded line 3\n"

    expected = [
      "--- a/lib/rubik/buffer/diff.rb",
      "+++ b/lib/rubik/buffer/diff.rb",
      "@@ -1,2 +1,3 @@",
      "-line 1",
      "-line 2",
      "+line 1",
      "+modified line 2",
      "+added line 3",
      ""
    ].join("\n")

    diff = Rubik::Buffer::Diff.unified_diff(file_path, original, new_content)
    assert_equal expected, diff
  end

  def test_build_hunk_direct_call
    orig_lines = ["line A\n", "line B\n"]
    new_lines = ["line A\n", "line C\n"]

    hunk = Rubik::Buffer::Diff.build_hunk(orig_lines, new_lines)
    assert_equal [
      "@@ -1,2 +1,2 @@",
      "-line A",
      "-line B",
      "+line A",
      "+line C"
    ], hunk
  end
end
