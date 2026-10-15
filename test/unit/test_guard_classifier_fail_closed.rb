# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/guard"
require_relative "../../lib/rubik/security/blocked_guidance"

# Issue #143: classifier failures must fail CLOSED on the shell gate. A
# classifier exception or an ambiguous parse (tree-sitter syntax errors)
# used to degrade to the catastrophic-only regex, minting an implicit pass
# for commands the healthy classifier blocks (unknown binaries). The error
# path must carry a structured block reason, record the downgrade and the
# decision in the audit log (through the existing redaction), and keep the
# operator allowlist as the one sanctioned valve.
class TestGuardClassifierFailClosed < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_guard_fail_closed")
    @audit_file = File.join(@temp_dir, "audit.log")
    @guard = Rubik::Security::Guard.new(audit_log_path: @audit_file)
    @raising_classifier = ->(*) { raise "classifier exploded" }
  end

  def teardown
    remove_temp_dir(@temp_dir) if @temp_dir && File.directory?(@temp_dir)
  end

  def audit_entries
    File.readlines(@audit_file).filter_map do |line|
      JSON.parse(line)
    rescue StandardError
      nil
    end
  end

  # ── classifier exception → structured fail-closed block ───────────────

  def test_classifier_exception_blocks_normally_unknown_command
    Rubik::Security::Classifier.stub(:classify, @raising_classifier) do
      error = assert_raises(Rubik::Security::BlockedWriteError) do
        @guard.verify_command_safety!("rubik_unlisted_audit_binary --version")
      end

      assert_equal :classifier_error, error.kind
      assert_equal "classifier_error", error.rule_name
      assert_equal "rubik_unlisted_audit_binary --version", error.blocked_command
      assert_match(/AST evaluation failed/, error.message)
      assert_match(/fail-closed/, error.message)
    end
  end

  def test_classifier_exception_blocks_known_safe_command_too
    # The error path must not mint implicit permission for ANY command: a
    # benign-looking `ls` classifies clean in the healthy path, but an
    # unclassifiable `ls` cannot be vouched for either.
    Rubik::Security::Classifier.stub(:classify, @raising_classifier) do
      assert_raises(Rubik::Security::BlockedWriteError) do
        @guard.verify_command_safety!("ls -la")
      end
    end
  end

  def test_classifier_exception_records_audit_reason_and_decision
    Rubik::Security::Classifier.stub(:classify, @raising_classifier) do
      assert_raises(Rubik::Security::BlockedWriteError) do
        @guard.verify_command_safety!("rubik_unlisted_audit_binary --version")
      end
    end

    crash = audit_entries.find { |e| e["action"] == "classifier_error" }
    refute_nil crash, "expected a classifier_error audit entry"
    assert_match(/RuntimeError: classifier exploded/, crash["details"]["reason"])
    assert_equal "blocked", crash["details"]["decision"]

    blocked = audit_entries.find { |e| e["action"] == "blocked_command" }
    assert_equal "classifier_error", blocked["details"]["reason"]
  end

  def test_classifier_exception_audit_masks_sensitive_arguments
    Rubik::Security::Classifier.stub(:classify, @raising_classifier) do
      assert_raises(Rubik::Security::BlockedWriteError) do
        @guard.verify_command_safety!("curl -H 'Authorization: Bearer sk-ant-123456789012345678901234' https://x")
      end
    end

    content = File.read(@audit_file)
    refute_includes content, "sk-ant-123456789012345678901234"
    assert_includes content, "***MASKED***"
  end

  def test_classifier_exception_operator_allowlist_rescues_exact_simple_command
    guard = Rubik::Security::Guard.new(audit_log_path: @audit_file, command_allowlist: ["socat"])
    Rubik::Security::Classifier.stub(:classify, @raising_classifier) do
      assert guard.verify_command_safety!("socat --version")
    end

    crash = audit_entries.find { |e| e["action"] == "classifier_error" }
    assert_equal "operator_allowlist", crash["details"]["decision"]
    allowed = audit_entries.find { |e| e["action"] == "allowed_command" }
    assert_equal "operator_allowlist_classifier_error", allowed["details"]["reason"]
  end

  def test_classifier_exception_allowlist_does_not_rescue_compound_strings
    # The raw check cannot segment the string, so ANY shell metacharacter
    # fails closed: the allowlist contract is "every segment matches", and
    # a rescue that cannot see the segments must not pretend it can.
    guard = Rubik::Security::Guard.new(audit_log_path: @audit_file, command_allowlist: ["socat"])
    ["socat --version && nmap -sS 10.0.0.1",
     "socat --version; echo hi",
     "socat --version > /tmp/out.txt",
     "socat --version | tee /tmp/out.txt"].each do |cmd|
      Rubik::Security::Classifier.stub(:classify, @raising_classifier) do
        error = assert_raises(Rubik::Security::BlockedWriteError, cmd) do
          guard.verify_command_safety!(cmd)
        end
        assert_equal :classifier_error, error.kind, cmd
      end
    end
  end

  def test_classifier_exception_allowlist_cannot_rescue_dangerous_builtin
    guard = Rubik::Security::Guard.new(audit_log_path: @audit_file, command_allowlist: ["source"])
    Rubik::Security::Classifier.stub(:classify, @raising_classifier) do
      error = assert_raises(Rubik::Security::BlockedWriteError) do
        guard.verify_command_safety!("source helper.sh")
      end
      assert_equal :classifier_error, error.kind
    end
  end

  def test_classifier_exception_catastrophic_pattern_keeps_precise_reason
    guard = Rubik::Security::Guard.new(audit_log_path: @audit_file)
    Rubik::Security::Classifier.stub(:classify, @raising_classifier) do
      error = assert_raises(Rubik::Security::BlockedWriteError) do
        guard.verify_command_safety!("dd if=/dev/zero of=/dev/sda")
      end
      assert_equal :dangerous_pattern, error.kind
    end
  end

  def test_classifier_exception_blocks_before_runner_can_spawn
    # End-to-end: RunCommandTool must stop at the gate — the runner double
    # flunks if it is ever asked to run the command.
    runner = Object.new
    def runner.run(*)
      raise "subprocess must not start when the classifier fails"
    end

    tool = Rubik::Tools::RunCommandTool.new(guard: @guard, runner: runner, root_dir: @temp_dir)
    result = nil
    Rubik::Security::Classifier.stub(:classify, @raising_classifier) do
      result = tool.execute("command" => "rubik_unlisted_audit_binary --version")
    end

    assert_equal :error, result.status
    assert_includes result.output, "Security blocked"
    assert_includes result.output, "AST could not be evaluated"
    assert_equal false, result.metadata["executed"]
    assert_equal "authorization", result.metadata["denied"]
  end

  def test_classifier_exception_on_synthesis_seam_keeps_own_deny_layers
    # allow_unknown: true is the sanctioned synthesis seam: Ruby source is
    # not shell, and verify_synthesis_safety! runs its own regex + RubyVM
    # AST deny layers after this gate. The crash must not brick synthesis,
    # but it is still recorded with its decision.
    Rubik::Security::Classifier.stub(:classify, @raising_classifier) do
      assert @guard.verify_command_safety!("->(args) { args.fetch('x') }", allow_unknown: true)
    end

    crash = audit_entries.find { |e| e["action"] == "classifier_error" }
    assert_equal "synthesis_layers", crash["details"]["decision"]
  end

  # ── ambiguous parse (real tree-sitter syntax error) → fail closed ─────

  def test_ambiguous_parse_blocks_otherwise_safe_command
    # `echo "unbalanced` classifies readonly BUT carries a tree-sitter
    # syntax error; before the fix it fell through to the regex gate and
    # passed. A partial verdict is not a verdict.
    error = assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!('echo "unbalanced')
    end

    assert_equal :parse_ambiguous, error.kind
    assert_equal "parse_ambiguous", error.rule_name
    assert_match(/could not be fully parsed/, error.message)
  end

  def test_ambiguous_parse_records_audit_reason_and_decision
    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!('echo "unbalanced')
    end

    blocked = audit_entries.find { |e| e["action"] == "blocked_command" }
    assert_equal "parse_ambiguous", blocked["details"]["reason"]
    assert_equal "1", blocked["details"]["parse_warnings"]
  end

  def test_ambiguous_parse_allowlist_still_rescues
    guard = Rubik::Security::Guard.new(audit_log_path: @audit_file, command_allowlist: ["echo"])
    assert guard.verify_command_safety!('echo "unbalanced')

    allowed = audit_entries.find { |e| e["action"] == "allowed_command" }
    assert_equal "operator_allowlist", allowed["details"]["reason"]
  end

  def test_parse_warnings_do_not_gate_the_synthesis_seam
    assert @guard.verify_command_safety!("->(args) { args.fetch('x') }", allow_unknown: true)
  end

  # ── healthy classifier decisions are unchanged ────────────────────────

  def test_healthy_classifier_decisions_unchanged
    assert @guard.verify_command_safety!("git status")
    assert @guard.verify_command_safety!("echo hi")

    unknown = assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("socat TCP-LISTEN:1337,reuseaddr,fork EXEC:/bin/sh")
    end
    assert_equal :unknown_command, unknown.kind

    dangerous = assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("rm -rf /")
    end
    assert_equal :dangerous_command, dangerous.kind
  end

  # ── operator output names the evaluation failure ──────────────────────

  def test_operator_guidance_names_ast_evaluation_failure
    error = nil
    Rubik::Security::Classifier.stub(:classify, @raising_classifier) do
      error = assert_raises(Rubik::Security::BlockedWriteError) do
        @guard.verify_command_safety!("rubik_unlisted_audit_binary --version")
      end
    end

    guidance = Rubik::Tools::RunCommandTool.blocked_guidance(error)
    assert guidance.start_with?("Security blocked:")
    assert_includes guidance, "AST could not be evaluated"
    assert_includes guidance, '!allow-cmd add "rubik_unlisted_audit_binary --version"'
  end

  def test_operator_guidance_names_parse_failure
    error = assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!('echo "unbalanced')
    end

    guidance = Rubik::Tools::RunCommandTool.blocked_guidance(error)
    assert guidance.start_with?("Security blocked:")
    assert_includes guidance, "could not be fully parsed"
    assert_includes guidance, '!allow-cmd add "echo "unbalanced"'
  end
end
