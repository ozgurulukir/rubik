# frozen_string_literal: true

require "zlib"
require "json"
require "fileutils"
require "securerandom"

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

      def initialize(storage_dir: File.join(ENV.fetch("HOME", nil), ".rubik", "snapshots", "default"))
        @storage_dir = storage_dir
        @snapshots = []
        @current_index = -1
        FileUtils.mkdir_p(@storage_dir)
      end

      def create_snapshot(buffer_manager)
        return nil unless buffer_manager.dirty?

        snapshot = Snapshot.new(files: buffer_manager.snapshot_state)
        file_path = File.join(@storage_dir, "#{snapshot.id}.zst")
        File.binwrite(file_path, snapshot.compress)

        @snapshots = @snapshots[0..@current_index] if @current_index < @snapshots.size - 1

        @snapshots << snapshot
        @current_index = @snapshots.size - 1
        snapshot
      end

      def undo(buffer_manager)
        return false if @current_index.negative?

        if @current_index.zero?
          buffer_manager.restore_snapshot_state({})
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
