# frozen_string_literal: true

require_relative "../test_helper"

# G13 error-path coverage: Buffer::SnapshotStore failure paths (audit
# 2026-09-29, item 4). Pins that corrupt payloads surface as codec errors and
# that a failed disk write never half-commits the in-memory snapshot list.
class TestBufferSnapshotFailures < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_snapshot_failure")
    @buffer = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    File.write(File.join(@temp_dir, "f.txt"), "content\n")
    @buffer.read("f.txt")
    @buffer.write("f.txt", "buffered\n")
  end

  def teardown
    remove_temp_dir(@temp_dir)
  end

  def test_decompress_raises_codec_error_on_corrupt_payload
    assert_raises(Zlib::Error) { Rubik::Buffer::Snapshot.decompress("definitely not deflate data") }
  end

  def test_unusable_storage_dir_raises_at_construction
    file_as_dir = File.join(@temp_dir, "occupied")
    File.write(file_as_dir, "a file, not a directory")

    assert_raises(StandardError) { Rubik::Buffer::SnapshotStore.new(storage_dir: file_as_dir) }
  end

  def test_failed_disk_write_leaves_snapshot_list_untouched
    store = Rubik::Buffer::SnapshotStore.new(storage_dir: File.join(@temp_dir, "snaps"))

    original_binwrite = File.method(:binwrite)
    failing = lambda do |path, data|
      raise Errno::EACCES, "simulated full disk" if File.extname(path) == ".zdeflate"

      original_binwrite.call(path, data)
    end

    assert_raises(Errno::EACCES) do
      File.stub(:binwrite, failing) { store.create_snapshot(@buffer) }
    end

    assert_empty store.snapshots, "failed write must not append a half-committed snapshot"
    assert_equal(-1, store.instance_variable_get(:@current_index))
  end

  def test_create_snapshot_returns_nil_for_clean_buffer
    store = Rubik::Buffer::SnapshotStore.new(storage_dir: File.join(@temp_dir, "snaps"))
    clean = Rubik::Buffer::Manager.new(root_dir: @temp_dir)

    assert_nil store.create_snapshot(clean)
    assert_empty store.snapshots
  end
end
