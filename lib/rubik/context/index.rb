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
        start_time = Time.now
        @files = @scanner.scan
        @languages = @scanner.detect_languages(@files)
        @last_scan_time = Time.now - start_time
        @files
      end

      def incremental_scan
        start_time = Time.now
        new_scan = @scanner.scan(@files)
        old_files = @files

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

        @files = new_scan
        @languages = @scanner.detect_languages(@files)
        @last_scan_time = Time.now - start_time

        {
          added: added,
          modified: modified,
          deleted: deleted,
          unchanged: unchanged
        }
      end

      def update_file(rel_path)
        full_path = File.expand_path(rel_path, @root_dir)
        unless File.file?(full_path)
          @files.delete(rel_path)
          return false
        end

        info = @scanner.inspect_file(rel_path, full_path)
        old_info = @files[rel_path]

        if old_info.nil? || old_info[:hash] != info[:hash]
          @files[rel_path] = info
          @languages = @scanner.detect_languages(@files)
          true
        else
          false
        end
      end

      def status_summary
        {
          file_count: @files.size,
          languages: @languages,
          last_scan_time_sec: @last_scan_time&.round(4)
        }
      end
    end
  end
end
