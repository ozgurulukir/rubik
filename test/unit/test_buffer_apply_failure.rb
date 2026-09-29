# frozen_string_literal: true

require_relative "../test_helper"

# G13 error-path coverage: Buffer::Manager#apply! mid-loop failures (audit
# 2026-09-29, items 1-2). Pins the partial-failure contract: applied entries
# stay applied, unapplied entries stay dirty with content intact, and the
# failure raises rather than pretending the apply completed.
class TestBufferApplyFailure < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_apply_failure")
    @event_bus = Rubik::EventBus.new
    @events = []
    [:buffer_applied, :buffer_apply_conflict, :buffer_containment_blocked, :buffer_garbage_skipped].each do |event|
      @event_bus.subscribe(event) { |payload| @events << [event, payload] }
    end
  end

  def teardown
    remove_temp_dir(@temp_dir)
  end

  def build_manager_with_three_dirty_files
    ["a.txt", "b.txt", "c.txt"].each { |f| File.write(File.join(@temp_dir, f), "original #{f}\n") }
    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, event_bus: @event_bus)
    ["a.txt", "b.txt", "c.txt"].each do |f|
      manager.read(f)
      manager.write(f, "buffered #{f}\n")
    end
    manager
  end

  def test_atomic_write_failure_mid_apply_keeps_earlier_files_and_dirty_tail
    manager = build_manager_with_three_dirty_files

    written = []
    original_write = Rubik::Platform.method(:atomic_write)
    failing_write = lambda do |path, content|
      written << File.basename(path)
      raise Errno::EACCES, "simulated permission loss" if File.basename(path) == "b.txt"

      original_write.call(path, content)
    end

    err = assert_raises(Errno::EACCES) do
      Rubik::Platform.stub(:atomic_write, failing_write) { manager.apply! }
    end
    assert_includes err.message, "simulated permission loss"

    # a.txt applied before the failure: on disk, clean, no longer buffered
    assert_equal "buffered a.txt\n", File.read(File.join(@temp_dir, "a.txt"))
    refute manager.dirty?("a.txt")
    # b.txt and c.txt stay dirty with content intact for a retry
    assert manager.dirty?("b.txt")
    assert manager.dirty?("c.txt")
    assert_equal "buffered b.txt\n", manager.read("b.txt")
    assert_equal "original b.txt\n", File.read(File.join(@temp_dir, "b.txt"))
    # the failure aborted the run: no :buffer_applied event, conflicts not committed
    refute(@events.any? { |(event, _)| event == :buffer_applied })
    assert_empty manager.last_conflicts

    # retry without the fault applies only the remaining entries
    retried = manager.apply!
    assert_equal ["b.txt", "c.txt"], retried.sort
    assert_equal "buffered c.txt\n", File.read(File.join(@temp_dir, "c.txt"))
    refute manager.dirty?("c.txt")
  end

  def test_containment_loss_at_apply_time_raises_and_keeps_entry_dirty
    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, event_bus: @event_bus)
    File.write(File.join(@temp_dir, "safe.txt"), "original\n")
    manager.read("safe.txt")
    manager.write("safe.txt", "buffered\n")

    blocked = [nil, nil]
    err = assert_raises(Rubik::Buffer::InvalidPathError) do
      manager.stub(:containment_root, blocked) { manager.apply! }
    end
    assert_includes err.message, "resolves outside all allowed roots"

    # the entry stays dirty for a retry after remediation
    assert manager.dirty?("safe.txt")
    assert_equal "buffered\n", manager.read("safe.txt")
    # the block is signaled on the bus for operators
    assert(@events.any? { |(event, payload)| event == :buffer_containment_blocked && payload[:path] == "safe.txt" })
  end

  def test_containment_loss_commits_conflicts_seen_so_far
    File.write(File.join(@temp_dir, "conflicted.txt"), "original conflict\n")
    File.write(File.join(@temp_dir, "blocked.txt"), "original\n")

    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, event_bus: @event_bus)
    manager.read("conflicted.txt")
    manager.write("conflicted.txt", "buffered conflict\n")
    manager.read("blocked.txt")
    manager.write("blocked.txt", "buffered blocked\n")
    # external modification AFTER the baseline read -> conflict at apply time
    File.write(File.join(@temp_dir, "conflicted.txt"), "externally modified\n")

    manager.stub(:containment_root, [nil, nil]) do
      assert_raises(Rubik::Buffer::InvalidPathError) { manager.apply! }
    end

    # last_conflicts is committed before the raise so AutoApply readers
    # observe the conflict even on the failure path
    assert_equal ["conflicted.txt"], manager.last_conflicts
    assert manager.dirty?("conflicted.txt")
  end
end
