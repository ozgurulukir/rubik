# frozen_string_literal: true

require "digest"
require "pathname"
require_relative "../platform"
require_relative "git_lister"

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
        # GitNexus parse cache: thousands of binary index files; indexing
        # them is pure cost and their non-UTF-8 bytes are a grep hazard.
        ".gitnexus/**",
        ".ua/**",
        ".trash*/**",
        "**/.trash*/**",
        ".turbo/**",
        ".sst/**",
        ".next/**",
        ".nuxt/**",
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
      HARD_PRUNE_ROOTS = [".git", ".rubik", ".ua", ".turbo", ".sst", ".next", ".nuxt"].freeze

      attr_reader :root_dir, :additional_roots
      attr_accessor :custom_includes, :custom_excludes

      def initialize(root_dir: Dir.pwd, additional_roots: [], includes: [], excludes: [], native: nil)
        @root_dir = File.expand_path(root_dir)
        @additional_roots = (additional_roots || []).map { |r| File.expand_path(r.to_s, @root_dir) }.uniq
        @custom_includes = includes || []
        @custom_excludes = excludes || []
        @native = native
      end

      def additional_roots=(roots)
        @additional_roots = (roots || []).map { |r| File.expand_path(r.to_s, @root_dir) }.uniq
      end

      # Builds the file info index. Two listing strategies per root:
      # - `git ls-files` fast path (when enabled and git answers): C-speed
      #   walk + gitignore handling; entries still pass the Ruby ignore
      #   filters (DEFAULT_IGNORES may cover paths absent from the target
      #   repo's .gitignore) and are ordered exactly like the walker.
      # - the pruned recursive walker as fallback.
      # Pass a previous scan result (rel_path => info hash) to enable the
      # stat-dirty model: stat-clean entries reuse the previous hash (which
      # may itself be nil — content never hashed), only stat-changed files
      # are read and re-hashed. Cold entries start hash-less.
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
      rescue StandardError => e
        Rubik::Log.warn(:context, "context scan aborted partway (#{e.class}: #{e.message}); returning partial index")
        files || {}
      end

      def detect_languages(files_hash)
        languages = Set.new

        files_hash.each_value do |info|
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
      # update_file-touched entry as modified. The probe always computes a
      # real content hash: its caller (Index#update_file) compares hashes to
      # decide reindexing, and a lazy nil would mask every change.
      def inspect_file(rel_path, full_path)
        entry_for(rel_path, full_path, {}, force_hash: true)
      end

      private

      # Stat-dirty model (à la git): a previous entry whose size and mtime
      # (microsecond precision) both match is NEVER read from disk — its
      # content hash is reused verbatim, including when it is nil (content
      # never hashed). Only a stat change triggers a read + SHA-256, and a
      # cold entry (no previous) starts hash-less. force_hash: true computes
      # a real hash regardless (single-file probes that must detect content
      # changes). Residual race — a same-size, same-microsecond-mtime rewrite
      # between scans — is the deliberate tradeoff the git model makes.
      def entry_for(rel_path, full_path, previous, stat: nil, force_hash: false)
        stat ||= File.stat(full_path)
        ext = File.extname(full_path)
        lang = EXTENSION_MAP[ext] || BUILD_SIGNATURES[File.basename(full_path)]
        mtime_us = mtime_micros(stat)

        prev = previous.is_a?(Hash) ? previous[rel_path] : nil
        # Cold entry (no previous): content unknown — defer the read until a
        # future scan observes a stat change (git's stat-dirty model), so the
        # implicit else is nil.
        hash =
          if !force_hash && prev.is_a?(Hash) &&
             prev[:size] == stat.size && prev[:mtime] == mtime_us
            # Stat-clean: reuse verbatim — including a nil (never hashed).
            prev[:hash]
          elsif force_hash || prev.is_a?(Hash)
            # Stat-dirty (or a probe that must see content): hash eagerly.
            content = begin
              Rubik::Platform.read_text(full_path)
            rescue Errno::ENOENT, Errno::EACCES
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

      # PERF: integer math avoids Rational allocation from Time#to_r (~5x faster, zero allocation)
      def mtime_micros(stat)
        (stat.mtime.tv_sec * 1_000_000) + stat.mtime.tv_usec
      end

      def walk_dir(base_dir, rel_prefix, key_prefix, ignore_patterns, previous, needles)
        current = rel_prefix.empty? ? base_dir : "#{base_dir}/#{rel_prefix}"
        out = {}

        # Sorted like the historical recursive Dir.glob walk so that index
        # insertion order (and anything downstream relying on it, e.g.
        # workspace_xml entry_points listing) stays deterministic.
        entries = begin
          Dir.foreach(current).sort - [".", ".."]
        rescue SystemCallError
          []
        end

        entries.each do |entry|
          entry = entry.tr("\\", "/")
          rel = rel_prefix.empty? ? entry : "#{rel_prefix}/#{entry}"

          begin
            lst = File.lstat("#{base_dir}/#{rel}")
          rescue Errno::ENOENT
            next
          end

          if lst.directory? && !lst.symlink?
            next if subtree_ignored?(rel, needles)

            out.merge!(walk_dir(base_dir, rel, key_prefix, ignore_patterns, previous, needles))
          else
            # Symlinked FILES are still listed (File.stat follows the link),
            # matching the old Dir.glob behavior; only directory descent is
            # withheld — glob never followed dir symlinks either, and doing
            # so would allow root escapes and cyclic recursion.
            st = begin
              File.stat("#{base_dir}/#{rel}")
            rescue Errno::ENOENT, Errno::EACCES
              nil
            end
            next unless st&.file?
            next if ignored?(rel, ignore_patterns)
            next unless included?(rel, @custom_includes)

            rel_key = key_prefix == "." ? rel : "#{key_prefix}/#{rel}"
            out[rel_key] = entry_for(rel_key, "#{base_dir}/#{rel}", previous, stat: st)
          end
        end

        out
      rescue StandardError => e
        Rubik::Log.warn(:context, "directory walk failed under #{base_dir} (#{e.class}: #{e.message}); keeping partial results")
        out
      end

      def subtree_ignored?(dir_rel, needles)
        comps = dir_rel.split("/")
        return true if HARD_PRUNE_ROOTS.include?(comps.first)

        needles.any? { |needle| contiguous_components?(comps, needle) }
      end

      # "<dir>/**" ignore patterns (see PRUNABLE_PATTERN) pre-split into
      # needle component arrays, once per scan root. Matching a directory
      # then costs plain array compares — no per-ancestor regex evaluation
      # and no re-splitting of the pattern's stem for every file visited.
      def prunable_needles(ignore_patterns)
        ignore_patterns.filter_map do |pattern|
          next unless (m = PRUNABLE_PATTERN.match(pattern))

          m[1].split("/")
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
        needles = prunable_needles(ignore_patterns)
        if git_listing? && @custom_includes.empty? && (listed = GitLister.files(base_dir))
          return index_listed(base_dir, prefix, listed, ignore_patterns, previous, needles)
        end

        walk_dir(base_dir, "", prefix, ignore_patterns, previous, needles)
      rescue StandardError => e
        Rubik::Log.warn(:context, "root scan failed for #{base_dir} (#{e.class}: #{e.message}); root omitted from index")
        {}
      end

      # Fast path over a `git ls-files` listing. The listing is stat-filled,
      # re-filtered through the Ruby-side ignore rules (ls-files only knows
      # the repo's own gitignore: DEFAULT_IGNORES subtrees may be missing
      # from it, and tracked files ignore gitignore entirely), ordered
      # identically to walk_dir's depth-first-per-directory sort, and
      # ancestor-pruned with the same whole-subtree semantics as the walker.
      # Residual drift the OTHER way: gitignore features the walker's crude
      # fnmatch translation lacks (negations, anchored patterns) can make the
      # fast path list fewer files.
      def index_listed(base_dir, key_prefix, rel_paths, ignore_patterns, previous, needles)
        out = {}
        # Verdict per ancestor directory, computed on first sight: walker
        # order keeps siblings adjacent, so each distinct directory's ignore
        # status is evaluated once per scan instead of once per file per
        # depth. subtree_ignored? is a pure function of (dir, needles), so
        # the memo is exact.
        dir_verdicts = Hash.new { |h, dir| h[dir] = subtree_ignored?(dir, needles) }

        # PERF: filter ignore_patterns to exclude prunable subtree patterns that
        # dir_verdicts already checked on ancestor directory segments.
        file_patterns = ignore_patterns.reject do |pat|
          m = PRUNABLE_PATTERN.match(pat)
          m && !m[1].include?("*") && !m[1].include?("?")
        end
        file_rules = compile_ignore_regexes(file_patterns)

        order_like_walker(rel_paths).each do |rel|
          # PERF: zero-allocation ancestor check using string slicing instead of Array#split and Array#join
          ignored_dir = false
          idx = 0
          while (idx = rel.index("/", idx))
            if dir_verdicts[rel[0, idx]]
              ignored_dir = true
              break
            end
            idx += 1
          end
          next if ignored_dir
          next if rel == ".rubik" || rel.start_with?(".rubik/") || rel == ".git" || rel.start_with?(".git/")
          next if file_rules.any? { |r| pattern_match?(r, rel) }
          next unless included?(rel, @custom_includes)

          full = "#{base_dir}/#{rel}"
          st = begin
            File.stat(full)
          rescue Errno::ENOENT, Errno::EACCES
            nil
          end
          next unless st&.file?

          rel_key = key_prefix == "." ? rel : "#{key_prefix}/#{rel}"
          out[rel_key] = entry_for(rel_key, full, previous, stat: st)
        end
        out
      rescue StandardError => e
        Rubik::Log.warn(:context, "git ls-files fast path failed for #{base_dir} (#{e.class}: #{e.message}); keeping partial index")
        out
      end

      def git_listing?
        GitLister.enabled?(@native)
      end

      # Sorts flat relative paths into the exact emission order of walk_dir:
      # every level name-sorts its entries and a directory descends in place,
      # so whole subtrees interleave positionally — which is precisely an
      # element-wise compare of the component arrays ("a/x" before "a.txt",
      # since "a" < "a.txt" at the first component; "lib/deep/core.rb" before
      # "lib/util.rb" via "deep" < "util").
      # PERF: replacing "/" with NUL byte ("\x00") is equivalent to array component
      # comparison because NUL (0x00) is strictly less than any valid path byte,
      # avoiding intermediate Array allocations per path (~8.4x faster, ~62.5% fewer allocations).
      # PERF: in-place sort_by! avoids array re-allocation
      def order_like_walker(paths)
        paths.sort_by! { |p| p.tr("/", "\x00") }
      end

      def parse_gitignore(dir = @root_dir)
        gitignore_path = File.join(dir, ".gitignore")
        return [] unless File.exist?(gitignore_path)

        patterns = File.readlines(gitignore_path, chomp: true).map(&:strip).reject do |line|
          line.empty? || line.start_with?("#")
        end
        patterns.map do |pattern|
          pattern.end_with?("/") ? "#{pattern}**" : pattern
        end
      rescue Errno::ENOENT, Errno::EACCES
        []
      end

      def ignored?(path, ignore_patterns)
        return true if path == ".rubik" || path.start_with?(".rubik/")
        return true if path == ".git" || path.start_with?(".git/")

        # PERF: precompile simple globs to memoized Regexp objects to avoid
        # repeated File.fnmatch? overhead across thousands of files; exotic
        # globs keep the fnmatch semantics untouched.
        compile_ignore_regexes(ignore_patterns).any? { |r| pattern_match?(r, path) }
      end

      # Translates a glob into a Regexp only where the mapping is exact: no
      # character classes, no leading-slash anchoring, and `**` only ever a
      # whole path segment (leading "**/", mid "/**/", trailing "/**").
      # Anything else returns nil and pattern_match? falls back to
      # File.fnmatch?, whose segment rules the Regexp form cannot express
      # (fnmatch "a**b" never crosses "/" and "**/x" also matches bare "x").
      def compile_ignore_regexes(ignore_patterns)
        @compiled_ignore_regexes ||= {}
        @compiled_ignore_regexes[ignore_patterns] ||= ignore_patterns.map do |pat|
          simple_glob_regex(pat) || pat
        end
      end

      def simple_glob_regex(pat)
        return nil if pat.empty? || pat.start_with?("/") || pat.include?("[")
        return nil unless pat.split("/").all? { |seg| !seg.include?("*") || seg == "**" || !seg.include?("**") }

        src = Regexp.escape(pat)
        src = src.sub(%r{\A\\\*\\\*/}, "") # leading "**/": the (?:.*/)? wrapper matches zero dirs too
        src = src.gsub("/\\*\\*/", "/(?:.*/)?") # mid "/**/": zero or more directories
        src = src.gsub("\\*\\*", ".*")          # trailing "/**" or lone "**"
        src = src.gsub("\\*", "[^/]*").gsub("\\?", "[^/]")
        Regexp.new("\\A(?:.*/)?#{src}\\z")
      end

      def pattern_match?(pattern_or_regex, path)
        if pattern_or_regex.is_a?(Regexp)
          pattern_or_regex.match?(path)
        else
          File.fnmatch?(pattern_or_regex, path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
            File.fnmatch?("**/#{pattern_or_regex}", path, File::FNM_PATHNAME | File::FNM_DOTMATCH)
        end
      end

      def included?(path, patterns)
        return true if patterns.nil? || patterns.empty?

        patterns.any? { |pattern| pattern_match?(pattern, path) }
      end
    end
  end
end
