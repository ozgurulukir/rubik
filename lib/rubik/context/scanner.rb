# frozen_string_literal: true

require "digest"
require "set"
require "pathname"
require_relative "../platform"

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

      # Subtrees whose ignore pattern is "<path>/**" (optionally with a
      # "**/" prefix) are pruned whole when the stem's components occur
      # contiguously in a directory's path. NOTE: this is intentionally
      # STRONGER than the legacy per-file filter — Ruby's fnmatch treats a
      # trailing `**` as a single segment, so patterns like "node_modules/**"
      # historically rejected only first-level entries while deeper files
      # leaked into the index. The walker applies the pattern's plain meaning
      # (whole subtree ignored), matching real gitignore semantics.
      PRUNABLE_PATTERN = %r{\A(?:\*\*/)?(.+)/\*\*\z}
      # Also hard-rejected inside `ignored?`; pruned here before descending.
      HARD_PRUNE_ROOTS = [".git", ".rubik"].freeze

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

      # Walks the project tree and builds the file info index. Pass a previous
      # scan result (rel_path => info hash) to skip re-reading unchanged files:
      # when size and mtime match, the previous content hash is reused instead
      # of re-reading and re-hashing the file body.
      def scan(previous = {})
        files = {}

        # 1. Scan primary root
        primary_ignores = DEFAULT_IGNORES + parse_gitignore(@root_dir) + @custom_excludes
        files.merge!(scan_root(@root_dir, ".", primary_ignores, previous))

        # 2. Scan additional roots
        @additional_roots.each do |extra_root|
          next unless File.directory?(extra_root)
          extra_ignores = DEFAULT_IGNORES + parse_gitignore(extra_root) + @custom_excludes
          files.merge!(scan_root(extra_root, relative_prefix(extra_root), extra_ignores, previous))
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

      # Public single-file probe. Delegates to entry_for so the persisted
      # info (notably the microsecond mtime) stays unit-identical with scan
      # results — mixed units would make incremental_scan flag every
      # update_file-touched entry as modified.
      def inspect_file(rel_path, full_path)
        entry_for(rel_path, full_path, {})
      end

      private

      # Stat-only fast path: reuse the previous scan's content hash when size
      # and mtime (microsecond precision) both match, so unchanged files are
      # never read from disk. Otherwise falls back to a full read + SHA-256.
      def entry_for(rel_path, full_path, previous, stat: nil)
        stat ||= File.stat(full_path)
        ext = File.extname(full_path)
        lang = EXTENSION_MAP[ext] || BUILD_SIGNATURES[File.basename(full_path)]
        mtime_us = mtime_micros(stat)

        prev = previous.is_a?(Hash) ? previous[rel_path] : nil
        hash =
          if prev.is_a?(Hash) && prev[:hash] &&
             prev[:size] == stat.size && prev[:mtime] == mtime_us
            prev[:hash]
          else
            content = begin
              File.read(full_path)
            rescue StandardError
              ""
            end
            Digest::SHA256.hexdigest(content)
          end

        {
          size: stat.size,
          mtime: mtime_us,
          hash: hash,
          language: lang
        }
      end

      def mtime_micros(stat)
        (stat.mtime.to_r * 1_000_000).to_i
      end

      def walk_dir(base_dir, rel_prefix, key_prefix, ignore_patterns, previous)
        current = rel_prefix.empty? ? base_dir : "#{base_dir}/#{rel_prefix}"
        out = {}

        # Sorted like the historical recursive Dir.glob walk so that index
        # insertion order (and anything downstream relying on it, e.g.
        # workspace_xml entry_points listing) stays deterministic.
        entries = Dir.foreach(current).sort - [".", ".."]
        entries.each do |entry|
          entry = entry.tr("\\", "/")
          rel = rel_prefix.empty? ? entry : "#{rel_prefix}/#{entry}"

          begin
            lst = File.lstat("#{base_dir}/#{rel}")
          rescue StandardError
            next
          end

          if lst.directory? && !lst.symlink?
            next if subtree_ignored?(rel, ignore_patterns)

            out.merge!(walk_dir(base_dir, rel, key_prefix, ignore_patterns, previous))
          else
            # Symlinked FILES are still listed (File.stat follows the link),
            # matching the old Dir.glob behavior; only directory descent is
            # withheld — glob never followed dir symlinks either, and doing
            # so would allow root escapes and cyclic recursion.
            st = begin
              File.stat("#{base_dir}/#{rel}")
            rescue StandardError
              nil
            end
            next unless st&.file?
            next if ignored?(rel, ignore_patterns)

            rel_key = key_prefix == "." ? rel : "#{key_prefix}/#{rel}"
            out[rel_key] = entry_for(rel_key, "#{base_dir}/#{rel}", previous, stat: st)
          end
        end

        out
      end

      def subtree_ignored?(dir_rel, ignore_patterns)
        comps = dir_rel.split("/")
        return true if HARD_PRUNE_ROOTS.include?(comps.first)

        ignore_patterns.any? do |pattern|
          m = PRUNABLE_PATTERN.match(pattern)
          next false unless m

          contiguous_components?(comps, m[1].split("/"))
        end
      end

      def contiguous_components?(haystack, needle)
        return true if haystack == needle
        return false if haystack.size < needle.size

        (0..(haystack.size - needle.size)).any? do |offset|
          haystack[offset, needle.size] == needle
        end
      end

      # Key prefix for files found under an additional root, mirroring the
      # historical layout: subtree roots get their path relative to the main
      # root; unrelated roots fall back to their absolute path.
      def relative_prefix(dir)
        Pathname.new(dir).relative_path_from(Pathname.new(@root_dir)).to_s.gsub("\\", "/")
      rescue ArgumentError
        dir.gsub("\\", "/")
      end

      # One recursive directory walk with EARLY SUBTREE PRUNING: instead of
      # enumerating ignored trees (.git/, node_modules/, vendor/ – thousands
      # of entries on real projects) only to reject each file afterwards,
      # descent into a matching subtree never happens. Pruning applies the
      # ignore pattern's plain whole-subtree meaning (see PRUNABLE_PATTERN)
      # and `ignored?` still filters every file that IS visited. `prefix` is
      # the key namespace for this root ("." for the primary project root).
      def scan_root(base_dir, prefix, ignore_patterns, previous)
        walk_dir(base_dir, "", prefix, ignore_patterns, previous)
      end

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
