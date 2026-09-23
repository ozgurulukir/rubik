# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/guard"
require_relative "../../lib/rubik/tools/builtins/exec"

# Structured segment payloads on BlockedWriteError: the guard collects every
# innermost dangerous segment (with trigger evidence), the safe-sibling roll
# call, the one-line wrapper preview, and gate-honest allowlist entries.
class TestGuardDangerousSegments < Minitest::Test
  def setup
    @guard = Rubik::Security::Guard.new
  end

  def block!(cmd)
    @guard.verify_command_safety!(cmd)
    flunk "expected #{cmd.inspect} to be blocked"
  rescue Rubik::Security::BlockedWriteError => e
    e
  end

  def test_wrapped_script_reports_every_segment_with_evidence
    script = <<~SCRIPT
      bash -c '
      git checkout -q main
      git merge --no-edit -q review-pr-1
      git merge --abort
      git branch -D merge-sim
      '
    SCRIPT

    err = block!(script)
    report = err.segment_report

    refute_nil report
    segments = report[:segments]
    assert_equal 2, segments.size
    assert_equal(["git.merge", "git.branch"], segments.map { |s| s[:rule] })
    assert_equal(["--abort", "-D"], segments.map { |s| s[:option] })
    assert_equal([1, 1], segments.map { |s| s[:depth] })
    assert_equal "git merge --abort", segments[0][:display]
    assert_includes segments[1][:argv], "-D"

    assert_equal "bash -c '...'", report[:wrapper_preview]
    assert_equal ["bash -c"], report[:allowlist_entries]
    assert_includes report[:safe], "git checkout"
    assert_includes report[:safe], "git merge"
    refute_includes report[:safe], "bash"

    # Scalar rule_name keeps its historical first-innermost semantics.
    assert_equal "git.merge", err.rule_name
  end

  def test_flag_permutation_hint_covers_the_delegation_flag
    err = block!('bash -e -c "rm -rf /"')

    # A naive first-two-tokens entry ("bash -e") would NOT match the gate's
    # argv prefix; the hint must span binary..flag.
    assert_equal ["bash -e -c"], err.segment_report[:allowlist_entries]
  end

  def test_silent_system_path_inner_carries_reason
    err = block!('bash -c "cp a /etc/passwd"')

    segment = err.segment_report[:segments].first
    assert_equal "cp", segment[:rule]
    assert_nil segment[:option]
    assert_includes segment[:reason], "system path /etc/passwd"
  end

  def test_single_top_level_dangerous_has_report_but_no_wrapper
    err = block!("rm -rf /")

    report = err.segment_report
    assert_equal 1, report[:segments].size
    assert_equal 0, report[:segments].first[:depth]
    assert_nil report[:wrapper_preview]
    # Full argv entries open the gate for top-level commands.
    assert_equal ["rm -rf /"], report[:allowlist_entries]
  end

  def test_guidance_renders_segment_format_only_for_wrapper_or_multi
    concise = Rubik::Tools::RunCommandTool.blocked_guidance(block!("rm -rf /"))
    assert_includes concise, "was denied (rule: rm)"
    refute_includes concise, "dangerous segment"

    wrapped = Rubik::Tools::RunCommandTool.blocked_guidance(block!('bash -c "rm -rf /"'))
    assert_includes wrapped, "1 dangerous segment in `bash -c '...'"
    assert_includes wrapped, '!allow-cmd add "bash -c"'
  end

  # The gate demands an entry for EVERY top-level command — safe siblings
  # included — so the entry set must cover them all, or the operator follows
  # the printed remedy and the gate still refuses.
  def test_compound_with_safe_sibling_gets_complete_entry_set
    err = block!("git checkout main && git push --force")

    report = err.segment_report
    assert_equal(["git.push"], report[:segments].map { |s| s[:rule] })
    assert_includes report[:safe], "git checkout"
    assert_includes report[:allowlist_entries], "git checkout main"
    assert_includes report[:allowlist_entries], "git push --force"
  end

  def test_wrapper_plus_top_level_dangerous_lists_both_entries
    err = block!("bash -c 'git merge --abort' && git branch -D feature")

    entries = err.segment_report[:allowlist_entries]
    assert_includes entries, "bash -c"
    assert_includes entries, "git branch -D feature"
  end

  # Entries are whitespace-split on add; an argv token containing spaces can
  # never be matched, so the entry must stop before it.
  def test_entry_stops_before_whitespace_token
    err = block!('git branch -D "feature x"')

    assert_includes err.segment_report[:allowlist_entries], "git branch -D"
  end

  # Redirect-bearing segments render their effects, not just their argv:
  # `echo pwned > /etc/shadow` names what would have been written where.
  def test_wrapped_redirect_segment_renders_redirect
    err = block!("bash -c 'echo pwned > /etc/shadow'")

    segment = err.segment_report[:segments].first
    assert_equal "echo pwned > /etc/shadow", segment[:display]
    assert_equal ["echo", "pwned"], segment[:argv]
    assert_equal "echo", segment[:rule]
    assert_includes segment[:reason], "system path /etc/shadow"
    assert_equal ["bash -c"], err.segment_report[:allowlist_entries]
  end

  def test_wrapped_redirect_guidance_lists_segment
    guidance = Rubik::Tools::RunCommandTool.blocked_guidance(block!("bash -c 'echo pwned > /etc/shadow'"))

    assert_includes guidance, "1 dangerous segment in `bash -c '...'`"
    assert_includes guidance, "echo pwned > /etc/shadow"
    assert_includes guidance, '!allow-cmd add "bash -c"'
  end

  # Expression-level danger: no segment exists, so the error carries the
  # composed reason and a DISTINCT rule label (not "dangerous_pattern" —
  # that means the catastrophic regex fired, and it never ran here).
  def test_expression_block_carries_honest_reason_and_distinct_rule
    err = block!("cd /etc && touch x")

    assert_nil err.segment_report
    assert_equal "expression_level", err.rule_name
    assert_equal "mutating pipeline (touch) touches system directory /etc", err.classification_reason
    assert_includes err.message, "reason: mutating pipeline (touch)"
  end

  def test_expression_guidance_variant_without_allowlist_hint
    guidance = Rubik::Tools::RunCommandTool.blocked_guidance(block!("cd /etc && touch x"))

    assert guidance.start_with?("Security blocked: `cd /etc && touch x` — nothing was executed.")
    assert_includes guidance, "mutating pipeline (touch) touches system directory /etc."
    assert_includes guidance, "Restructure"
    refute_includes guidance, "!allow-cmd"
  end

  # The "dangerous_ast" sentinel must stay exclusive to expression-level
  # elevations: a dangerous command whose inners are all safe reports its
  # OWN elevation reason, not the sentinel.
  def test_dangerous_wrapper_with_safe_inner_reports_own_reason
    err = block!("bash -c 'echo hi' > /etc/shadow")

    assert_includes err.message, "elevated by output redirect; elevated to DANGEROUS: system path /etc/shadow"
    refute_includes err.message, "dangerous_ast"
    assert_equal "bash", err.rule_name
    assert_nil err.classification_reason
  end
end
