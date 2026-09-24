# frozen_string_literal: true

require_relative "../test_helper"

class TestGitInfo < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_git_repo_detection
    git_info = Rubik::Context::GitInfo.new(root_dir: @temp_dir)
    refute git_info.git_repo?

    FileUtils.mkdir_p(File.join(@temp_dir, ".git"))
    assert git_info.git_repo?
  end

  def test_active_branch_resolution
    git_info = Rubik::Context::GitInfo.new(root_dir: @temp_dir)
    assert_nil git_info.active_branch

    git_dir = File.join(@temp_dir, ".git")
    FileUtils.mkdir_p(git_dir)

    File.write(File.join(git_dir, "HEAD"), "ref: refs/heads/main\n")
    assert_equal "main", git_info.active_branch

    File.write(File.join(git_dir, "HEAD"), "1234567890abcdef\n")
    assert_equal "1234567", git_info.active_branch
  end

  def test_active_branch_in_linked_worktree
    real_git = File.join(@temp_dir, "realgit")
    FileUtils.mkdir_p(real_git)
    File.write(File.join(real_git, "HEAD"), "ref: refs/heads/wt-branch\n")

    worktree = File.join(@temp_dir, "worktree")
    FileUtils.mkdir_p(worktree)
    File.write(File.join(worktree, ".git"), "gitdir: #{real_git}\n")

    git_info = Rubik::Context::GitInfo.new(root_dir: worktree)
    assert git_info.git_repo?, "worktree (.git as FILE) is a git repo"
    assert_equal "wt-branch", git_info.active_branch
  end

  def test_active_branch_with_relative_gitdir
    real_git = File.join(@temp_dir, "realgit")
    FileUtils.mkdir_p(real_git)
    File.write(File.join(real_git, "HEAD"), "ref: refs/heads/rel-wt\n")

    worktree = File.join(@temp_dir, "nested", "worktree")
    FileUtils.mkdir_p(worktree)
    File.write(File.join(worktree, ".git"), "gitdir: ../../realgit\n")

    git_info = Rubik::Context::GitInfo.new(root_dir: worktree)
    assert_equal "rel-wt", git_info.active_branch, "relative gitdir resolves against the root"
  end

  def test_status_with_mock_runner
    mock_runner = lambda do |cmd|
      if cmd.include?("status")
        [" M file.txt\n", 0]
      else
        ["", 1]
      end
    end

    git_info = Rubik::Context::GitInfo.new(root_dir: @temp_dir, process_runner: mock_runner)
    FileUtils.mkdir_p(File.join(@temp_dir, ".git"))
    File.write(File.join(@temp_dir, ".git", "HEAD"), "ref: refs/heads/feature")

    status = git_info.status
    assert status[:git]
    assert_equal "feature", status[:branch]
    assert status[:dirty]
  end

  def test_default_runner_prevents_command_injection
    canary_file = File.join(@temp_dir, "canary_injected.txt")
    refute File.exist?(canary_file)

    git_info = Rubik::Context::GitInfo.new(root_dir: @temp_dir)
    # Attempt command injection via cmd string
    malicious_cmd = "status; touch #{canary_file}"
    git_info.send(:default_runner, malicious_cmd)

    # Shell should NOT have executed `touch`
    refute File.exist?(canary_file), "Command injection vulnerability! Canary file was created."
  end

  def test_default_runner_handles_array_and_string_commands
    git_info = Rubik::Context::GitInfo.new(root_dir: @temp_dir)

    out, code = git_info.send(:default_runner, ["status"])
    assert_kind_of String, out
    assert_kind_of Integer, code

    out_str, code_str = git_info.send(:default_runner, "status")
    assert_kind_of String, out_str
    assert_kind_of Integer, code_str
  end
end
