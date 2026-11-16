# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/segment_report"

# Direct unit tests for the pure SegmentReport builder (#500): classified
# command trees go in, frozen plain-data guidance hashes come out — no
# blocked commands, no classifier stack, no gate.
class TestSecuritySegmentReport < Minitest::Test
  Cmd = Struct.new(:classification, :argv, :command, :matched_rule,
                   :overriding_option, :classification_reason, :inner_commands,
                   :redirects, :delegation_mode, :delegation_source,
                   keyword_init: true)

  def leaf(classification: :safe, argv: ["git"], command: nil, rule: nil,
           reason: nil, redirects: nil, delegation_mode: nil, delegation_source: nil)
    Cmd.new(classification: classification, argv: argv,
            command: command || argv.first.to_s.split,
            matched_rule: rule, overriding_option: nil,
            classification_reason: reason, inner_commands: nil,
            redirects: redirects,
            delegation_mode: delegation_mode, delegation_source: delegation_source)
  end

  def wrapper(argv:, inners:)
    Cmd.new(classification: :dangerous, argv: argv, command: argv.first.to_s.split,
            matched_rule: "bash", overriding_option: nil,
            classification_reason: "delegates", inner_commands: inners,
            redirects: nil)
  end

  def test_nil_when_no_command_is_dangerous
    cmds = [leaf(argv: ["git", "status"]), leaf(argv: ["ls", "-la"])]
    assert_nil Rubik::Security::SegmentReport.build(cmds)
  end

  def test_dangerous_leaf_becomes_segment_with_frozen_argv
    cmds = [leaf(argv: ["git", "status"], command: ["git", "status"]), leaf(classification: :dangerous, argv: ["rm", "-rf", "/"],
                                                                            rule: "rm", reason: "recursive_force_root")]
    report = Rubik::Security::SegmentReport.build(cmds)

    assert report.frozen?
    assert_equal 1, report[:segments].size
    seg = report[:segments].first
    assert_equal "rm -rf /", seg[:display]
    assert_equal ["rm", "-rf", "/"], seg[:argv]
    assert seg[:argv].frozen?
    assert_equal "rm", seg[:rule]
    assert_equal 0, seg[:depth]
    assert_equal ["git status"], report[:safe]
    assert_nil report[:wrapper_preview]
  end

  def test_wrapper_reports_inner_leaf_not_the_wrapper
    inner = leaf(classification: :dangerous, argv: ["rm", "-rf", "/"], rule: "rm",
                 delegation_mode: "flag_value_is_expression", delegation_source: "-c")
    cmds = [wrapper(argv: ["bash", "-c", "rm -rf /"], inners: [inner])]
    report = Rubik::Security::SegmentReport.build(cmds)

    assert_equal ["rm", "-rf", "/"], report[:segments].first[:argv]
    assert_equal 1, report[:segments].first[:depth]
    assert report[:wrapper_preview].start_with?("bash")
    refute_includes report[:wrapper_preview], "rm -rf /"
    assert_includes report[:allowlist_entries], "bash -c"
  end

  def test_rest_argv_wrapper_entry_is_bare_binary
    inner = leaf(classification: :dangerous, argv: ["nmap", "-A", "host"], rule: "nmap",
                 delegation_mode: "rest_argv", delegation_source: "nmap")
    cmds = [wrapper(argv: ["sudo", "nmap", "-A", "host"], inners: [inner])]
    assert_includes Rubik::Security::SegmentReport.build(cmds)[:allowlist_entries], "sudo"
  end

  def test_allowlist_entry_stops_at_whitespace_token
    cmds = [leaf(classification: :dangerous, argv: ["git", "feature x", "extra"], rule: "git")]
    assert_equal "git", Rubik::Security::SegmentReport.build(cmds)[:allowlist_entries].first
  end

  def test_redirects_render_in_display_but_stay_out_of_argv
    red = Struct.new(:operator, :target).new(">", "/etc/shadow")
    cmds = [leaf(classification: :dangerous, argv: ["echo", "pwned"], rule: "echo", redirects: [red])]
    seg = Rubik::Security::SegmentReport.build(cmds)[:segments].first

    assert_equal "echo pwned > /etc/shadow", seg[:display]
    assert_equal ["echo", "pwned"], seg[:argv]
  end

  def test_display_caps_long_segments
    long = ["echo", "a" * 300]
    cmds = [leaf(classification: :dangerous, argv: long, rule: "echo")]
    display = Rubik::Security::SegmentReport.build(cmds)[:segments].first[:display]

    # Truncation is text[0, CAP - 1] + "..." — the string can reach CAP + 2.
    assert display.length <= Rubik::Security::SegmentReport::SEGMENT_DISPLAY_CAP + 2
    assert display.end_with?("...")
  end
end
