# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/buffer/apply_transaction"

# Focused coverage for the extracted two-phase apply transaction (issue
# #472): the loop, conflict skipping, partial-progress failure reports, and
# the on_finish run-report hook — exercised against a stub disk policy,
# without the full Manager dictionary API.
class TestBufferApplyTransaction < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_apply_transaction")
    @events = []
    @event_bus = Rubik::EventBus.new
    [:buffer_apply_conflict, :buffer_containment_blocked, :buffer_garbage_skipped].each do |event|
      @event_bus.subscribe(event) { |payload| @events << [event, payload] }
    end
  end

  def teardown
    remove_temp_dir(@temp_dir)
  end

  # Builds overlay state with an explicit baseline (what the disk contained
  # when the entry was buffered). Entries whose baseline differs from the
  # current disk surface as external conflicts.
  def build_overlay(entries)
    buffer = {}
    dirty_files = {}
    original_hashes = {}
    entries.each do |name, entry|
      # Normalize the baseline through the same pipeline Manager uses, so
      # baselines stay comparable on platforms where File.write emits CRLF
      # (Windows) — otherwise every entry would false-positive as an
      # external conflict and the failure paths would never trigger.
      baseline = entry[:baseline] && Rubik::Platform.normalize_newlines(entry[:baseline])
      original_hashes[name] = baseline && Digest::SHA256.hexdigest(baseline)
      buffer[name] = entry.fetch(:content)
      dirty_files[name] = true
    end
    Rubik::Buffer::ApplyTransaction::Overlay.new(buffer, dirty_files, original_hashes)
  end

  # Minimal stand-in for Manager's disk policy adapter. disk_hash mirrors
  # Manager's exact newline-normalized read path — a raw byte digest would
  # diverge on Windows, where File.write stores CRLF on disk.
  StubPolicy = Struct.new(:root_dir, :contained) do
    def containment_root(_path)
      contained ? [:root, root_dir] : nil
    end

    def disk_hash(rel_path)
      full = File.join(root_dir, rel_path)
      return nil unless File.exist?(full)

      Digest::SHA256.hexdigest(Rubik::Platform.normalize_newlines(Rubik::Platform.read_text(full)))
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def external_modification_policy
      "skip"
    end
  end

  def build_transaction(overlay, contained: true)
    Rubik::Buffer::ApplyTransaction.new(
      overlay: overlay,
      disk_policy: StubPolicy.new(@temp_dir, contained),
      event_bus: @event_bus
    )
  end

  def test_run_writes_dirty_entries_and_clears_overlay
    File.write(File.join(@temp_dir, "a.txt"), "old\n")
    overlay = build_overlay("a.txt" => { content: "new\n", baseline: "old\n" })
    report = []

    result = build_transaction(overlay).run(["a.txt"], "skip") { |*r| report << r }

    assert_equal ["a.txt"], result.applied
    assert_empty result.conflicts
    assert_empty result.skipped
    assert_equal "new\n", File.read(File.join(@temp_dir, "a.txt"))
    refute overlay.dirty_files.key?("a.txt")
    refute overlay.buffer.key?("a.txt")
    assert_equal [[["a.txt"], [], []]], report
  end

  def test_external_conflict_is_skipped_and_reported
    File.write(File.join(@temp_dir, "a.txt"), "externally modified\n")
    overlay = build_overlay("a.txt" => { content: "new\n", baseline: "original baseline\n" })
    transaction = build_transaction(overlay)

    result = transaction.run(["a.txt"], "skip") { |_a, _c, _s| }

    assert_empty result.applied
    assert_equal ["a.txt"], result.conflicts
    assert overlay.dirty_files.key?("a.txt") # stays dirty
    assert_includes @events.map(&:first), :buffer_apply_conflict

    # overwrite policy applies despite the conflict
    result = transaction.run(["a.txt"], "overwrite") { |_a, _c, _s| }
    assert_equal ["a.txt"], result.applied
  end

  def test_write_failure_raises_structured_partial_progress_error
    ["a.txt", "b.txt"].each { |f| File.write(File.join(@temp_dir, f), "old #{f}\n") }
    overlay = build_overlay(
      "a.txt" => { content: "new a\n", baseline: "old a.txt\n" },
      "b.txt" => { content: "new b\n", baseline: "old b.txt\n" }
    )
    report = []
    original_write = Rubik::Platform.method(:atomic_write)
    failing = lambda do |path, content|
      raise Errno::EACCES, "nope" if File.basename(path) == "b.txt"

      original_write.call(path, content)
    end

    transaction = build_transaction(overlay)

    err = assert_raises(Rubik::Buffer::ApplyFailedError) do
      Rubik::Platform.stub(:atomic_write, failing) do
        transaction.run(["a.txt", "b.txt"], "skip") do |applied, conflicts, skipped|
          report << [applied, conflicts, skipped]
        end
      end
    end

    assert_equal :write_failed, err.kind
    assert_equal ["a.txt"], err.applied
    assert_equal "b.txt", err.failed
    assert_empty err.pending
    assert_empty err.conflicts
    # on_finish runs even on failure (the caller's run-report hook)
    assert_equal [[["a.txt"], [], []]], report
    # a.txt stayed applied; b.txt stays dirty for retry
    assert_equal "new a\n", File.read(File.join(@temp_dir, "a.txt"))
    assert overlay.dirty_files.key?("b.txt")
    assert_equal "new b\n", overlay.buffer["b.txt"]
  end

  def test_containment_blocked_at_apply_time_fails_loud
    File.write(File.join(@temp_dir, "a.txt"), "old\n")
    overlay = build_overlay("a.txt" => { content: "new\n", baseline: "old\n" })
    transaction = build_transaction(overlay, contained: false)

    err = assert_raises(Rubik::Buffer::ApplyFailedError) do
      transaction.run(["a.txt"], "skip") { |_a, _c, _s| }
    end

    assert_equal :containment_blocked, err.kind
    assert_includes err.message, "resolves outside all allowed roots"
    assert overlay.dirty_files.key?("a.txt")
    assert_includes @events.map(&:first), :buffer_containment_blocked
  end

  def test_garbage_entry_is_skipped_and_removed_from_overlay
    overlay = build_overlay("bad," => { content: "x\n", baseline: nil })
    transaction = build_transaction(overlay)

    result = transaction.run(["bad,"], "skip") { |_a, _c, _s| }

    assert_empty result.applied
    assert_equal [{ path: "bad,", reason: :path_validator_rejected }], result.skipped
    refute overlay.dirty_files.key?("bad,")
    assert_includes @events.map(&:first), :buffer_garbage_skipped
  end
end
