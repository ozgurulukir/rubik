# frozen_string_literal: true

module Rubik
  module Context
    # Frozen value object owning the entire "is this path in scope?" dialect
    # of the context index: default ignore globs, the repo's own .gitignore,
    # user excludes/includes, whole-subtree pruning, and the reserved runtime
    # roots. Built once per scan root via .build, it answers three predicates
    # — prune_dir?, ignore_file? / listed_file_ignored?, include_file? — so
    # both listing strategies (Scanner#walk_dir and the git ls-files fast
    # path) stay symmetric by consuming the same rules instead of each
    # re-implementing the filter sequence.
    class IgnoreRules
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
        "coverage/**",
        # Multi-GB local model blobs; never project sources.
        ".ollama/**",
        # Agent-harness state: transcripts, sessions, caches.
        ".zcode/**"
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
      # Also hard-rejected inside ignore_file?; pruned before descending.
      # ROOT-anchored only (comps.first) to match the rg-side `!/X/**`
      # globs — a nested `src/AppData` stays indexed.
      HARD_PRUNE_ROOTS = [".git", ".rubik", ".ua", ".turbo", ".sst", ".next", ".nuxt", "AppData"].freeze

      attr_reader :custom_includes

      # `dir` is the scan root whose top-level .gitignore contributes
      # patterns; excludes/includes come from the Scanner's accessors.
      def self.build(dir:, custom_excludes: [], custom_includes: [])
        new(DEFAULT_IGNORES + parse_gitignore(dir) + custom_excludes, custom_includes)
      end

      # Reads one root's .gitignore: comments and blanks dropped, directory
      # entries ("tmp/") widened to whole-subtree globs ("tmp/**").
      def self.parse_gitignore(dir)
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

      # `patterns` is the merged ignore table; `custom_includes` the user's
      # allow-list. Compilation happens eagerly here so the predicates are
      # allocation-free lookups afterwards.
      def initialize(patterns, custom_includes)
        @patterns = patterns.freeze
        @custom_includes = (custom_includes || []).freeze
        # "<dir>/**" patterns pre-split into needle component arrays.
        # Matching a directory then costs plain array compares — no
        # per-ancestor regex evaluation and no re-splitting of the pattern's
        # stem for every file visited.
        @prunable_needles = @patterns.filter_map do |pattern|
          next unless (m = PRUNABLE_PATTERN.match(pattern))

          stem = m[1]
          # A leading "/" anchors the ignore to the scan root; an unanchored
          # stem (including the "**/" prefix) matches at any depth.
          [stem.delete_prefix("/").split("/"), stem.start_with?("/")]
        end.freeze
        @file_regexes = compile(@patterns).freeze
        # The git fast path skips prunable subtree patterns with literal
        # stems: its ancestor loop already pruned every directory segment
        # through prune_dir?, so re-testing those globs per file is pure
        # redundancy. Exotic stems (wildcards) stay in the per-file set.
        @listed_file_regexes = compile(listed_file_patterns).freeze
        freeze
      end

      # Should descent into a directory stop? `rel_comps` is the directory's
      # path split on "/". Applies the hard-prune roots (root-anchored) and
      # the whole-subtree globs (contiguous component match). The one
      # predicate behind the walker's early pruning and the fast path's
      # ancestor check.
      def prune_dir?(rel_comps)
        return true if HARD_PRUNE_ROOTS.include?(rel_comps.first)

        @prunable_needles.any? do |needle, anchored|
          anchored ? rel_comps[0, needle.size] == needle : contiguous_components?(rel_comps, needle)
        end
      end

      # Walker-dialect file filter: reserved roots plus every ignore pattern
      # (prunable ones included, with the documented legacy fnmatch drift).
      def ignore_file?(rel)
        reserved_root?(rel) || @file_regexes.any? { |r| pattern_match?(r, rel) }
      end

      # Fast-path-dialect file filter: same reserved roots, but prunable
      # literal-stem subtree patterns are withheld because prune_dir? already
      # covered their ancestors (see initialize).
      def listed_file_ignored?(rel)
        reserved_root?(rel) || @listed_file_regexes.any? { |r| pattern_match?(r, rel) }
      end

      # Include dialect: no include patterns means "everything is included";
      # otherwise a file must match at least one pattern.
      def include_file?(rel)
        return true if @custom_includes.empty?

        @custom_includes.any? { |pattern| pattern_match?(pattern, rel) }
      end

      private

      def listed_file_patterns
        @patterns.reject do |pat|
          m = PRUNABLE_PATTERN.match(pat)
          m && !m[1].include?("*") && !m[1].include?("?") && !m[1].include?("[")
        end
      end

      def contiguous_components?(haystack, needle)
        return true if haystack == needle
        return false if haystack.size < needle.size

        (0..(haystack.size - needle.size)).any? do |offset|
          haystack[offset, needle.size] == needle
        end
      end

      # Runtime-owned roots are never indexed, whatever the ignore tables
      # say — the one predicate behind both listing strategies (the git
      # fast path and the generic walk).
      def reserved_root?(rel)
        rel == ".rubik" || rel.start_with?(".rubik/") || rel == ".git" || rel.start_with?(".git/")
      end

      # Translates a glob into a Regexp only where the mapping is exact: no
      # character classes, no leading-slash anchoring, and `**` only ever a
      # whole path segment (leading "**/", mid "/**/", trailing "/**").
      # Anything else keeps the pattern string and pattern_match? falls back
      # to File.fnmatch?, whose segment rules the Regexp form cannot express
      # (fnmatch "a**b" never crosses "/" and "**/x" also matches bare "x").
      def compile(ignore_patterns)
        ignore_patterns.map do |pat|
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
    end
  end
end
