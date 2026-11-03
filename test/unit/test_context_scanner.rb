# frozen_string_literal: true

require_relative "../test_helper"

class TestContextScanner < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    File.write(File.join(@temp_dir, ".gitignore"), "node_modules/\n*.log\n")
    FileUtils.mkdir_p(File.join(@temp_dir, "node_modules"))
    File.write(File.join(@temp_dir, "node_modules", "package.json"), "{}")

    FileUtils.mkdir_p(File.join(@temp_dir, "src"))
    File.write(File.join(@temp_dir, "src", "main.go"), "package main")
    File.write(File.join(@temp_dir, "build.zig"), "// zig build")
    File.write(File.join(@temp_dir, "app.log"), "log line")
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_respects_gitignore
    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir)
    files = scanner.scan

    refute_includes files.keys, "node_modules/package.json"
    refute_includes files.keys, "app.log"
    assert_includes files.keys, "src/main.go"
    assert_includes files.keys, "build.zig"
  end

  def test_detects_multiple_languages
    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir)
    files = scanner.scan
    langs = scanner.detect_languages(files)

    assert_includes langs, "go"
    assert_includes langs, "zig"
  end

  def test_ignores_rubik_internal_directory_and_detects_html
    FileUtils.mkdir_p(File.join(@temp_dir, ".rubik", "sessions"))
    File.write(File.join(@temp_dir, ".rubik", "sessions", "session_123.jsonl"), "{}")
    File.write(File.join(@temp_dir, "index.html"), "<html><body>Snake</body></html>")

    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir)
    files = scanner.scan
    langs = scanner.detect_languages(files)

    refute_includes files.keys, ".rubik/sessions/session_123.jsonl"
    assert_includes files.keys, "index.html"
    assert_includes langs, "html"
  end

  def test_pruning_walker_matches_glob_semantics_for_dot_and_ignored_dirs
    # Heavy ignored trees with deep content
    FileUtils.mkdir_p(File.join(@temp_dir, ".git", "objects", "ab"))
    File.write(File.join(@temp_dir, ".git", "config"), "[core]")
    File.write(File.join(@temp_dir, ".git", "objects", "ab", "pack.idx"), "\x0")
    FileUtils.mkdir_p(File.join(@temp_dir, "sub", "node_modules", "left-pad"))
    File.write(File.join(@temp_dir, "sub", "node_modules", "left-pad", "index.js"), "module.exports=1")
    FileUtils.mkdir_p(File.join(@temp_dir, "vendor", "cache"))
    File.write(File.join(@temp_dir, "vendor", "cache", "gem.rb"), "puts 1")

    # Unlisted dot-directory MUST still be walked and kept
    FileUtils.mkdir_p(File.join(@temp_dir, ".github", "workflows"))
    File.write(File.join(@temp_dir, ".github", "workflows", "ci.yml"), "on: push")

    # Regular sources
    FileUtils.mkdir_p(File.join(@temp_dir, "src", "deep"))
    File.write(File.join(@temp_dir, "src", "deep", "util.go"), "package main")
    File.write(File.join(@temp_dir, "docs.md"), "# doc")

    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir)
    keys = scanner.scan.keys

    assert_includes keys, ".github/workflows/ci.yml"
    assert_includes keys, "src/deep/util.go"
    assert_includes keys, "docs.md"
    refute_includes keys, ".git/config"
    refute_includes keys, ".git/objects/ab/pack.idx"
    refute_includes keys, "sub/node_modules/left-pad/index.js"
    refute_includes keys, "vendor/cache/gem.rb"
  end

  def test_custom_excludes_prune_subtrees_but_keep_other_files
    FileUtils.mkdir_p(File.join(@temp_dir, "docs", "drafts"))
    File.write(File.join(@temp_dir, "docs", "guide.md"), "# g")
    File.write(File.join(@temp_dir, "docs", "drafts", "wip.md"), "# wip")
    File.write(File.join(@temp_dir, "src.txt"), "hello")

    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir, excludes: ["docs/**"])
    keys = scanner.scan.keys

    assert_includes keys, "src.txt"
    refute_includes keys, "docs/guide.md"
    refute_includes keys, "docs/drafts/wip.md"
  end

  def test_gitignore_directory_pattern_excludes_whole_tree
    gitignore = File.join(@temp_dir, ".gitignore")
    File.write(gitignore, "#{File.read(gitignore)}tmp/\n")
    FileUtils.mkdir_p(File.join(@temp_dir, "tmp", "cache"))
    File.write(File.join(@temp_dir, "tmp", "scratch.rb"), "1")
    File.write(File.join(@temp_dir, "tmp", "cache", "blob.bin"), "\x0")
    File.write(File.join(@temp_dir, "main.rb"), "puts :hi")

    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir)
    keys = scanner.scan.keys

    assert_includes keys, "main.rb"
    refute_includes keys, "tmp/scratch.rb"
    refute_includes keys, "tmp/cache/blob.bin"
  end

  def test_ignore_pattern_matching_matches_fnmatch_semantics_for_exotic_globs
    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir)
    match = ->(path, patterns) { scanner.send(:ignored?, path, patterns) }

    # Bracket classes keep File.fnmatch? semantics (single-char class match)
    assert match.call("a.rb", ["[abc].rb"])
    # Mid "/**/" also matches with zero directories between
    assert match.call("docs/draft.md", ["docs/**/draft.md"])
    assert match.call("docs/a/draft.md", ["docs/**/draft.md"])
    # Leading "**/" also matches the bare path
    assert match.call("secret.txt", ["**/secret.txt"])
    # Single "*" spans one segment; the "**/pattern" probe covers deeper paths
    assert match.call("x.rb", ["*.rb"])
    assert match.call("dir/x.rb", ["*.rb"])
    # "**" inside a segment never crosses "/" in fnmatch
    refute match.call("a/b", ["a**b"])
    # Trailing "/**" requires at least one entry below the prefix
    assert match.call("foo/a/b", ["foo/**"])
    refute match.call("foo", ["foo/**"])
    # Leading-slash patterns never match relative paths (fnmatch semantics)
    refute match.call("build", ["/build"])
  end

  def test_symlinked_directories_are_not_descended
    real_dir = File.join(@temp_dir, "real")
    FileUtils.mkdir_p(real_dir)
    File.write(File.join(real_dir, "inner.rb"), "puts :inner")

    begin
      File.symlink("real", File.join(@temp_dir, "link"))
    rescue StandardError, NotImplementedError
      skip "File.symlink not supported on this platform/privilege level"
    end

    keys = Rubik::Context::Scanner.new(root_dir: @temp_dir).scan.keys

    assert_includes keys, "real/inner.rb"
    refute_includes keys, "link/inner.rb",
                    "dir symlinks must not be followed (root escape / cycles)"
  end

  def test_update_file_then_incremental_scan_reports_no_modification
    index = Rubik::Context::Index.new(root_dir: @temp_dir)
    index.full_scan

    target = File.join(@temp_dir, "src", "main.go")
    File.write(target, "package main // edited")
    assert index.update_file("src/main.go"), "edited file must be flagged changed"

    # update_file stores the probe result; the next scan must agree the file
    # is unchanged (mtime/hash unit mismatch previously forced a permanent
    # spurious "modified" on every subsequent scan).
    delta = index.incremental_scan
    assert_empty delta[:modified]
    assert_includes delta[:unchanged], "src/main.go"
  end

  def test_clean_scan_reports_no_abort
    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir, native: "off")
    scanner.scan

    refute scanner.last_scan_report.aborted
    assert_empty scanner.last_scan_report.reasons
  end

  def test_walk_dir_failure_marks_the_report_but_keeps_partial_results
    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir, native: "off")
    scanner.define_singleton_method(:subtree_ignored?) do |dir_rel, needles|
      raise "boom" if dir_rel == "src"

      Rubik::Context::Scanner::HARD_PRUNE_ROOTS.include?(dir_rel.split("/").first) ||
        needles.any? { |n| dir_rel.split("/") == n }
    end
    files = scanner.scan

    assert_includes files.keys, "build.zig", "unaffected entries survive"
    assert scanner.last_scan_report.aborted
    assert(scanner.last_scan_report.reasons.any? { |r| r.include?("walk failed") })
  end

  def test_scan_root_failure_marks_the_report
    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir, native: "off")
    scanner.define_singleton_method(:prunable_needles) { |_pats| raise "needles boom" }
    scanner.scan

    assert scanner.last_scan_report.aborted
    assert(scanner.last_scan_report.reasons.any? { |r| r.include?("root scan failed") })
  end

  def test_whole_scan_failure_marks_the_report
    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir, native: "off")
    scanner.define_singleton_method(:scan_root) { |_b, _p, _i, _prev| raise "root boom" }
    scanner.scan

    assert scanner.last_scan_report.aborted
    assert(scanner.last_scan_report.reasons.any? { |r| r.include?("scan aborted partway") })
  end

  def test_git_fast_path_failure_marks_the_report
    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir, native: "off")
    # Force the fast path, then let an inner call blow up INSIDE index_listed
    # so its own rescue is what marks the report.
    scanner.define_singleton_method(:git_listing?) { true }
    scanner.define_singleton_method(:entry_for) { |*_args, **_kw| raise "listing boom" }
    git_lister = Rubik::Context::GitLister
    git_lister.singleton_class.send(:alias_method, :orig_files_for_abort_test, :files)
    git_lister.singleton_class.send(:define_method, :files) { |_base| ["build.zig"] }
    begin
      scanner.scan
    ensure
      git_lister.singleton_class.send(:alias_method, :files, :orig_files_for_abort_test)
      git_lister.singleton_class.send(:remove_method, :orig_files_for_abort_test)
    end

    assert scanner.last_scan_report.aborted
    assert(scanner.last_scan_report.reasons.any? { |r| r.include?("ls-files fast path failed") })
  end

  def test_unreadable_directory_marks_the_report
    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir, native: "off")
    Dir.singleton_class.send(:alias_method, :orig_foreach_abort_test, :foreach)
    Dir.singleton_class.send(:define_method, :foreach) do |name, &blk|
      raise Errno::EACCES if name.end_with?("src")

      Dir.orig_foreach_abort_test(name, &blk)
    end
    begin
      files = scanner.scan
    ensure
      Dir.singleton_class.send(:alias_method, :foreach, :orig_foreach_abort_test)
      Dir.singleton_class.send(:remove_method, :orig_foreach_abort_test)
    end

    assert_includes files.keys, "build.zig"
    assert scanner.last_scan_report.aborted
    assert(scanner.last_scan_report.reasons.any? { |r| r.include?("directory unreadable") })
  end

  def test_report_resets_between_scans
    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir, native: "off")
    scanner.define_singleton_method(:prunable_needles) { |_pats| raise "needles boom" }
    scanner.scan
    assert scanner.last_scan_report.aborted

    scanner.singleton_class.send(:remove_method, :prunable_needles)
    scanner.scan

    refute scanner.last_scan_report.aborted
    assert_empty scanner.last_scan_report.reasons
  end
end
