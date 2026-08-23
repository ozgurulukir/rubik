# frozen_string_literal: true

require_relative "scanner"

module Rubik
  module Context
    class Index
      attr_reader :root_dir, :files, :languages, :last_scan_time

      def initialize(root_dir: Dir.pwd, scanner: nil)
        @root_dir = File.expand_path(root_dir)
        @scanner = scanner || Scanner.new(root_dir: @root_dir)
        @files = {}
        @languages = []
        @last_scan_time = nil
      end

      def full_scan
        start_time = Time.now
        @files = @scanner.scan
        @languages = @scanner.detect_languages(@files)
        @last_scan_time = Time.now - start_time
        @files
      end

      def update_file(rel_path)
        full_path = File.join(@root_dir, rel_path)
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
          last_scan_time_sec: @last_scan_time ? @last_scan_time.round(4) : nil
        }
      end
    end
  end
end
