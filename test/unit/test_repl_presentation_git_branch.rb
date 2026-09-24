# frozen_string_literal: true

require_relative "../test_helper"

class TestReplPresentationGitBranch < Minitest::Test
  def setup
    @orig_dir = Dir.pwd
    @temp_dir = Dir.mktmpdir
  end

  def teardown
    Dir.chdir(@orig_dir)
    remove_temp_dir(@temp_dir)
  end

  def test_detect_git_branch_in_linked_worktree
    real_git = File.join(@temp_dir, "realgit")
    FileUtils.mkdir_p(real_git)
    File.write(File.join(real_git, "HEAD"), "ref: refs/heads/wt-branch\n")

    worktree = File.join(@temp_dir, "worktree")
    FileUtils.mkdir_p(worktree)
    File.write(File.join(worktree, ".git"), "gitdir: #{real_git}\n")

    Dir.chdir(worktree)
    host = Object.new.extend(Rubik::REPL::Presentation)

    assert_equal "wt-branch", host.detect_git_branch, ".git-as-file (worktree) must resolve the branch"
  end

  def test_detect_git_branch_normal_repo_still_works
    FileUtils.mkdir_p(File.join(@temp_dir, ".git"))
    File.write(File.join(@temp_dir, ".git", "HEAD"), "ref: refs/heads/main\n")

    Dir.chdir(@temp_dir)
    host = Object.new.extend(Rubik::REPL::Presentation)

    assert_equal "main", host.detect_git_branch
  end

  def test_detect_git_branch_detached_head_short_sha
    FileUtils.mkdir_p(File.join(@temp_dir, ".git"))
    File.write(File.join(@temp_dir, ".git", "HEAD"), "1234567890abcdef\n")

    Dir.chdir(@temp_dir)
    host = Object.new.extend(Rubik::REPL::Presentation)

    assert_equal "1234567", host.detect_git_branch
  end
end
