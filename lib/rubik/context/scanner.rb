# frozen_string_literal: true

require "digest"
require "set"

module Rubik
  module Context
    class Scanner
      EXTENSION_MAP = {
        ".rb" => "ruby",
        ".py" => "python",
        ".go" => "go",
        ".rs" => "rust",
        ".c" => "c",
        ".h" => "c",
        ".zig" => "zig",
        ".js" => "javascript",
        ".ts" => "typescript"
      }.freeze

      BUILD_SIGNATURES = {
        "Gemfile" => "ruby",
        "pyproject.toml" => "python",
        "go.mod" => "go",
        "Cargo.toml" => "rust",
        "Makefile" => "c",
        "build.zig" => "zig"
      }.freeze

      DEFAULT_IGNORES = [
        "node_modules/**",
        ".git/**",
        "vendor/**",
        "tmp/**",
        "dist/**",
        "build/**"
      ].freeze

      attr_reader :root_dir, :custom_includes, :custom_excludes

      def initialize(root_dir: Dir.pwd, includes: [], excludes: [])
        @root_dir = File.expand_path(root_dir)
        @custom_includes = includes || []
        @custom_excludes = excludes || []
      end

      def scan
        ignore_patterns = DEFAULT_IGNORES + parse_gitignore + @custom_excludes
        files = {}

        Dir.glob("**/*", File::FNM_DOTMATCH, base: @root_dir).each do |rel_path|
          next if rel_path == "." || rel_path == ".."
          full_path = File.join(@root_dir, rel_path)
          next unless File.file?(full_path)

          next if ignored?(rel_path, ignore_patterns)

          file_info = inspect_file(rel_path, full_path)
          files[rel_path] = file_info if file_info
        end

        files
      end

      def detect_languages(files_hash)
        languages = Set.new

        files_hash.each do |_rel_path, info|
          languages << info[:language] if info[:language]
        end

        BUILD_SIGNATURES.each do |build_file, lang|
          languages << lang if File.exist?(File.join(@root_dir, build_file))
        end

        languages.to_a.sort
      end

      def inspect_file(rel_path, full_path)
        stat = File.stat(full_path)
        ext = File.extname(rel_path)
        lang = EXTENSION_MAP[ext] || BUILD_SIGNATURES[File.basename(rel_path)]

        content = begin
          File.read(full_path)
        rescue StandardError
          ""
        end
        hash = Digest::SHA256.hexdigest(content)

        {
          size: stat.size,
          mtime: stat.mtime.to_i,
          hash: hash,
          language: lang
        }
      end

      private

      def parse_gitignore
        gitignore_path = File.join(@root_dir, ".gitignore")
        return [] unless File.exist?(gitignore_path)

        File.readlines(gitignore_path, chomp: true).map(&:strip).reject do |line|
          line.empty? || line.start_with?("#")
        end.map do |pattern|
          pattern.end_with?("/") ? "#{pattern}**" : pattern
        end
      end

      def ignored?(path, ignore_patterns)
        ignore_patterns.any? do |pattern|
          File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
            File.fnmatch?("**/#{pattern}", path, File::FNM_PATHNAME | File::FNM_DOTMATCH)
        end
      end
    end
  end
end
