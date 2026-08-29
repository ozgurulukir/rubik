# frozen_string_literal: true

require_relative "../test_helper"

class TestSnapshot < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @snap_dir = Dir.mktmpdir
    @manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @store = Rubik::Buffer::SnapshotStore.new(storage_dir: @snap_dir)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
    FileUtils.remove_entry(@snap_dir)
  end

  def test_compress_decompress_roundtrip
    snapshot = Rubik::Buffer::Snapshot.new(files: { "a.rb" => "content" })
    compressed = snapshot.compress
    decompressed = Rubik::Buffer::Snapshot.decompress(compressed)

    assert_equal snapshot.id, decompressed.id
    assert_equal snapshot.files, decompressed.files
  end

  def test_write_undo_cycle
    @manager.write("a.rb", "v1")
    @store.create_snapshot(@manager)

    @manager.write("a.rb", "v2")
    @store.create_snapshot(@manager)
    assert_equal "v2", @manager.read("a.rb")

    assert @store.undo(@manager)
    assert_equal "v1", @manager.read("a.rb")

    assert @store.undo(@manager)
    refute @manager.dirty?
  end

  def test_rollback_to_specific_snapshot
    @manager.write("a.rb", "v1")
    s1 = @store.create_snapshot(@manager)

    @manager.write("a.rb", "v2")
    @store.create_snapshot(@manager)

    @manager.write("a.rb", "v3")
    @store.create_snapshot(@manager)

    assert @store.rollback(s1.id, @manager)
    assert_equal "v1", @manager.read("a.rb")
  end
end
