# frozen_string_literal: true

require "fileutils"
require "digest"
require "pathname"
require "monitor"
require_relative "diff"
require_relative "path_validator"
require_relative "../platform"
require_relative "../security/guard"

module Rubik
  module Buffer
    class InvalidPathError < StandardError; end

    class Manager
      attr_reader :root_dir, :dirty_files, :additional_roots, :rw_roots, :allowed_external_dirs, :rw_allowed_dirs, :guard, :last_conflicts
      attr_accessor :allow_external_writes, :config

      def initialize(root_dir: Dir.pwd, additional_roots: [], allowed_external_dirs: [], allow_external_writes: false,
                     event_bus: nil, guard: nil, config: nil)
        @monitor = Monitor.new
        @root_dir = File.expand_path(root_dir)
        @additional_roots = (additional_roots || []).map { |r| File.expand_path(r.to_s, @root_dir) }.uniq
        @allowed_external_dirs = (allowed_external_dirs || []).map { |d| File.expand_path(d.to_s, @root_dir) }.uniq
        @allow_external_writes = allow_external_writes || false
        @rw_roots = Set.new
        @rw_allowed_dirs = Set.new(@allowed_external_dirs)
        @event_bus = event_bus
        @guard = guard || Rubik::Security::Guard.new
        @config = config
        @buffer = {}
        @dirty_files = {}
        @original_hashes = {}
        @last_conflicts = []
      end

      def add_root(path, rw: false) # rubocop:disable Naming/MethodParameterName -- rw: bilinçli kisa kwarg
        @monitor.synchronize do
          expanded = File.expand_path(path.to_s, @root_dir)
          @additional_roots << expanded unless @additional_roots.include?(expanded)
          if rw
            @rw_roots << expanded
          else
            @rw_roots.delete(expanded)
          end
          expanded
        end
      end

      def remove_root(path)
        @monitor.synchronize do
          expanded = File.expand_path(path.to_s, @root_dir)
          @additional_roots.delete(expanded)
          @rw_roots.delete(expanded)
          expanded
        end
      end

      def add_allowed_dir(path, rw: true) # rubocop:disable Naming/MethodParameterName -- rw: bilinçli kisa kwarg
        @monitor.synchronize do
          expanded = File.expand_path(path.to_s, @root_dir)
          @allowed_external_dirs << expanded unless @allowed_external_dirs.include?(expanded)
          if rw
            @rw_allowed_dirs << expanded
          else
            @rw_allowed_dirs.delete(expanded)
          end
          expanded
        end
      end

      def remove_allowed_dir(path)
        @monitor.synchronize do
          expanded = File.expand_path(path.to_s, @root_dir)
          @allowed_external_dirs.delete(expanded)
          @rw_allowed_dirs.delete(expanded)
          expanded
        end
      end

      def sanitize_path(path, for_write: false)
        expanded = File.expand_path(path.to_s, @root_dir)

        # Boundary containment (symlink escape): lexical prefix matching is
        # the floor; containment_root additionally resolves symlinks on BOTH
        # sides, so a link planted inside the root cannot redirect
        # reads/writes outside it. Stored buffer keys stay lexical.
        matched_kind, matched_dir = containment_root(expanded)

        unless matched_dir
          all_allowed = ([@root_dir] + @additional_roots + @allowed_external_dirs).uniq
          raise InvalidPathError,
                "Path traversal attempt blocked: '#{path}'. Not within primary root, allowed workspace roots, " \
                "or external allowed dirs: #{all_allowed.join(', ')}"
        end

        matched_root = matched_kind == :root ? matched_dir : nil
        matched_ext = matched_kind == :external ? matched_dir : nil

        rel_or_exp = if matched_root && Rubik::Platform.path_equal?(matched_root, @root_dir)
                       begin
                         rel = Pathname.new(expanded).relative_path_from(Pathname.new(@root_dir)).to_s.gsub("\\", "/")
                         rel == "." ? "." : rel
                       rescue ArgumentError
                         expanded
                       end
                     else
                       expanded
                     end

        if for_write
          # Critical path security check (@guard is always assigned in
          # initialize — the historical re-fallback here was unreachable).
          # Pass the ROOT-ANCHORED expanded path: the guard's lexical
          # candidates and its symlink resolution both anchor to the process
          # cwd, which diverges from the workspace root when the REPL is
          # launched from elsewhere — resolving relative keys there would
          # inspect the wrong tree.
          begin
            @guard.verify_path_write!(expanded)
          rescue Rubik::Security::BlockedWriteError => e
            raise InvalidPathError, e.message
          end

          if matched_root && !Rubik::Platform.path_equal?(matched_root, @root_dir)
            if !@allow_external_writes && @rw_roots.none? { |r| Rubik::Platform.path_equal?(r, matched_root) }
              raise InvalidPathError,
                    "Write blocked on external workspace root: '#{path}'. Configure 'workspace.allow_external_writes: true' or add with --rw to enable writes."
            end
          elsif matched_ext
            if !@allow_external_writes && @rw_allowed_dirs.none? { |d| Rubik::Platform.path_equal?(d, matched_ext) }
              raise InvalidPathError,
                    "Write blocked on external allowed directory: '#{path}'. " \
                    "Configure 'workspace.allow_external_writes: true' or add with --rw to enable writes."
            end
          end
        end

        rel_or_exp
      end

      # Reads a file from the buffer (if dirty) or from disk, normalizing newlines.
      #
      # @param path [String] file path relative to the root directory
      # @param reload [Boolean] force reload from disk, discarding in-memory buffer if present
      # @param from_disk [Boolean] read directly from disk without modifying buffer or original hashes
      # @return [String, nil] the file content, or nil if the file does not exist
      def read(path, reload: false, from_disk: false)
        @monitor.synchronize do
          rel_path = sanitize_path(path, for_write: false)
          if reload
            @buffer.delete(rel_path)
            @dirty_files.delete(rel_path)
            @original_hashes.delete(rel_path)
            @last_conflicts.delete(rel_path)
          end

          if from_disk
            full_path = File.expand_path(rel_path, @root_dir)
            return nil unless File.exist?(full_path)

            return Rubik::Platform.normalize_newlines(Rubik::Platform.read_text(full_path))
          elsif @buffer.key?(rel_path)
            return @buffer[rel_path]
          end

          full_path = File.expand_path(rel_path, @root_dir)
          return nil unless File.exist?(full_path)

          content = Rubik::Platform.normalize_newlines(Rubik::Platform.read_text(full_path))
          @original_hashes[rel_path] = Digest::SHA256.hexdigest(content)
          content
        end
      end

      def discard(path)
        @monitor.synchronize do
          rel_path = sanitize_path(path, for_write: false)
          @buffer.delete(rel_path)
          @dirty_files.delete(rel_path)
          @original_hashes.delete(rel_path)
          @last_conflicts.delete(rel_path)
          @event_bus&.emit(:buffer_discarded, path: rel_path)
          rel_path
        end
      end

      def write(path, content, reset_baseline: false)
        @monitor.synchronize do
          rel_path = sanitize_path(path, for_write: true)
          normalized_content = Rubik::Platform.normalize_newlines(content)

          if reset_baseline || !@original_hashes.key?(rel_path)
            full_path = File.expand_path(rel_path, @root_dir)
            @original_hashes[rel_path] = (Digest::SHA256.hexdigest(Rubik::Platform.normalize_newlines(Rubik::Platform.read_text(full_path))) if File.exist?(full_path))
          end

          @buffer[rel_path] = normalized_content
          @dirty_files[rel_path] = true
          @event_bus&.emit(:buffer_changed, path: rel_path)
          normalized_content
        end
      end

      # Returns whether the buffer has any unapplied file modifications,
      # or whether a specific file path is dirty or unwritten to disk.
      #
      # @param path [String, nil] optional path to check
      # @return [Boolean] true if there are dirty files (or specified path is dirty)
      def dirty?(path = nil)
        @monitor.synchronize do
          if path
            rel_path = begin
              sanitize_path(path, for_write: false)
            rescue InvalidPathError
              path.to_s
            end

            return true if @dirty_files.key?(rel_path) || @dirty_files.key?(path.to_s)

            target = if @buffer.key?(rel_path)
                       rel_path
                     elsif @buffer.key?(path.to_s)
                       path.to_s
                     end

            if target
              full_path = File.expand_path(target, @root_dir)
              return true unless File.exist?(full_path)
            end

            false
          else
            !@dirty_files.empty?
          end
        end
      end

      # Returns list of all known files in the buffer and on disk within root_dir.
      # The disk walk happens OUTSIDE the monitor (review 2026-09-17, Finding 4):
      # a full-tree Dir.glob under the lock used to block every concurrent
      # buffer operation on large repos. We snapshot the in-buffer keys under
      # the lock, glob without it, then merge — results may be a few ms stale
      # for callers that only need a fuzzy-match candidate list.
      def all_files
        buffer_keys = @monitor.synchronize { @buffer.keys }
        disk_files = begin
          Dir.glob("**/*", File::FNM_DOTMATCH, base: @root_dir).reject do |f|
            f.start_with?(".git") || File.directory?(File.expand_path(f, @root_dir))
          end
        rescue SystemCallError
          []
        end
        (buffer_keys + disk_files).uniq
      end

      def diff_all
        snapshot = @monitor.synchronize do
          @dirty_files.keys.map { |rel_path| [rel_path, @buffer[rel_path] || ""] }
        end

        diffs = snapshot.map do |rel_path, new_content|
          full_path = File.expand_path(rel_path, @root_dir)
          orig_content = File.exist?(full_path) ? Rubik::Platform.normalize_newlines(File.read(full_path)) : ""
          Diff.unified_diff(rel_path, orig_content, new_content)
        end

        diffs.join("\n")
      end

      def apply!(target_paths = nil, policy: nil)
        @monitor.synchronize do
          applied_paths = []
          conflicts = []
          keys_to_apply = if target_paths
                            Array(target_paths).map { |p| sanitize_path(p, for_write: true) }
                          else
                            @dirty_files.keys.dup
                          end

          effective_policy = (policy || external_modification_policy).to_s.downcase

          keys_to_apply.each do |rel_path|
            next unless @dirty_files.key?(rel_path)

            unless PathValidator.valid?(rel_path)
              @dirty_files.delete(rel_path)
              @buffer.delete(rel_path)
              @original_hashes.delete(rel_path)
              @event_bus&.emit(:buffer_garbage_skipped, path: rel_path)
              next
            end

            baseline = @original_hashes[rel_path]
            current_disk = disk_hash(rel_path)

            conflict = if baseline
                         current_disk != baseline
                       else
                         !current_disk.nil?
                       end

            if conflict && effective_policy != "overwrite"
              conflicts << rel_path
              @event_bus&.emit(:buffer_apply_conflict, paths: conflicts, path: rel_path)
              next
            end

            full_path = File.expand_path(rel_path, @root_dir)

            # TOCTOU close: re-verify containment immediately before the
            # atomic write — a symlink planted between write-time sanitize
            # and apply! must not redirect the write outside the workspace.
            # Fail loud: an untrustworthy path is an attack signal or a
            # mid-flight root misconfiguration, not a content problem; the
            # entry stays dirty for a retry after remediation.
            containment_kind, = containment_root(full_path)
            unless containment_kind
              @event_bus&.emit(:buffer_containment_blocked, path: rel_path)
              # Commit what this run has seen so "apply! rewrites
              # last_conflicts on every run" holds for readers (AutoApply's
              # report_conflicts) even on the failure path.
              @last_conflicts = conflicts
              raise InvalidPathError,
                    "Write blocked: '#{rel_path}' resolves outside all allowed roots at apply time " \
                    "(possible symlink swap since buffering). Re-verify the workspace and retry."
            end

            content = @buffer[rel_path]

            Rubik::Platform.atomic_write(full_path, content)

            @original_hashes[rel_path] = Digest::SHA256.hexdigest(content)
            @dirty_files.delete(rel_path)
            @buffer.delete(rel_path)
            applied_paths << rel_path
          end

          @last_conflicts = conflicts
          @event_bus&.emit(:buffer_applied, paths: applied_paths) unless applied_paths.empty?
          applied_paths
        end
      end

      def reset!
        @monitor.synchronize do
          @buffer.clear
          @dirty_files.clear
          @original_hashes.clear
          @last_conflicts.clear
        end
      end

      def snapshot_state
        @monitor.synchronize do
          state = {}
          @dirty_files.each_key do |rel_path|
            state[rel_path] = @buffer[rel_path]
          end
          state
        end
      end

      def restore_snapshot_state(state)
        @monitor.synchronize do
          @buffer.clear
          @dirty_files.clear
          state.each do |rel_path, content|
            @buffer[rel_path] = content
            @dirty_files[rel_path] = true
          end
        end
      end

      private

      # Single source of boundary containment for both the sanitize_path
      # entry check and the apply! re-verification. Returns [kind, dir] with
      # kind :root / :external (dir is the LEXICAL matched root/external
      # dir — downstream keying stays lexical), or nil when the path,
      # symlink-resolved on both sides, escapes every allowed root.
      def containment_root(path)
        allowed_roots = [@root_dir] + @additional_roots.map { |r| File.expand_path(r.to_s, @root_dir) }
        root = allowed_roots.find { |r| Rubik::Platform.resolved_path_under?(path, r) }
        return [:root, root] if root

        ext = @allowed_external_dirs.map { |d| File.expand_path(d.to_s, @root_dir) }
                                    .find { |d| Rubik::Platform.resolved_path_under?(path, d) }
        ext && [:external, ext]
      end

      def external_modification_policy
        raw = if @config.is_a?(Rubik::Config)
                @config.fetch("buffer.on_external_modification", "skip")
              elsif @config.respond_to?(:dig)
                @config.dig("buffer", "on_external_modification") ||
                  (@config["buffer.on_external_modification"] if @config.respond_to?(:[])) ||
                  "skip"
              else
                "skip"
              end
        raw.to_s.downcase
      end

      def disk_hash(rel_path)
        full_path = File.expand_path(rel_path, @root_dir)
        return nil unless File.exist?(full_path)

        Digest::SHA256.hexdigest(Rubik::Platform.normalize_newlines(Rubik::Platform.read_text(full_path)))
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end
    end
  end
end
