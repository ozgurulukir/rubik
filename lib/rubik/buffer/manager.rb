# frozen_string_literal: true

require "fileutils"
require "digest"
require "set"
require_relative "diff"

module Rubik
  module Buffer
    class InvalidPathError < StandardError; end

    class Manager
      attr_reader :root_dir, :dirty_files, :additional_roots, :rw_roots, :allowed_external_dirs, :rw_allowed_dirs
      attr_accessor :allow_external_writes

      def initialize(root_dir: Dir.pwd, additional_roots: [], allowed_external_dirs: [], allow_external_writes: false, event_bus: nil)
        @root_dir = File.expand_path(root_dir)
        @additional_roots = (additional_roots || []).map { |r| File.expand_path(r.to_s, @root_dir) }.uniq
        @allowed_external_dirs = (allowed_external_dirs || []).map { |d| File.expand_path(d.to_s, @root_dir) }.uniq
        @allow_external_writes = allow_external_writes || false
        @rw_roots = Set.new
        @rw_allowed_dirs = Set.new(@allowed_external_dirs)
        @event_bus = event_bus
        @buffer = {}
        @dirty_files = {}
        @original_hashes = {}
      end

      def add_root(path, rw: false)
        expanded = File.expand_path(path.to_s, @root_dir)
        @additional_roots << expanded unless @additional_roots.include?(expanded)
        if rw
          @rw_roots << expanded
        else
          @rw_roots.delete(expanded)
        end
        expanded
      end

      def remove_root(path)
        expanded = File.expand_path(path.to_s, @root_dir)
        @additional_roots.delete(expanded)
        @rw_roots.delete(expanded)
        expanded
      end

      def add_allowed_dir(path, rw: true)
        expanded = File.expand_path(path.to_s, @root_dir)
        @allowed_external_dirs << expanded unless @allowed_external_dirs.include?(expanded)
        if rw
          @rw_allowed_dirs << expanded
        else
          @rw_allowed_dirs.delete(expanded)
        end
        expanded
      end

      def remove_allowed_dir(path)
        expanded = File.expand_path(path.to_s, @root_dir)
        @allowed_external_dirs.delete(expanded)
        @rw_allowed_dirs.delete(expanded)
        expanded
      end

      def sanitize_path(path, for_write: false)
        expanded = File.expand_path(path.to_s, @root_dir)
        allowed_roots = [@root_dir] + @additional_roots.map { |r| File.expand_path(r.to_s, @root_dir) }
        allowed_exts = @allowed_external_dirs.map { |d| File.expand_path(d.to_s, @root_dir) }

        matched_root = allowed_roots.find { |r| expanded == r || expanded.start_with?("#{r}/") }
        matched_ext = allowed_exts.find { |d| expanded == d || expanded.start_with?("#{d}/") } unless matched_root

        unless matched_root || matched_ext
          all_allowed = (allowed_roots + allowed_exts).uniq
          raise InvalidPathError, "Path traversal attempt blocked: '#{path}'. Not within primary root, allowed workspace roots, or external allowed dirs: #{all_allowed.join(', ')}"
        end

        if for_write
          if matched_root && matched_root != @root_dir
            if !@allow_external_writes && !@rw_roots.include?(matched_root)
              raise InvalidPathError, "Write blocked on external workspace root: '#{path}'. Configure 'workspace.allow_external_writes: true' or add with --rw to enable writes."
            end
          elsif matched_ext
            if !@allow_external_writes && !@rw_allowed_dirs.include?(matched_ext)
              raise InvalidPathError, "Write blocked on external allowed directory: '#{path}'. Configure 'workspace.allow_external_writes: true' or add with --rw to enable writes."
            end
          end
        end

        if matched_root == @root_dir
          rel = expanded[@root_dir.bytesize..]
          rel = rel[1..] if rel&.start_with?("/")
          (rel.nil? || rel.empty?) ? "." : rel
        else
          expanded
        end
      end

      def read(path)
        rel_path = sanitize_path(path, for_write: false)
        return @buffer[rel_path] if @buffer.key?(rel_path)

        full_path = File.expand_path(rel_path, @root_dir)
        return nil unless File.exist?(full_path)

        content = File.read(full_path)
        @original_hashes[rel_path] ||= Digest::SHA256.hexdigest(content)
        content
      end

      def write(path, content)
        rel_path = sanitize_path(path, for_write: true)

        unless @original_hashes.key?(rel_path)
          full_path = File.expand_path(rel_path, @root_dir)
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
          full_path = File.expand_path(rel_path, @root_dir)
          orig_content = File.exist?(full_path) ? File.read(full_path) : ""
          new_content = @buffer[rel_path] || ""
          diffs << Diff.unified_diff(rel_path, orig_content, new_content)
        end
        diffs.join("\n")
      end

      def apply!(target_paths = nil)
        applied_paths = []
        keys_to_apply = if target_paths
                          Array(target_paths).map { |p| (sanitize_path(p, for_write: true) rescue p) }
                        else
                          @dirty_files.keys.dup
                        end

        keys_to_apply.each do |rel_path|
          next unless @dirty_files.key?(rel_path)

          full_path = File.expand_path(rel_path, @root_dir)
          content = @buffer[rel_path]

          FileUtils.mkdir_p(File.dirname(full_path))

          tmp_file = "#{full_path}.tmp.#{Process.pid}.#{rand(10000)}"
          File.write(tmp_file, content)
          File.rename(tmp_file, full_path)

          @original_hashes[rel_path] = Digest::SHA256.hexdigest(content)
          @dirty_files.delete(rel_path)
          applied_paths << rel_path
        end

        @event_bus&.emit(:buffer_applied, paths: applied_paths) unless applied_paths.empty?
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
