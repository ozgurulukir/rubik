# frozen_string_literal: true

require "pathname"
require_relative "scanner"

module Rubik
  module Context
    class Index
      attr_reader :root_dir, :files, :languages, :last_scan_time, :scanner

      def initialize(root_dir: Dir.pwd, scanner: nil, additional_roots: [], includes: [], excludes: [], native: nil)
        @root_dir = File.expand_path(root_dir)
        # Serialises mutations to @files / @languages. The index is driven both
        # by synchronous REPL turns and by an async background AST indexer, so
        # without a shared lock concurrent incremental_scan / update_file /
        # full_scan / detect_languages calls race on the same hash (ruby/ruby#
        # 17006) and can corrupt it. Scanning itself is not changed — only the
        # shared-state mutation is made thread-safe.
        @mutex = Mutex.new
        # Serializes whole scan runs (full_scan / incremental_scan) so the
        # files hash and the completeness verdict pair atomically — two
        # concurrent scans would otherwise let one publish the other's
        # clean verdict with its own aborted files. Held only by scanners,
        # never by readers (status_summary stays lock-cheap).
        @scan_mutex = Mutex.new
        @scanner = scanner || Scanner.new(
          root_dir: @root_dir,
          additional_roots: additional_roots,
          includes: includes,
          excludes: excludes,
          native: native
        )
        @files = {}
        @languages = []
        @last_scan_time = nil
        @last_scan_aborted = false
        @last_scan_error = nil
      end

      def update_file_filters(includes: nil, excludes: nil)
        @scanner.custom_includes = Array(includes).compact unless includes.nil?
        @scanner.custom_excludes = Array(excludes).compact unless excludes.nil?
        full_scan
      end

      def additional_roots
        @scanner.additional_roots
      end

      def additional_roots=(roots)
        @scanner.additional_roots = roots
      end

      def full_scan
        @scan_mutex.synchronize do
          start_time = Time.now
          files = @scanner.scan
          languages = @scanner.detect_languages(files)
          report = scanner_report
          @mutex.synchronize do
            @files = files
            @languages = languages
            @last_scan_time = Time.now - start_time
            store_scan_outcome!(report)
          end
        end
        @files
      end

      def incremental_scan
        @scan_mutex.synchronize do
          start_time = Time.now
          snapshot = @mutex.synchronize { @files }
          new_scan = @scanner.scan(snapshot)
          old_files = snapshot

          added = []
          modified = []
          deleted = []
          unchanged = []

          new_scan.each do |rel_path, info|
            if old_files.key?(rel_path)
              old_info = old_files[rel_path]
              if old_info[:mtime] != info[:mtime] || old_info[:size] != info[:size] || old_info[:hash] != info[:hash]
                modified << rel_path
              else
                unchanged << rel_path
              end
            else
              added << rel_path
            end
          end

          old_files.each_key do |rel_path|
            deleted << rel_path unless new_scan.key?(rel_path)
          end

          languages = @scanner.detect_languages(new_scan)
          report = scanner_report
          @mutex.synchronize do
            @files = new_scan
            @languages = languages
            @last_scan_time = Time.now - start_time
            store_scan_outcome!(report)
          end

          {
            added: added,
            modified: modified,
            deleted: deleted,
            unchanged: unchanged
          }
        end
      end

      def update_file(rel_path)
        full_path = File.expand_path(rel_path, @root_dir)
        unless File.file?(full_path)
          return @mutex.synchronize do
            @files.delete(rel_path)
            false
          end
        end

        info = @scanner.inspect_file(rel_path, full_path)
        @mutex.synchronize do
          old_info = @files[rel_path]
          if old_info.nil? || old_info[:hash] != info[:hash]
            @files[rel_path] = info
            @languages = @scanner.detect_languages(@files)
            true
          else
            false
          end
        end
      end

      def status_summary
        @mutex.synchronize do
          {
            file_count: @files.size,
            languages: @languages,
            last_scan_time_sec: @last_scan_time&.round(4),
            last_scan_aborted: @last_scan_aborted,
            last_scan_error: @last_scan_error
          }
        end
      end

      private

      # Test doubles may not carry last_scan_report; a nil report means a
      # clean scan.
      def scanner_report
        @scanner.respond_to?(:last_scan_report) ? @scanner.last_scan_report : nil
      end

      # Copies the scanner's completeness verdict under the same lock that
      # publishes the files, so a reader never sees files from an aborted
      # scan without also seeing the flag.
      def store_scan_outcome!(report)
        @last_scan_aborted = report ? report.aborted : false
        @last_scan_error = report&.reasons&.any? ? report.reasons.join("; ") : nil
      end
    end
  end
end
