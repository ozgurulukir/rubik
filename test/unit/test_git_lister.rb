# frozen_string_literal: true

require_relative "../test_helper"

# Plan 52 Faz B2: `git ls-files` fast listing with walker parity.
class TestGitLister < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_returns_nil_outside_a_git_repo
    skip unless git_installed?

    assert_nil Rubik::Context::GitLister.files(@temp_dir)
  end

  def test_lists_tracked_and_untracked_excluding_gitignored
    skip unless git_installed?

    init_repo_with_gitignore
    FileUtils.mkdir_p(File.join(@temp_dir, "node_modules"))
    File.write(File.join(@temp_dir, "node_modules", "pkg.json"), "{}")
    File.write(File.join(@temp_dir, "untracked.rb"), "x = 1")

    files = Rubik::Context::GitLister.files(@temp_dir)
    assert_includes files, "tracked.rb"
    assert_includes files, "untracked.rb"
    refute_includes files, "ignored.log"
    refute_includes files, "node_modules/pkg.json"
  end

  def test_enabled_switch_env_beats_config
    without_env("RUBIK_NATIVE") do
      assert Rubik::Context::GitLister.enabled?("auto")
      assert Rubik::Context::GitLister.enabled?("on")
      refute Rubik::Context::GitLister.enabled?("off")
      refute Rubik::Context::GitLister.enabled?("auto", env: { "RUBIK_NATIVE" => "off" })
      assert Rubik::Context::GitLister.enabled?("off", env: { "RUBIK_NATIVE" => "on" })
    end
  end

  def test_scanner_git_path_produces_walker_identical_keys_and_order
    skip unless git_installed?

    init_repo_with_gitignore
    # A directory and a lexically-neighbouring file: the walker emits the
    # whole "lib/" subtree BEFORE "license.txt" ("/" < "." byte-wise), a
    # flat lexical sort would not.
    FileUtils.mkdir_p(File.join(@temp_dir, "lib", "deep"))
    File.write(File.join(@temp_dir, "lib", "util.rb"), "x = 1")
    File.write(File.join(@temp_dir, "lib", "deep", "core.rb"), "x = 2")
    File.write(File.join(@temp_dir, "license.txt"), "MIT")

    walker = Rubik::Context::Scanner.new(root_dir: @temp_dir, native: "off").scan
    fast = Rubik::Context::Scanner.new(root_dir: @temp_dir, native: "on").scan

    assert_equal walker.keys, fast.keys
    assert_equal(walker.keys, fast.keys.sort_by { |k| walker.keys.index(k) })
    walker.each do |key, info|
      assert_equal info[:size], fast[key][:size], key
      if info[:language].nil?
        assert_nil fast[key][:language], key
      else
        assert_equal info[:language], fast[key][:language], key
      end
    end
  end

  # git ls-files --cached lists TRACKED files even when a later gitignore or
  # Rubik's DEFAULT_IGNORES covers them, and the per-file fnmatch in
  # `ignored?` treats a trailing `**` as a single segment — so a tracked
  # vendor/bundle/deep.rb would leak into the fast path unless ancestors are
  # pruned with the walker's whole-subtree semantics.
  def test_scanner_fast_path_prunes_tracked_default_ignore_subtrees
    skip unless git_installed?

    FileUtils.mkdir_p(File.join(@temp_dir, "vendor", "bundle"))
    FileUtils.mkdir_p(File.join(@temp_dir, "build1"))
    File.write(File.join(@temp_dir, "vendor", "bundle", "deep.rb"), "x = 9")
    File.write(File.join(@temp_dir, "build1", "ignored.rb"), "x = 2")
    File.write(File.join(@temp_dir, "app.rb"), "x = 1")
    File.write(File.join(@temp_dir, ".gitignore"), "build[0-9]/**\n")
    system("git", "-C", @temp_dir, "init", "-q")
    system("git", "-C", @temp_dir, "add", "vendor", "app.rb", ".gitignore")
    system("git", "-C", @temp_dir, "add", "-f", "build1/ignored.rb")
    system("git", "-C", @temp_dir, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init")

    walker = Rubik::Context::Scanner.new(root_dir: @temp_dir, native: "off").scan
    fast = Rubik::Context::Scanner.new(root_dir: @temp_dir, native: "on").scan

    refute_includes walker.keys, "vendor/bundle/deep.rb", "walker prunes the vendor subtree"
    refute_includes walker.keys, "build1/ignored.rb", "walker applies bracket-class ignore patterns"
    assert_includes Rubik::Context::GitLister.files(@temp_dir), "vendor/bundle/deep.rb", "ls-files lists tracked files regardless of ignore rules"
    assert_includes Rubik::Context::GitLister.files(@temp_dir), "build1/ignored.rb", "ls-files lists tracked bracket-class ignores"
    assert_equal walker.keys, fast.keys, "fast path must prune the same subtrees as the walker"
  end

  # The ancestor-verdict memo in the fast path must stay exact: siblings
  # reuse cached verdicts, and a pruned name nested under a kept directory
  # ("lib/vendor") must not inherit its parent's keep verdict — the needle
  # matches CONTIGUOUSLY anywhere in the path, so it prunes regardless.
  def test_scanner_fast_path_dir_memo_is_exact_for_siblings_and_nesting
    skip unless git_installed?

    init_repo_with_gitignore
    FileUtils.mkdir_p([
                        File.join(@temp_dir, "vendor", "bundle", "inner"),
                        File.join(@temp_dir, "lib", "deep"),
                        File.join(@temp_dir, "lib", "vendor")
                      ])
    File.write(File.join(@temp_dir, "vendor", "bundle", "a.rb"), "x = 1")
    File.write(File.join(@temp_dir, "vendor", "bundle", "inner", "b.rb"), "x = 2")
    File.write(File.join(@temp_dir, "lib", "a.rb"), "x = 3")
    File.write(File.join(@temp_dir, "lib", "b.rb"), "x = 4")
    File.write(File.join(@temp_dir, "lib", "deep", "c.rb"), "x = 5")
    File.write(File.join(@temp_dir, "lib", "vendor", "d.rb"), "x = 6")

    walker = Rubik::Context::Scanner.new(root_dir: @temp_dir, native: "off").scan
    fast = Rubik::Context::Scanner.new(root_dir: @temp_dir, native: "on").scan

    assert_equal walker.keys, fast.keys, "memoized fast path must match the walker exactly"
    assert_includes fast.keys, "lib/a.rb"
    assert_includes fast.keys, "lib/b.rb"
    assert_includes fast.keys, "lib/deep/c.rb"
    refute_includes fast.keys, "vendor/bundle/a.rb"
    refute_includes fast.keys, "vendor/bundle/inner/b.rb"
    refute_includes fast.keys, "lib/vendor/d.rb", "nested 'vendor' still prunes under the memo"
  end

  private

  def git_installed?
    system("git", "--version", out: File::NULL)
  end

  def init_repo_with_gitignore
    File.write(File.join(@temp_dir, ".gitignore"), "node_modules/\n*.log\n")
    File.write(File.join(@temp_dir, "tracked.rb"), "x = 0")
    File.write(File.join(@temp_dir, "ignored.log"), "noise")
    system("git", "-C", @temp_dir, "init", "-q")
    system("git", "-C", @temp_dir, "add", "tracked.rb")
    system("git", "-C", @temp_dir, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init")
  end

  def without_env(key)
    old = ENV.fetch(key, nil)
    ENV.delete(key)
    yield
  ensure
    ENV[key] = old
  end
end
