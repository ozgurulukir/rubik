# frozen_string_literal: true

require "json"
require "fileutils"
require "digest"
require_relative "symbol"
require_relative "../platform"

module Rubik
  module AST
    class CacheStore
      LANGUAGE_MAP = {
        ".rb" => "ruby",
        ".py" => "python",
        ".go" => "go",
        ".rs" => "rust",
        ".zig" => "zig",
        ".c" => "c",
        ".h" => "c",
        ".cpp" => "cpp",
        ".hpp" => "cpp",
        ".cc" => "cpp",
        ".ts" => "typescript",
        ".tsx" => "typescript",
        ".js" => "javascript",
        ".jsx" => "javascript"
      }.freeze

      attr_reader :root_dir, :home_dir

      def initialize(root_dir: Dir.pwd, home_dir: nil)
        @root_dir = File.expand_path(root_dir)
        @home_dir = home_dir ? File.expand_path(home_dir) : Rubik::Platform.home_dir
      end

      def cache_path
        rubik_dir = File.join(@root_dir, ".rubik")
        primary = File.join(rubik_dir, "cache", "ast_index.json")
        if File.directory?(rubik_dir) && (File.writable?(rubik_dir) || (File.exist?(primary) && File.writable?(primary)))
          return primary
        end

        project_hash = Digest::SHA256.hexdigest(@root_dir)[0..11]
        File.join(@home_dir, ".rubik", "cache", project_hash, "ast_index.json")
      end

      def save(file_symbols_hash)
        return false unless file_symbols_hash && file_symbols_hash.is_a?(Hash)

        data = {
          "version" => 1,
          "last_scan" => Time.now.to_i,
          "files" => {}
        }

        file_symbols_hash.each do |file_path, syms|
          next if syms.nil? || syms.empty?

          full_path = File.expand_path(file_path, @root_dir)
          next unless File.exist?(full_path) && File.file?(full_path)

          stat = File.stat(full_path) rescue nil
          next unless stat

          rel_path = if full_path.start_with?("#{@root_dir}/")
                       full_path.sub("#{@root_dir}/", "")
                     else
                       file_path
                     end

          ext = File.extname(full_path).downcase
          lang = LANGUAGE_MAP[ext] || "unknown"

          data["files"][rel_path] = {
            "language" => lang,
            "mtime" => stat.mtime.to_i,
            "size" => stat.size,
            "symbols" => syms.map(&:to_h)
          }
        end

        target_path = cache_path
        Rubik::Platform.atomic_write(target_path, JSON.pretty_generate(data))
        true
      rescue StandardError
        false
      end

      def load
        target_path = cache_path
        return {} unless File.exist?(target_path)

        content = File.read(target_path)
        data = JSON.parse(content)
        return {} unless data.is_a?(Hash) && data["files"].is_a?(Hash)

        result = {}
        data["files"].each do |rel_path, cached_info|
          full_path = File.expand_path(rel_path, @root_dir)
          next unless valid_entry?(full_path, cached_info)

          symbols_raw = cached_info["symbols"] || []
          symbols = symbols_raw.map do |s|
            line_start = s["line_start"] || (s["line_range"] && s["line_range"][0]) || 1
            line_end = s["line_end"] || (s["line_range"] && s["line_range"][1]) || line_start
            Symbol.new(
              name: s["name"],
              kind: (s["kind"] || :function).to_sym,
              file: full_path,
              line_start: line_start,
              line_end: line_end,
              signature: s["signature"],
              calls: s["calls"] || [],
              body: s["body"],
              docstring: s["docstring"]
            )
          end
          result[full_path] = symbols
        end

        result
      rescue StandardError
        {}
      end

      def valid_entry?(file_path, cached_info)
        return false unless cached_info.is_a?(Hash)

        full_path = File.expand_path(file_path, @root_dir)
        return false unless File.exist?(full_path) && File.file?(full_path)

        stat = File.stat(full_path)
        cached_mtime = (cached_info["mtime"] || cached_info[:mtime]).to_i
        cached_size = (cached_info["size"] || cached_info[:size]).to_i

        stat.mtime.to_i == cached_mtime && stat.size == cached_size
      rescue StandardError
        false
      end

      def clear!
        target_path = cache_path
        File.delete(target_path) if File.exist?(target_path)
        true
      rescue StandardError
        false
      end
    end
  end
end
