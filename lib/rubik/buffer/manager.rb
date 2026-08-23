# frozen_string_literal: true

require "fileutils"
require "digest"
require_relative "diff"

module Rubik
  module Buffer
    class InvalidPathError < StandardError; end

    class Manager
      attr_reader :root_dir, :dirty_files

      def initialize(root_dir: Dir.pwd, event_bus: nil)
        @root_dir = File.expand_path(root_dir)
        @event_bus = event_bus
        @buffer = {}
        @dirty_files = {}
        @original_hashes = {}
      end

      def sanitize_path(path)
        expanded = File.expand_path(path, @root_dir)
        unless expanded.start_with?(@root_dir)
          raise InvalidPathError, "Path traversal attempt blocked: #{path}"
        end

        rel = expanded[@root_dir.bytesize..]
        rel = rel[1..] if rel&.start_with?("/")
        rel.empty? ? "." : rel
      end

      def read(path)
        rel_path = sanitize_path(path)
        return @buffer[rel_path] if @buffer.key?(rel_path)

        full_path = File.join(@root_dir, rel_path)
        return nil unless File.exist?(full_path)

        content = File.read(full_path)
        @original_hashes[rel_path] ||= Digest::SHA256.hexdigest(content)
        content
      end

      def write(path, content)
        rel_path = sanitize_path(path)

        unless @original_hashes.key?(rel_path)
          full_path = File.join(@root_dir, rel_path)
          if File.exist?(full_path)
            @original_hashes[rel_path] = Digest::SHA256.hexdigest(File.read(full_path))
          else
            @original_hashes[rel_path] = nil
          end
        end

        @buffer[rel_path] = content
        @dirty_files[rel_path] = true
        @event_bus&.emit(:buffer_changed, path: rel_path)
        content
      end

      def dirty?
        !@dirty_files.empty?
      end

      def diff_all
        diffs = []
        @dirty_files.keys.each do |rel_path|
          full_path = File.join(@root_dir, rel_path)
          orig_content = File.exist?(full_path) ? File.read(full_path) : ""
          new_content = @buffer[rel_path] || ""
          diffs << Diff.unified_diff(rel_path, orig_content, new_content)
        end
        diffs.join("\n")
      end

      def apply!
        applied_paths = []
        @dirty_files.keys.each do |rel_path|
          full_path = File.join(@root_dir, rel_path)
          content = @buffer[rel_path]

          FileUtils.mkdir_p(File.dirname(full_path))

          tmp_file = "#{full_path}.tmp.#{Process.pid}.#{rand(10000)}"
          File.write(tmp_file, content)
          File.rename(tmp_file, full_path)

          @original_hashes[rel_path] = Digest::SHA256.hexdigest(content)
          applied_paths << rel_path
        end

        @dirty_files.clear
        @event_bus&.emit(:buffer_applied, paths: applied_paths)
        applied_paths
      end

      def reset!
        @buffer.clear
        @dirty_files.clear
        @original_hashes.clear
      end

      def snapshot_state
        state = {}
        @dirty_files.keys.each do |rel_path|
          state[rel_path] = @buffer[rel_path]
        end
        state
      end

      def restore_snapshot_state(state)
        @buffer.clear
        @dirty_files.clear
        state.each do |rel_path, content|
          @buffer[rel_path] = content
          @dirty_files[rel_path] = true
        end
      end
    end
  end
end
