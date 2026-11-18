# frozen_string_literal: true

require_relative "../test_helper"

class TestBuffer < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_read_and_write_in_memory_only
    file_path = "src/main.rb"
    disk_path = File.join(@temp_dir, file_path)
    FileUtils.mkdir_p(File.dirname(disk_path))
    File.write(disk_path, "puts 'original'")

    assert_equal "puts 'original'", @manager.read(file_path)

    @manager.write(file_path, "puts 'modified'")
    assert @manager.dirty?
    assert_equal "puts 'modified'", @manager.read(file_path)

    assert_equal "puts 'original'", File.read(disk_path)
  end

  def test_path_traversal_is_blocked
    assert_raises(Rubik::Buffer::InvalidPathError) do
      @manager.write("../../etc/passwd", "evil")
    end
  end

  def test_atomic_apply_flushes_dirty_files_to_disk
    file_path = "lib/code.rb"
    @manager.write(file_path, "def hello; end")
    assert @manager.dirty?

    applied = @manager.apply!
    assert_equal [file_path], applied
    refute @manager.dirty?

    disk_path = File.join(@temp_dir, file_path)
    assert File.exist?(disk_path)
    assert_equal "def hello; end", File.read(disk_path)
  end

  def test_diff_generation
    file_path = "test.txt"
    disk_path = File.join(@temp_dir, file_path)
    File.write(disk_path, "line 1\n")

    @manager.write(file_path, "line 1\nline 2\n")
    diff = @manager.diff_all
    assert_includes diff, "--- a/test.txt"
    assert_includes diff, "+++ b/test.txt"
    assert_includes diff, "+line 2"
  end

  def test_read_and_write_preserve_crlf_bytes
    crlf = "line one\r\nline two\r\n"
    disk_path = File.join(@temp_dir, "crlf.txt")
    File.binwrite(disk_path, crlf)

    assert_equal crlf, @manager.read("crlf.txt"), "read must not normalize CRLF to LF"

    edited = "line one edited\r\nline two\r\n"
    @manager.write("crlf.txt", edited)
    assert_equal edited, @manager.read("crlf.txt"), "write must keep the caller's raw bytes"

    @manager.apply!
    assert_equal edited, File.binread(disk_path), "apply must not rewrite line endings wholesale"
  end

  def test_write_of_crlf_content_keeps_line_endings_on_disk
    crlf = "alpha\r\nbeta\r\n"
    @manager.write("new.txt", crlf)
    @manager.apply!

    assert_equal crlf, File.binread(File.join(@temp_dir, "new.txt"))
  end

  def test_diff_of_crlf_file_shows_only_the_edited_line
    disk_path = File.join(@temp_dir, "crlf.txt")
    File.binwrite(disk_path, "alpha\r\nbeta\r\n")
    @manager.read("crlf.txt")
    @manager.write("crlf.txt", "alpha\r\nBETA\r\n")

    diff = @manager.diff_all
    assert_includes diff, "-beta"
    assert_includes diff, "+BETA"
  end
end
