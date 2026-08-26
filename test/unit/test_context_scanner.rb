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
end
