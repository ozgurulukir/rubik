# frozen_string_literal: true

require "digest"
require "set"
require "pathname"

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
        ".cpp" => "cpp",
        ".hpp" => "cpp",
        ".cc" => "cpp",
        ".zig" => "zig",
        ".js" => "javascript",
        ".jsx" => "javascript",
        ".ts" => "typescript",
        ".tsx" => "typescript",
        ".html" => "html",
        ".htm" => "html",
        ".css" => "css",
        ".json" => "json",
        ".yaml" => "yaml",
        ".yml" => "yaml",
        ".md" => "markdown",
        ".sh" => "shell",
        ".java" => "java",
        ".kt" => "kotlin",
        ".swift" => "swift"
      }.freeze

      BUILD_SIGNATURES = {
        "Gemfile" => "ruby",
        "pyproject.toml" => "python",
        "go.mod" => "go",
        "Cargo.toml" => "rust",
        "Makefile" => "c",
        "build.zig" => "zig",
        "package.json" => "javascript"
      }.freeze

      DEFAULT_IGNORES = [
        ".rubik/**",
        ".git/**",
        "node_modules/**",
        "vendor/**",
        "tmp/**",
        "dist/**",
        "build/**",
        ".cache/**",
        "coverage/**"
      ].freeze

      attr_reader :root_dir, :custom_includes, :custom_excludes
      attr_reader :additional_roots

      def initialize(root_dir: Dir.pwd, additional_roots: [], includes: [], excludes: [])
        @root_dir = File.expand_path(root_dir)
        @additional_roots = (additional_roots || []).map { |r| File.expand_path(r.to_s, @root_dir) }.uniq
        @custom_includes = includes || []
        @custom_excludes = excludes || []
      end

      def additional_roots=(roots)
        @additional_roots = (roots || []).map { |r| File.expand_path(r.to_s, @root_dir) }.uniq
      end

      def scan
        files = {}

        # 1. Scan primary root
        primary_ignores = DEFAULT_IGNORES + parse_gitignore(@root_dir) + @custom_excludes
        Dir.glob("**/*", File::FNM_DOTMATCH, base: @root_dir).each do |rel_path|
          next if rel_path == "." || rel_path == ".."
          full_path = File.join(@root_dir, rel_path)
          next unless File.file?(full_path)
          next if ignored?(rel_path, primary_ignores)

          file_info = inspect_file(rel_path, full_path)
          files[rel_path] = file_info if file_info
        end

        # 2. Scan additional roots
        @additional_roots.each do |extra_root|
          next unless File.directory?(extra_root)
          extra_ignores = DEFAULT_IGNORES + parse_gitignore(extra_root) + @custom_excludes

          Dir.glob("**/*", File::FNM_DOTMATCH, base: extra_root).each do |sub_rel_path|
            next if sub_rel_path == "." || sub_rel_path == ".."
            full_path = File.join(extra_root, sub_rel_path)
            next unless File.file?(full_path)
            next if ignored?(sub_rel_path, extra_ignores)

            rel_from_root = Pathname.new(full_path).relative_path_from(Pathname.new(@root_dir)).to_s
            file_info = inspect_file(rel_from_root, full_path)
            files[rel_from_root] = file_info if file_info
          end
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
          @additional_roots.each do |extra_root|
            languages << lang if File.exist?(File.join(extra_root, build_file))
          end
        end

        languages.to_a.sort
      end

      def inspect_file(rel_path, full_path)
        stat = File.stat(full_path)
        ext = File.extname(full_path)
        lang = EXTENSION_MAP[ext] || BUILD_SIGNATURES[File.basename(full_path)]

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

      def parse_gitignore(dir = @root_dir)
        gitignore_path = File.join(dir, ".gitignore")
        return [] unless File.exist?(gitignore_path)

        File.readlines(gitignore_path, chomp: true).map(&:strip).reject do |line|
          line.empty? || line.start_with?("#")
        end.map do |pattern|
          pattern.end_with?("/") ? "#{pattern}**" : pattern
        end
      end

      def ignored?(path, ignore_patterns)
        return true if path == ".rubik" || path.start_with?(".rubik/")
        return true if path == ".git" || path.start_with?(".git/")

        ignore_patterns.any? do |pattern|
          File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
            File.fnmatch?("**/#{pattern}", path, File::FNM_PATHNAME | File::FNM_DOTMATCH)
        end
      end
    end
  end
end
