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
end
