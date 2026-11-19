# frozen_string_literal: true

require_relative "../test_helper"

# Issue #590: the shell-plane critical-path write gate must re-resolve each
# AST-derived write target (symlinks included) exactly like verify_path_write!,
# failing closed on resolution failure — a committed `evil -> .git/config`
# symlink must not let `echo x > evil` write into .git/.
class TestPathPolicyCriticalWrites < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @audit = Rubik::Security::AuditLog.new(nil)
    @policy = Rubik::Security::PathPolicy.new(audit: @audit)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_symlinked_redirect_target_into_git_is_rejected
    Dir.mkdir(File.join(@temp_dir, ".git"))
    File.write(File.join(@temp_dir, ".git", "config"), "[core]\n")
    File.symlink(".git/config", File.join(@temp_dir, "evil"))

    Dir.chdir(@temp_dir) do
      ast = Rubik::Security::Classifier.classify("echo x > evil")
      error = assert_raises(Rubik::Security::BlockedWriteError) do
        @policy.check_critical_path_writes!(ast, "echo x > evil")
      end

      assert_match(/symlink|resolved/, error.message)
    end
  end

  def test_resolution_failure_fails_closed
    # A symlink pointing at itself cannot be resolved; strict resolution
    # must fail closed even though the lexical name is harmless.
    File.symlink("loop", File.join(@temp_dir, "loop"))

    Dir.chdir(@temp_dir) do
      ast = Rubik::Security::Classifier.classify("echo x > loop")
      assert_raises(Rubik::Security::BlockedWriteError) do
        @policy.check_critical_path_writes!(ast, "echo x > loop")
      end
    end
  end

  def test_ordinary_writes_still_pass
    Dir.chdir(@temp_dir) do
      ast = Rubik::Security::Classifier.classify("echo x > plain.txt")
      assert @policy.check_critical_path_writes!(ast, "echo x > plain.txt")
    end
  end
end
