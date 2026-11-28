# frozen_string_literal: true

require_relative "../test_helper"

# Regressions for issue #671: critical-path protection only covered one path
# level and a narrow set of write commands/option forms.
class TestSecurityIssue671 < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @audit = Rubik::Security::AuditLog.new(nil)
    @policy = Rubik::Security::PathPolicy.new(audit: @audit)
    @guard = Rubik::Security::Guard.new(audit_log_path: nil)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def assert_blocked(command)
    assert_raises(Rubik::Security::BlockedWriteError, "expected gate to BLOCK: #{command}") do
      @guard.verify_command_safety!(command)
    end
  end

  # 1. Nested critical paths.
  def test_nested_git_and_rubik_paths_are_critical
    [
      ".git/hooks/pre-commit", ".git/refs/heads/main", ".git/objects/ab/cdef", ".git/info/exclude",
      "proj/.git/hooks/pre-commit", ".rubik/agents/x.md", ".rubik/skills/a/SKILL.md",
      "sub/.rubik/a/b.yml", ".git", ".rubik"
    ].each { |path| assert @policy.critical_path?(path), "#{path} should be critical" }
  end

  def test_verify_path_write_blocks_nested_critical_paths
    [
      ".git/hooks/pre-commit", "proj/.git/hooks/pre-commit", ".rubik/skills/a/SKILL.md", ".git"
    ].each do |path|
      assert_raises(Rubik::Security::BlockedWriteError, "expected write to #{path} to be blocked") do
        @policy.verify_path_write!(path)
      end
    end
  end

  def test_symlink_recheck_blocks_nested_critical_path
    FileUtils.mkdir_p(File.join(@temp_dir, ".git", "hooks"))
    File.write(File.join(@temp_dir, ".git", "hooks", "pre-commit"), "")
    File.symlink(".git/hooks/pre-commit", File.join(@temp_dir, "evil"))

    Dir.chdir(@temp_dir) do
      error = assert_raises(Rubik::Security::BlockedWriteError) do
        @policy.verify_path_write!("evil")
      end
      assert_match(/symlink|resolved/, error.message)
    end
  end

  def test_redirect_to_nested_critical_path_is_blocked
    assert_blocked("echo x > proj/.git/hooks/pre-commit")
  end

  def test_copy_to_nested_critical_path_is_blocked
    assert_blocked("cp x proj/.git/hooks/pre-commit")
  end

  # 2. Common write commands and option-supplied targets.
  def test_common_write_commands_targeting_critical_paths_are_blocked
    [
      "rm -rf .git", "rm -f .env", "mkdir -p .git/hooks", "git clone https://x .rubik",
      "git init .git", "rsync -a src/ .git/"
    ].each { |command| assert_blocked(command) }
  end

  def test_option_supplied_write_targets_are_blocked
    [
      "cp --target-directory=.git/hooks payload", "mv -t .git payload",
      "tar -x -C .git -f a.tar", "curl -o .env https://x", "wget -O .env https://x"
    ].each { |command| assert_blocked(command) }
  end

  def test_glob_and_bare_critical_write_targets_are_blocked
    ["echo hi > .en?v", "echo hi > .git"].each { |command| assert_blocked(command) }
  end

  def test_ordinary_writes_stay_allowed
    assert @guard.verify_command_safety!("echo x > notes.txt")
    assert @guard.verify_command_safety!("cp a.txt b.txt")
  end

  def test_read_only_git_pathspecs_stay_allowed
    [
      "git status .git", "git log --oneline .git/config", "git diff .rubik/config.yml",
      "git show HEAD:.env"
    ].each { |command| assert @guard.verify_command_safety!(command), command }
  end
end
