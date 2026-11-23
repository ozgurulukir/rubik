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
      # JSON cannot emit invalid UTF-8, so binary buffer contents are tagged
      # and hex-encoded before deflate (issue #628 + #629).
      BINARY_MARKER = "__rubik_binary_hex_v1__"

      attr_reader :id, :timestamp, :files, :created_at

      def initialize(id: nil, timestamp: nil, files: {}, created_at: nil)
        now = Time.now
        @id = id || SecureRandom.hex(6)
        @timestamp = timestamp || now.to_i
        # Sub-second creation time orders undo steps made in the same second
        # (issue #629); older files without it fall back to their timestamp.
        @created_at = created_at || (timestamp ? timestamp.to_f : now.to_f)
        @files = files
      end

      def to_h
        {
          "id" => @id,
          "timestamp" => @timestamp,
          "created_at" => @created_at,
          "files" => @files
        }
      end

      def self.from_h(hash)
        new(
          id: hash["id"],
          timestamp: hash["timestamp"],
          created_at: hash["created_at"],
          files: hash["files"] || {}
        )
      end

      def compress
        payload = to_h
        payload["files"] = @files.transform_values { |content| encode_file_content(content) }
        Zlib::Deflate.deflate(JSON.dump(payload))
      end

      def self.decompress(binary_data)
        payload = JSON.parse(Zlib::Inflate.inflate(binary_data))
        payload["files"] = (payload["files"] || {}).transform_values { |value| decode_file_content(value) }
        from_h(payload)
      end

      def encode_file_content(content)
        return content unless content.is_a?(String) && !content.dup.force_encoding(Encoding::UTF_8).valid_encoding?

        { BINARY_MARKER => content.b.unpack1("H*") }
      end

      def self.decode_file_content(value)
        return value unless value.is_a?(Hash) && value.key?(BINARY_MARKER)

        [value[BINARY_MARKER]].pack("H*").force_encoding(Encoding::BINARY)
      end
    end

    class SnapshotStore
      attr_reader :storage_dir, :snapshots

      # Issue #589: in-memory snapshots stay per-edit (undo granularity is
      # untouched), but the whole-buffer deflate+disk persist is debounced to
      # at most one write per interval — the IO is the expensive part. The
      # files are durability artifacts: load_snapshots restores them at
      # startup so undo/rollback survive a restart (issue #629).
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

      # Restores persisted snapshots so undo/rollback work after a restart
      # (issue #629). Called once from the composition root at startup.
      # Defensive: a corrupt or incompatible file is skipped with a warning,
      # never allowed to break buffer startup. Idempotent.
      #
      # @return [Integer] number of snapshots restored
      def load_snapshots
        @monitor.synchronize do
          return @snapshots.size if @snapshots.any?

          entries = Dir.glob(File.join(@storage_dir, "*.zdeflate")).filter_map do |path|
            snapshot = load_snapshot_file(path)
            [path, snapshot] if snapshot
          end
          # Second-resolution timestamps tie for rapid edits and glob order
          # follows random hex ids. created_at carries sub-second precision.
          entries.sort_by! { |_path, snapshot| [snapshot.created_at.to_f, snapshot.timestamp.to_s.to_i] }

          excess = entries.size - @max_snapshots
          entries = entries.drop(excess) if excess.positive?

          @snapshots = entries.map { |_path, snapshot| snapshot }
          @current_index = @snapshots.empty? ? -1 : @snapshots.size - 1
          @snapshots.size
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

      private

      def load_snapshot_file(path)
        snapshot = Snapshot.decompress(File.binread(path))
        return nil unless snapshot.is_a?(Snapshot) && snapshot.files.is_a?(Hash)
        return nil unless snapshot.id.is_a?(String) && !snapshot.id.empty?
        return nil unless snapshot.files.all? { |key, value| key.is_a?(String) && value.is_a?(String) }

        snapshot
      rescue StandardError => e
        warn "[Buffer] skipping unreadable snapshot #{File.basename(path)}: #{e.class}: #{e.message}"
        nil
      end
    end
  end
end
