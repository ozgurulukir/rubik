# frozen_string_literal: true

require "zlib"
require "json"
require "fileutils"
require "securerandom"
require "monitor"
require_relative "../platform"

module Rubik
  module Buffer
    class Snapshot
      attr_reader :id, :timestamp, :files

      def initialize(id: nil, timestamp: nil, files: {})
        @id = id || SecureRandom.hex(6)
        @timestamp = timestamp || Time.now.to_i
        @files = files
      end

      def to_h
        {
          "id" => @id,
          "timestamp" => @timestamp,
          "files" => @files
        }
      end

      def self.from_h(hash)
        new(
          id: hash["id"],
          timestamp: hash["timestamp"],
          files: hash["files"] || {}
        )
      end

      def compress
        Zlib::Deflate.deflate(JSON.dump(to_h))
      end

      def self.decompress(binary_data)
        decompressed = Zlib::Inflate.inflate(binary_data)
        from_h(JSON.parse(decompressed))
      end
    end

    class SnapshotStore
      attr_reader :storage_dir, :snapshots

      # Issue #589: in-memory snapshots stay per-edit (undo granularity is
      # untouched), but the whole-buffer deflate+disk persist is debounced to
      # at most one write per interval — the IO is the expensive part and the
      # files are durability artifacts, never read back by undo/rollback.
      # 0 disables debouncing (the historical per-write persistence, still
      # the default so standalone/test stores keep exact per-edit durability).
      DEFAULT_MIN_INTERVAL = 0.0
      # On-disk retention cap: once exceeded, the oldest snapshot files are
      # rotated away (their undo reach is lost, same as an expired redo
      # tail). Keeps a long session from accumulating unbounded snapshot
      # files (issue #589).
      DEFAULT_MAX_SNAPSHOTS = 200

      def initialize(storage_dir: File.join(Rubik::Platform.home_dir, ".rubik", "snapshots", "default"),
                     min_interval: DEFAULT_MIN_INTERVAL,
                     max_snapshots: DEFAULT_MAX_SNAPSHOTS)
        @storage_dir = storage_dir
        @min_interval = min_interval.to_f
        @max_snapshots = [max_snapshots.to_i, 1].max
        @snapshots = []
        @current_index = -1
        @last_file_write_at = nil
        # The store is written from the manager's write path (outside the
        # manager monitor, issue #589) and read by undo/rollback; guard its
        # own index/file state independently.
        @monitor = Monitor.new
        # The state undo-to-beginning restores. Defaults to a clean
        # buffer; consumers that snapshot a pre-existing dirty buffer
        # (e.g. Repair::Loop) record that state explicitly so an aborted
        # operation restores the pending edits instead of wiping them
        # (issue #544).
        @baseline = {}
        FileUtils.mkdir_p(@storage_dir)
      end

      # Records the state that a full undo should restore. Call once,
      # before the first snapshot, when the buffer already holds edits
      # that must survive an aborted operation.
      def record_baseline(buffer_manager)
        @monitor.synchronize do
          @baseline = buffer_manager.snapshot_state
        end
      end

      def create_snapshot(buffer_manager)
        @monitor.synchronize do
          return nil unless buffer_manager.dirty?

          snapshot = Snapshot.new(files: buffer_manager.snapshot_state)

          # Persist BEFORE any list mutation (issue #476 tranche 2): a failed
          # disk write must leave the in-memory snapshot list untouched.
          # Persistence is debounced (issue #589) — a skip inside the window
          # costs only crash-durability granularity, never an undo step.
          persist_snapshot(snapshot)

          # Clamp the redo truncation: with @current_index == -1 the range
          # [0..-1] is the WHOLE array, so a fresh snapshot after undoing
          # to empty would be appended after stale snapshots and a later
          # undo would resurrect the discarded edit (issue #544).
          if @current_index < @snapshots.size - 1
            @snapshots = @current_index.negative? ? [] : @snapshots[0..@current_index]
          end

          @snapshots << snapshot
          @current_index = @snapshots.size - 1

          rotate_expired_snapshots
          snapshot
        end
      end

      # Debounced persistence (issue #589): at most one deflate+binwrite per
      # interval. Undo/rollback run from the in-memory snapshot list, so a
      # skipped persist costs only crash-durability granularity, never an
      # undo step.
      def persist_snapshot(snapshot)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return false if @min_interval.positive? && @last_file_write_at && now - @last_file_write_at < @min_interval

        # Naming reflects the actual codec: this is Zlib::Deflate (RFC 1951),
        # NOT Zstandard despite the "z" prefix. "zst" was misleading and could
        # fool a tool into trying a zstd decompressor. Kept short to preserve
        # the existing file layout.
        File.binwrite(File.join(@storage_dir, "#{snapshot.id}.zdeflate"), snapshot.compress)
        @last_file_write_at = now
        true
      end

      # Retention cap (issue #589): drop the oldest snapshots beyond the cap
      # and unlink their files. Only undo-unreachable entries may be dropped:
      # @current_index is shifted so it keeps pointing at the same logical
      # snapshot, and a shift below zero folds into the baseline restore.
      def rotate_expired_snapshots
        excess = @snapshots.size - @max_snapshots
        return if excess <= 0

        dropped = @snapshots.shift(excess)
        @current_index -= excess
        @current_index = -1 if @current_index.negative?
        dropped.each do |snapshot|
          File.delete(File.join(@storage_dir, "#{snapshot.id}.zdeflate"))
        rescue SystemCallError
          nil
        end
      end

      def undo(buffer_manager)
        @monitor.synchronize do
          return false if @current_index.negative?

          if @current_index.zero?
            buffer_manager.restore_snapshot_state(@baseline)
            @current_index = -1
            return true
          end

          @current_index -= 1
          prev_snapshot = @snapshots[@current_index]
          buffer_manager.restore_snapshot_state(prev_snapshot.files)
          true
        end
      end

      def rollback(snapshot_id, buffer_manager)
        @monitor.synchronize do
          target_idx = @snapshots.index { |s| s.id == snapshot_id }
          return false unless target_idx

          target_snapshot = @snapshots[target_idx]
          buffer_manager.restore_snapshot_state(target_snapshot.files)
          @current_index = target_idx
          true
        end
      end
    end
  end
end
