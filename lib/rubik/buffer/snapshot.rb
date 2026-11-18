# frozen_string_literal: true

require "zlib"
require "json"
require "fileutils"
require "securerandom"
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

      def initialize(storage_dir: File.join(Rubik::Platform.home_dir, ".rubik", "snapshots", "default"))
        @storage_dir = storage_dir
        @snapshots = []
        @current_index = -1
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
        @baseline = buffer_manager.snapshot_state
      end

      def create_snapshot(buffer_manager)
        return nil unless buffer_manager.dirty?

        snapshot = Snapshot.new(files: buffer_manager.snapshot_state)
        # Naming reflects the actual codec: this is Zlib::Deflate (RFC 1951),
        # NOT Zstandard despite the "z" prefix. "zst" was misleading and could
        # fool a tool into trying a zstd decompressor. Kept short to preserve
        # the existing file layout.
        file_path = File.join(@storage_dir, "#{snapshot.id}.zdeflate")
        File.binwrite(file_path, snapshot.compress)

        # Clamp the redo truncation: with @current_index == -1 the range
        # [0..-1] is the WHOLE array, so a fresh snapshot after undoing
        # to empty would be appended after stale snapshots and a later
        # undo would resurrect the discarded edit (issue #544).
        if @current_index < @snapshots.size - 1
          @snapshots = @current_index.negative? ? [] : @snapshots[0..@current_index]
        end

        @snapshots << snapshot
        @current_index = @snapshots.size - 1
        snapshot
      end

      def undo(buffer_manager)
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

      def rollback(snapshot_id, buffer_manager)
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
