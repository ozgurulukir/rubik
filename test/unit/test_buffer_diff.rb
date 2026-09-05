# frozen_string_literal: true

require_relative "../test_helper"

class TestBufferDiff < Minitest::Test
  def test_unified_diff_identical_content
    diff = Rubik::Buffer::Diff.unified_diff("file.txt", "same content\n", "same content\n")
    assert_equal "", diff
  end

  def test_unified_diff_nil_and_empty_content
    file_path = "lib/example.rb"

    assert_equal "", Rubik::Buffer::Diff.unified_diff(file_path, nil, nil)
    assert_equal "", Rubik::Buffer::Diff.unified_diff(file_path, "", "")
    assert_equal "", Rubik::Buffer::Diff.unified_diff(file_path, nil, "")
    assert_equal "", Rubik::Buffer::Diff.unified_diff(file_path, "", nil)
  end

  def test_unified_diff_addition_from_nil_or_empty
    file_path = "lib/example.rb"
    new_content = "first line\nsecond line\n"

    expected = [
      "--- a/lib/example.rb",
      "+++ b/lib/example.rb",
      "@@ -0,0 +1,2 @@",
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
      "@@ -1,2 +0,0 @@",
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
    original = "line 1\nline 2\nline 3\n"
    new_content = "line 1\nmodified line 2\nline 3\n"

    expected = [
      "--- a/lib/rubik/buffer/diff.rb",
      "+++ b/lib/rubik/buffer/diff.rb",
      "@@ -1,3 +1,3 @@",
      " line 1",
      "-line 2",
      "+modified line 2",
      " line 3",
      ""
    ].join("\n")

    diff = Rubik::Buffer::Diff.unified_diff(file_path, original, new_content)
    assert_equal expected, diff
  end

  def test_unified_diff_multiple_distinct_hunks
    file_path = "lib/sample.rb"
    orig = (1..20).map { |i| "line #{i}\n" }.join
    new_c = orig.sub("line 2\n", "line 2 changed\n").sub("line 18\n", "line 18 changed\n")

    diff = Rubik::Buffer::Diff.unified_diff(file_path, orig, new_c, context: 2)

    assert_includes diff, "--- a/#{file_path}\n+++ b/#{file_path}\n"
    assert_includes diff, "@@ -1,4 +1,4 @@"
    assert_includes diff, "-line 2\n+line 2 changed"
    assert_includes diff, "@@ -16,5 +16,5 @@"
    assert_includes diff, "-line 18\n+line 18 changed"
    refute_includes diff, "line 10" # Unchanged lines far away should not appear in diff
  end

  def test_unified_diff_overlapping_hunks_merged
    file_path = "lib/sample.rb"
    orig = (1..10).map { |i| "line #{i}\n" }.join
    # Changes are close to each other: line 3 and line 5
    new_c = orig.sub("line 3\n", "line 3 modified\n").sub("line 5\n", "line 5 modified\n")

    diff = Rubik::Buffer::Diff.unified_diff(file_path, orig, new_c, context: 3)

    # Should be merged into a single hunk because context overlaps
    hunk_headers = diff.scan(/^@@ .* @@$/)
    assert_equal 1, hunk_headers.size
    assert_includes diff, "+line 3 modified"
    assert_includes diff, "+line 5 modified"
  end

  def test_unified_diff_custom_zero_context
    file_path = "file.txt"
    orig = "line 1\nline 2\nline 3\n"
    new_c = "line 1\nmodified 2\nline 3\n"

    diff = Rubik::Buffer::Diff.unified_diff(file_path, orig, new_c, context: 0)

    expected = [
      "--- a/file.txt",
      "+++ b/file.txt",
      "@@ -2 +2 @@",
      "-line 2",
      "+modified 2",
      ""
    ].join("\n")

    assert_equal expected, diff
  end
end
