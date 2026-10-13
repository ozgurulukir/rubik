# frozen_string_literal: true

require_relative "../test_helper"

# Pins for the Narration render seam (architecture review 2026-10-08,
# Candidate 1 + the action-vocabulary commit): instance state narration is
# DERIVED from lifecycle state (never stored, so it cannot go stale — the
# session-review B3/B4 bug class), and the manage_subagents action
# vocabulary (schema enum, help list, dispatch keys, error text) is
# projected from ONE frozen table.
class TestSubagentNarration < Minitest::Test
  N = Rubik::Orchestrator::Subagent::Narration

  def test_state_note_is_derived_from_lifecycle_state_not_stored
    assert_equal "Paused awaiting budget expansion from the maestro.", N.state_note(:waiting_budget)
    assert_equal "Paused awaiting error recovery: Errno::ECONNRESET: boom",
                 N.state_note(:paused_error, last_error: "Errno::ECONNRESET: boom")
    assert_equal "Asked the maestro a clarifying question; blocked awaiting the answer.", N.state_note(:waiting_input)

    assert_nil N.state_note(:running), "a live run needs no invented prose"
    assert_nil N.state_note(:pending)
    assert_nil N.state_note(:completed), "a completed run narrates via its real result"
    assert_nil N.state_note(:canceling)
    assert_nil N.state_note(:disposed)
  end

  def test_halt_note_distinguishes_no_grant_from_no_further_grant
    plain = N.state_note(:budget_exhausted, max_steps: 2)
    assert_includes plain, "Subagent reached step budget (2 steps) and halted: task was NOT completed. " \
                           "Inspect transcript or spawn a new subagent."
    assert_includes plain, "Budget expansion was not received from the maestro.",
                    "first exhaustion keeps the plain not-received wording (B4)"

    granted = N.state_note(:budget_exhausted, grants_received: 3, max_steps: 2, paused_after_s: 0.05)
    assert_includes granted, "No further budget expansion arrived"
    assert_includes granted, "within 0.05s (3 grant(s) were received and consumed earlier)",
                    "a consumed grant must not read as a lost one (B4)"
  end

  def test_failed_note_requires_the_recorded_pause_fact
    assert_nil N.state_note(:failed, last_error: "boom"),
               "a plain failure narrates via last_error — no invented halt wording"
    assert_equal "Subagent halted after 0.05s in paused_error state: boom",
                 N.state_note(:failed, last_error: "boom", paused_after_s: 0.05)
  end

  def test_completed_stub_line_keeps_the_nil_provider_wording
    assert_equal "Subagent [subagent-3] (Scout) completed task successfully: look around",
                 N.completed_stub_line("subagent-3", "Scout", "look around")
  end

  def test_running_guidance_names_the_poll_discipline_and_wait_hint
    guidance = N.guidance(:running, id: "subagent-1", max_steps: 10, step: 3, uptime: 1.24)
    assert_includes guidance, "Subagent is actively working (step 3/10, 1.2s uptime)."
    assert_includes guidance, "DO NOT poll 'status' in a loop!"
    assert_includes guidance, "manage_subagents(action: 'wait', timeout: 30)"
  end

  # ---- manage_subagents action vocabulary: one table, many projections ----

  def test_manage_subagents_schema_enum_equals_narration_projection
    enum = Rubik::Tools::ManageSubagentsTool::DECLARATION.params_schema.dig(:properties, :action, :enum)
    assert_equal N::SCHEMA_ACTIONS, enum, "the schema enum is a projection of ACTION_SPECS"
    assert_equal ["list", "status", "wait", "transcript", "result", "extend_budget", "resume", "redeploy", "reap", "kill", "kill_all"],
                 N::CANONICAL_NAMES, "canonical order is the description's historical order (TOOLS.md stays byte-identical)"
  end

  def test_tool_description_lists_every_canonical_action
    description = Rubik::Tools::ManageSubagentsTool::DECLARATION.description
    N::CANONICAL_NAMES.each { |action| assert_includes description, "'#{action}'" }
  end

  def test_killall_alias_is_in_schema_and_dispatchable
    assert_includes N::SCHEMA_ACTIONS, "killall", "the live enum↔dispatch drift regression pin"
    sup = Object.new
    sup.define_singleton_method(:kill_all) { true }
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)

    res = tool.execute("action" => "killall")

    assert_equal "All active subagents have been terminated.", res
  end

  def test_unknown_action_error_names_every_canonical_action
    sup = Object.new
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)

    err = tool.execute("action" => "teleport")

    assert err.error?
    assert_includes err.to_s, "Unknown manage_subagents action: 'teleport'"
    N::CANONICAL_NAMES.each { |action| assert_includes err.to_s, action }
  end

  def test_canonical_action_resolves_aliases_and_rejects_unknown
    assert_equal "extend_budget", N.canonical_action("grant_steps")
    assert_equal "extend_budget", N.canonical_action("  EXTEND ")
    assert_equal "resume", N.canonical_action("retry")
    assert_equal "reap", N.canonical_action("clean")
    assert_equal "kill_all", N.canonical_action("killall")
    assert_equal "kill_all", N.canonical_action("kill_all")
    assert_nil N.canonical_action("teleport")
  end

  def test_notices_hint_actions_are_canonical
    hints = [
      Rubik::Orchestrator::Subagent::Notices.wait_hint("subagent-1"),
      Rubik::Orchestrator::Subagent::Notices.wait_any_hint,
      Rubik::Orchestrator::Subagent::Notices.wait_hint_template,
      Rubik::Orchestrator::Subagent::Notices.extend_budget_hint("subagent-1"),
      Rubik::Orchestrator::Subagent::Notices.resume_hint("subagent-1")
    ]
    hints.each do |hint|
      match = hint.match(/action: '(\w+)'/)
      assert match, "hint must name an action: #{hint}"
      assert_includes N::CANONICAL_NAMES, match[1], "hint action '#{match[1]}' must be canonical"
    end
  end
end
