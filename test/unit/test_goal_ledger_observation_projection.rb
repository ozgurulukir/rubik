# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/orchestrator/goal_ledger"

# Plan D gözlem projeksiyonu: banked tool satırlarının rev-pinned
# tombstone'a emilmesi. Garanti seti: son K tur raw, pin muafiyetleri,
# satır düşme YOK (pairing güvenliği), kayıt dokunulmazlığı, knob
# matrisinde OFF-kimliği ve sessizlik (:ledger_absorb_drop + dmesg).
class TestGoalLedgerObservationProjection < Minitest::Test
  GL = Rubik::Orchestrator::GoalLedger

  def setup
    @events = []
  end

  attr_reader :events

  def tool_row(name, content = "x" * 400, status: :ok)
    { role: "tool", tool_call_id: "c_#{rand(100_000)}", tool_name: name, status: status,
      duration_ms: 3, content: content }
  end

  def ledger_row(status: :ok)
    tool_row(GL::ObservationProjection::MODULE_NAME, "<goal_ledger_applied rev=\"1\" />", status: status)
  end

  def deps(goal_mode: true, config: {}, ledger: nil, dmesg: nil)
    deps = Object.new
    ctx = Object.new
    store = { Rubik::Coeffects::GOAL_LEDGER => ledger, Rubik::Coeffects::DMESG => dmesg }
    ctx.define_singleton_method(:get) { |key| store[key] }
    mgr = Object.new
    mgr.define_singleton_method(:context) { ctx }
    deps.define_singleton_method(:goal_mode?) { goal_mode }
    deps.define_singleton_method(:config) { config }
    deps.define_singleton_method(:runtime_manager) { mgr }
    steps = { step: 4, max: 20 }
    deps.define_singleton_method(:step_count) { steps[:step] }
    deps.define_singleton_method(:max_steps) { steps[:max] }
    events = @events
    handler = ->(**event) { events << event }
    deps.define_singleton_method(:on_step) { handler }
    deps
  end

  def ledger(rev: 7)
    led = Object.new
    led.define_singleton_method(:rev) { rev }
    led
  end

  def directive(dps, window: 5, rev: 7)
    GL::ObservationProjection::Directive.new(ledger: ledger(rev: rev), window: window, deps: dps)
  end

  def history_with_old_observations(older: 6)
    rows = []
    older.times { |i| rows << tool_row("read_file", "old observation #{i}: #{'y' * 300}") }
    rows << { role: "assistant", content: "reading ledger" }
    rows << ledger_row
    3.times { |i| rows << tool_row("grep_search", "recent #{i}: #{'z' * 300}") }
    rows
  end

  # ---- absorption ----

  def test_absorbs_a_banked_tool_result_older_than_the_observe_window
    rows = history_with_old_observations
    out = directive(deps).apply!(rows)
    assert_equal 6, out[:count]
    assert_equal 7, out[:rev]
    assert_operator out[:reclaimed_tokens], :>, 0
    assert_includes rows.first[:content], '<absorbed_into_ledger rev="7" tool="read_file" />'
  end

  def test_keeps_the_last_k_assistant_turns_and_everything_after_the_anchor_raw
    rows = history_with_old_observations
    directive(deps, window: 2).apply!(rows)
    raw_after = rows.last(4)
    assert raw_after.all? { |r| !r[:content].to_s.start_with?("<absorbed_into_ledger") },
           "anchor + everything after it stays raw"
  end

  def test_never_tombstones_the_update_goal_ledger_rows_themselves
    rows = history_with_old_observations(older: 1)
    directive(deps).apply!(rows)
    ledger_idx = rows.index { |r| r[:tool_name] == GL::ObservationProjection::MODULE_NAME }
    assert_includes rows[ledger_idx][:content], "<goal_ledger_applied", "the Σ audit trail stays raw"
  end

  def test_never_tombstones_skill_bodies_or_error_rows
    rows = [tool_row("skill", "SKILL.md body"), tool_row("read_file", "boom", status: :error),
            { role: "assistant", content: "a" }, ledger_row]
    out = directive(deps, window: 1).apply!(rows)
    assert_equal 0, out[:count]
  end

  def test_never_tombstones_rows_inside_a_goal_pinned_unit
    rows = [{ role: "user", content: "<user_task>\nGoal\n</user_task>" },
            { role: "assistant", content: "<user_task>\nGoal\n</user_task>",
              tool_calls: [{ "tool" => "read_file", "args" => { "path" => "x" } }] },
            tool_row("read_file", "goal-scoped read"),
            { role: "assistant", content: "a" }, ledger_row]
    out = directive(deps, window: 1).apply!(rows)
    goal_rows = rows.select { |r| r[:content].to_s.include?("<user_task>") }
    assert goal_rows.all? { |r| !r[:content].to_s.start_with?("<absorbed_into_ledger") },
           "the pinned goal rows are never candidates — unit_pins_goal? shields any unit they join"
    assert_operator out[:count], :<=, 1
  end

  def test_skips_rows_already_carrying_a_tombstone
    rows = [tool_row("read_file", '<absorbed_into_ledger rev="6" tool="read_file" />'),
            { role: "assistant", content: "a" }, ledger_row]
    out = directive(deps).apply!(rows)
    assert_equal 0, out[:count], "idempotence across compactions"
  end

  def test_anchor_missing_degrades_to_a_noop_without_raising
    rows = [tool_row("read_file", "no ledger call anywhere")]
    out = directive(deps).apply!(rows)
    assert_equal 0, out[:count]
  end

  def test_never_mutates_the_original_history_rows
    rows = history_with_old_observations
    snapshot = JSON.generate(rows)
    copied = JSON.parse(snapshot)
    directive(deps).apply!(copied)
    assert_equal snapshot, JSON.generate(rows), "record intactness: tombstones land only on the compaction copy"
  end

  def test_tombstones_string_keyed_rows_on_their_existing_dialect
    rows = [{ "role" => "tool", "tool_call_id" => "c1", "tool_name" => "read_file", "status" => "ok", "content" => "old" }]
    rows << { "role" => "assistant", "content" => "a" } << ledger_row
    directive(deps, window: 1).apply!(rows)
    assert_includes rows[0]["content"], "<absorbed_into_ledger"
    assert_equal "c1", rows[0]["tool_call_id"], "pairing keys are preserved bit-for-bit"
  end

  # ---- directive matrix ----

  def test_returns_nil_directive_outside_a_goal_loop
    assert_nil GL::ObservationProjection.directive_for(deps: deps(goal_mode: false))
  end

  def test_returns_nil_directive_when_the_ledger_knob_matrix_fails
    assert_nil GL::ObservationProjection.directive_for(deps: deps(config: { "goal" => { "ledger" => { "enabled" => false } } }))
    assert_nil GL::ObservationProjection.directive_for(deps: deps(config: { "goal" => { "ledger" => { "observe_projection" => false } } }))
    assert_nil GL::ObservationProjection.directive_for(deps: deps(ledger: nil))
    assert_nil GL::ObservationProjection.directive_for(deps: deps(ledger: ledger(rev: 0))), "rev 0: no accepted patch yet"
  end

  def test_warns_via_dmesg_when_projection_is_on_but_the_ledger_is_disabled
    dmesg_lines = []
    dm = Object.new
    dm.define_singleton_method(:log) { |*args| dmesg_lines << args }
    GL::ObservationProjection.directive_for(
      deps: deps(config: { "goal" => { "ledger" => { "enabled" => false, "observe_projection" => true } } }, dmesg: dm)
    )
    assert(dmesg_lines.any? { |(_, level, msg)| level == :warn && msg.include?("inert") })
  end

  # ---- observability ----

  def test_emits_one_ledger_absorb_drop_event_and_a_dmesg_record
    dmesg_lines = []
    dm = Object.new
    dm.define_singleton_method(:log) { |*args| dmesg_lines << args }
    dps = deps(dmesg: dm)
    out = directive(dps).apply!(history_with_old_observations)
    assert_equal 6, out[:count]
    event = events.first
    assert_equal :ledger_absorb_drop, event[:type]
    assert_equal 6, event[:count]
    assert_equal 7, event[:rev]
    assert_operator event[:reclaimed_tokens], :>, 0
    assert(dmesg_lines.any? { |(_, _level, msg)| msg.include?("absorbed 6 observation row(s)") })
  end

  def test_emits_nothing_when_nothing_was_absorbed
    directive(deps).apply!([{ role: "assistant", content: "a" }, ledger_row])
    assert_empty events
  end

  # ---- compaction seam ordering ----

  def test_compact_history_absorb_tier_runs_before_generic_tiers_and_can_satisfy_alone
    rows = Array.new(24) { |i| tool_row("read_file", "old observation #{i}: #{'y' * 2000}") }
    rows << { role: "assistant", content: "reading ledger" } << ledger_row
    3.times { |i| rows << tool_row("grep_search", "recent #{i}: #{'z' * 300}") }

    absorb = directive(deps)
    out = Rubik::Prompt::ContextCompactor.compact_history(
      Marshal.load(Marshal.dump(rows)), context_limit: 8192, max_output_tokens: 512,
                                        config: { "compaction_strategy" => "sliding_window" }, absorb: absorb
    )
    tombstones = out.count { |r| r[:content].to_s.start_with?("<absorbed_into_ledger") }
    assert_operator tombstones, :>=, 20, "absorption alone satisfied the budget — generic drop never ran"
    assert out.any? { |r| r[:content].to_s.include?("recent") }, "recent observations stay raw"

    nil_run = Rubik::Prompt::ContextCompactor.compact_history(
      rows, context_limit: 8192, max_output_tokens: 512,
            config: { "compaction_strategy" => "sliding_window" }
    )
    assert_empty nil_run.grep(/absorbed_into_ledger/), "nil absorb stays byte-identical (OFF identity)"
  end

  def test_emergency_compact_forwards_absorb_to_the_structural_layer
    history = history_with_old_observations(older: 3)
    Rubik::Prompt::EmergencyCompactor.compact!(history, context_limit: 4096, max_output_tokens: 512,
                                                        config: {}, absorb: directive(deps, window: 2))
    assert(history.any? { |r| r[:content].to_s.start_with?("<absorbed_into_ledger") })
  end
end
