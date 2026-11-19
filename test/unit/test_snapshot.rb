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

  def test_undo_to_empty_then_new_snapshot_does_not_resurrect_discarded_edit
    @manager.write("a.rb", "discarded")
    @store.create_snapshot(@manager)

    assert @store.undo(@manager)
    refute @manager.dirty?, "undo must return the buffer to the empty baseline"

    @manager.write("a.rb", "kept")
    @store.create_snapshot(@manager)

    assert @store.undo(@manager)
    refute @manager.dirty?, "undo must not restore the edit discarded before the new snapshot"
  end

  def test_recorded_baseline_is_restored_by_undo
    @manager.write("a.rb", "pending edit")
    @store.record_baseline(@manager)
    @store.create_snapshot(@manager)

    @manager.write("a.rb", "proposed fix")
    assert @store.undo(@manager)
    assert_equal "pending edit", @manager.read("a.rb")
  end

  def test_snapshot_preserves_crlf_bytes
    crlf = "a\r\nb\r\n"
    snapshot = Rubik::Buffer::Snapshot.new(files: { "a.rb" => crlf })

    assert_equal crlf, Rubik::Buffer::Snapshot.decompress(snapshot.compress).files["a.rb"]
  end

  def test_default_storage_dir_uses_platform_home_dir
    fake_home = Dir.mktmpdir
    Rubik::Platform.stub(:home_dir, fake_home) do
      store = Rubik::Buffer::SnapshotStore.new

      assert_equal File.join(fake_home, ".rubik", "snapshots", "default"), store.storage_dir
    end
  ensure
    FileUtils.remove_entry(fake_home) if fake_home && File.directory?(fake_home)
  end

  # Issue #589: debounced stores coalesce rapid edits into at most one
  # deflate+disk persist per interval — while undo keeps every step, because
  # undo runs from the in-memory snapshot list, never from the files.
  def test_debounce_coalesces_disk_persists_but_keeps_undo_steps
    store = Rubik::Buffer::SnapshotStore.new(storage_dir: @snap_dir, min_interval: 60.0)
    @manager.snapshot_store = store

    @manager.write("a.rb", "v1")
    assert_equal 1, Dir.children(@snap_dir).size, "the first persist always lands"

    @manager.write("a.rb", "v2")
    assert_equal 2, store.snapshots.size
    assert_equal 1, Dir.children(@snap_dir).size, "a persist inside the debounce window is skipped"

    # Undo granularity is preserved even though the second persist was
    # debounced away.
    assert store.undo(@manager)
    assert_equal "v1", @manager.read("a.rb")
  end

  def test_retention_cap_rotates_old_snapshots_and_files
    store = Rubik::Buffer::SnapshotStore.new(storage_dir: @snap_dir, max_snapshots: 3)
    @manager.snapshot_store = store

    5.times { |i| @manager.write("a.rb", "v#{i}") }

    assert_equal 3, store.snapshots.size, "snapshots beyond the cap are rotated away"

    files = Dir.children(@snap_dir).sort
    assert_equal 3, files.size, "rotated snapshot files are deleted from disk"

    # Undo still walks the retained history in order.
    assert store.undo(@manager)
    assert_equal "v3", @manager.read("a.rb")
    assert store.undo(@manager)
    assert_equal "v2", @manager.read("a.rb")
  end
end
