# frozen_string_literal: true

require_relative "../test_helper"

# Pure value-object tests for the extracted ignore dialect (issue #498):
# no filesystem fixtures — a nil dir just skips .gitignore parsing since
# File.exist?(nil) would raise; we pass a dir that cannot hold a
# .gitignore instead. Paths use forward slashes only, so the suite is
# Windows-safe (no /tmp literals, no binmode pipes).
class TestContextIgnoreRules < Minitest::Test
  EMPTY_DIR = Dir.pwd # any real dir; its .gitignore (if any) only adds patterns these tests never touch

  def build(excludes: [], includes: [])
    Rubik::Context::IgnoreRules.build(dir: EMPTY_DIR, custom_excludes: excludes, custom_includes: includes)
  end

  def test_build_returns_a_frozen_value_object
    rules = build(excludes: ["docs/**"])

    assert rules.frozen?
    assert rules.custom_includes.frozen?
  end

  def test_prune_dir_matches_hard_prune_roots_only_at_the_root
    rules = build

    assert rules.prune_dir?([".git", "objects"])
    assert rules.prune_dir?(["AppData"])
    refute rules.prune_dir?(["src", "AppData"]), "nested hard-prune roots stay indexed"
    refute rules.prune_dir?(["src"])
  end

  def test_prune_dir_applies_whole_subtree_globs_contiguously
    rules = build(excludes: ["docs/**", "**/node_modules/**"])

    assert rules.prune_dir?(["docs"])
    assert rules.prune_dir?(["docs", "drafts"])
    assert rules.prune_dir?(["sub", "node_modules", "left-pad"])
    assert rules.prune_dir?(["node_modules"])
    refute rules.prune_dir?(["docsx"]), "no partial-component matches"
  end

  def test_ignore_file_rejects_reserved_roots_wherever_they_appear
    rules = build

    assert rules.ignore_file?(".rubik")
    assert rules.ignore_file?(".rubik/sessions/s.jsonl")
    assert rules.ignore_file?(".git/config")
    refute rules.ignore_file?("src/.gitkeep")
  end

  def test_ignore_file_covers_default_and_custom_patterns
    rules = build(excludes: ["*.tmp"])

    assert rules.ignore_file?("node_modules/left-pad/index.js")
    assert rules.ignore_file?(".zcode/state.json")
    assert rules.ignore_file?("scratch.tmp")
    refute rules.ignore_file?("src/main.rb")
  end

  def test_ignore_file_keeps_fnmatch_semantics_for_exotic_globs
    rules = build(excludes: ["[abc].rb", "a**b", "foo/**"])

    assert rules.ignore_file?("b.rb")
    refute rules.ignore_file?("a/b"), "fnmatch a**b never crosses /"
    assert rules.ignore_file?("foo/a/b")
    refute rules.ignore_file?("foo"), "trailing /** needs one entry below the prefix"
  end

  def test_listed_file_ignored_skips_prunable_literal_subtree_patterns
    rules = build(excludes: ["docs/**", "na*ce/**"])

    # Literal-stem "docs/**" is withheld from the per-file set: the fast
    # path's ancestor loop already pruned the "docs" directory via
    # prune_dir?, so re-testing the glob per file is redundant.
    assert rules.ignore_file?("docs/draft.md")
    refute rules.listed_file_ignored?("docs/draft.md")
    assert rules.prune_dir?(["docs"])
    # Wildcard stems stay in the per-file set (ancestors may not prune them).
    assert rules.listed_file_ignored?("naxce/x.rb")
  end

  def test_include_file_is_pass_through_without_patterns
    rules = build

    assert rules.include_file?("anything/at/all.rb")
  end

  def test_include_file_requires_a_match_when_patterns_present
    rules = build(includes: ["*.rb", "**/guide.md"])

    assert rules.include_file?("app.rb")
    assert rules.include_file?("docs/deep/guide.md")
    refute rules.include_file?("src/main.go")
  end

  def test_parse_gitignore_widens_directory_entries_and_drops_comments
    dir = Dir.mktmpdir
    File.write(File.join(dir, ".gitignore"), "# comment\n\n*.log\ntmp/\n")
    patterns = Rubik::Context::IgnoreRules.parse_gitignore(dir)

    assert_equal ["*.log", "tmp/**"], patterns
  ensure
    FileUtils.remove_entry(dir) if dir
  end
end
