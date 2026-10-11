# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/orchestrator/goal_ledger"

# GoalLedger::Ledger facade davranışları (plan A): gerçek Storage::Store +
# tmpdir (owned resource — mock'suz), C Validator sözleşmesi üzerine kurulu
# update döngüsü, ardışık-ret bütçesi, dürüst storage degradasyonu ve
# XML render'ın GoalState mold'u (yokluk boşluk değil).
class TestGoalLedger < Minitest::Test
  GL = Rubik::Orchestrator::GoalLedger

  def setup
    @root = Dir.mktmpdir("goal-ledger-test")
    @store = Rubik::Storage::Store.new(root: @root, project: "ledger-test")
    @dmesg_events = []
    dmesg = Object.new
    dmesg.define_singleton_method(:log) { |*args| @dmesg_events << args }
    @dmesg = dmesg
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def dmesg_collector
    collector = Object.new
    collector.define_singleton_method(:log) { |*args| @dmesg_events << args }
    collector
  end

  def ledger(goal_text: "Fix the payment module", store: @store, dmesg: dmesg_collector)
    GL::Ledger.create!(goal_text: goal_text, store: store, dmesg: dmesg)
  end

  def patch(ops, rev: nil)
    rev ||= ledger_default_rev
    JSON.generate({ "rev" => rev, "ops" => ops })
  end

  def ledger_default_rev
    0
  end

  def add_task_op(id: "t1", status: "todo")
    { "op" => "add", "path" => "/tasks/-",
      "value" => { "id" => id, "title" => "Design retry", "status" => status } }
  end

  # ---- create! ----

  def test_create_seeds_objective_from_the_goal_text_and_persists_revision_zero
    led = ledger(goal_text: "Ship the seam")
    snap = led.snapshot
    assert_equal 0, snap[:rev]
    assert_equal "Ship the seam", snap[:objective]

    row = @store.get(type: "goal", id: snap[:storage_id])
    assert row, "revision zero is appended as a goal row"
    assert_equal "ledger r0: Ship the seam", row["title"]
    assert_includes row["tags"], "goal-ledger"
    body = JSON.parse(row["body"])
    assert_equal "Ship the seam", body["objective"]
    assert_equal 0, body["rev"]
  end

  def test_update_applies_a_valid_patch_atomically_appends_a_revision_row_and_bumps_the_ref
    led = ledger
    result = led.update(JSON.generate({ "rev" => 0, "ops" => [add_task_op] }))
    assert_equal :applied, result.status
    assert_equal 1, result.rev

    row = @store.get(type: "goal", id: led.snapshot[:storage_id])
    assert_equal 1, JSON.parse(row["body"])["rev"]
    ref_id = @store.refs["goal-ledger"]
    assert_equal led.snapshot[:storage_id], ref_id, "the goal-ledger ref always names the latest revision"

    prev = row["links"]["ledger_prev"]
    refute_nil prev, "revision rows chain through ledger_prev"
  end

  # ---- rejection taxonomy ----

  def test_a_stale_rev_patch_is_classified_conflict_and_names_the_current_rev
    led = ledger
    result = led.update(JSON.generate({ "rev" => 5, "ops" => [add_task_op] }))
    assert_equal :rejected, result.status
    assert_equal :conflict, result.reasons.first[:class]
    assert_includes result.reasons.first[:message], "0"
    assert_equal 0, led.snapshot[:rev], "the ledger is untouched"
  end

  def test_a_schema_violating_patch_returns_op_level_model_readable_reasons_without_mutating_state
    led = ledger
    led.update(JSON.generate({ "rev" => 0, "ops" => [add_task_op] }))
    result = led.update(JSON.generate({ "rev" => 1, "ops" => [{ "op" => "replace", "path" => "/tasks/0/status", "value" => "archived" }] }))
    assert_equal :rejected, result.status
    assert_equal :schema, result.reasons.first[:class]
    assert_includes result.reasons.first[:message], "todo, doing, done, blocked"
    assert_equal 1, led.snapshot[:rev], "state unchanged"
    assert_equal "todo", led.to_xml[/<task [^>]*status="([^"]+)"/, 1]
  end

  def test_malformed_json_is_classified_syntax
    led = ledger
    result = led.update("{not json")
    assert_equal :rejected, result.status
    assert_equal :syntax, result.reasons.first[:class]
  end

  # ---- retry budget ----

  def test_consecutive_rejections_exhaust_the_budget_with_an_honest_unchanged_state_error
    led = ledger
    led.update("{bad")
    led.update("{bad")
    result = led.update("{bad")
    assert_equal :exhausted, result.status, "budget 2 → the third consecutive failing call is refused"
    assert_equal 0, result.rev

    ok = led.update(JSON.generate({ "rev" => 0, "ops" => [add_task_op] }))
    assert_equal :applied, ok.status, "a valid patch re-opens the accept path (goal work continues)"
  end

  def test_success_resets_the_rejection_budget
    led = ledger
    led.update("{bad")
    led.update(JSON.generate({ "rev" => 0, "ops" => [add_task_op] }))
    led.update("{bad")
    assert_equal :rejected, led.update("{bad").status, "only CONSECUTIVE rejections count (budget re-armed)"
    assert_equal :exhausted, led.update("{bad").status
  end

  def test_max_patch_retries_knob_is_honored
    led = GL::Ledger.new(goal_text: "x", max_retries: 0, store: @store, dmesg: dmesg_collector)
    result = led.update("{bad")
    assert_equal :exhausted, result.status
  end

  # ---- finalize ----

  def test_finalize_stamps_terminal_status_on_the_latest_row_is_idempotent_and_reports_shape
    led = ledger
    led.update(JSON.generate({ "rev" => 0, "ops" => [add_task_op] }))
    id = led.snapshot[:storage_id]
    out = led.finalize!(:completed)
    assert_equal id, out[:id]
    assert_equal 1, out[:rev]

    row = @store.get(type: "goal", id: id)
    assert_equal "completed", row["status"]
    assert_equal "completed", row["links"]["finish_status"]
    assert_includes row["tags"], "final"

    led.finalize!(:failed)
    assert_equal "completed", @store.get(type: "goal", id: id)["status"], "finalize is idempotent"
  end

  # ---- degradation ----

  def test_degrades_honestly_without_a_store_in_memory_ledger_still_updates
    events = []
    collector = Object.new
    collector.define_singleton_method(:log) { |*args| events << args }
    led = ledger(store: nil, dmesg: collector)
    result = led.update(JSON.generate({ "rev" => 0, "ops" => [add_task_op] }))
    assert_equal :applied, result.status
    assert_nil result.uri, "no store → no storage uri (honest degradation)"
    assert_equal 1, led.snapshot[:rev]
    assert events.any? { |(_, _, msg)| msg.include?("memory") }, "degradation is visible in dmesg, never swallowed"
  end

  # ---- XML ----

  def test_to_xml_escapes_text_and_omits_empty_collections_and_unset_attributes
    bare = ledger(store: nil, dmesg: dmesg_collector)
    bare_xml = bare.to_xml
    refute_includes bare_xml, "storage_id=", "no store → no storage attribute (honest absence)"
    refute_includes bare_xml, "<tasks>"

    led = ledger(goal_text: 'Fix < "payments" & retries')
    xml = led.to_xml
    assert_includes xml, "Fix &lt; &quot;payments&quot; &amp; retries"

    led.update(JSON.generate({ "rev" => 0, "ops" => [
                               add_task_op(id: "t1", status: "doing"),
                               { "op" => "add", "path" => "/findings/-", "value" => { "id" => "f1", "text" => "retry not < idempotent", "source_step" => 3 } },
                               { "op" => "add", "path" => "/decisions/-", "value" => { "id" => "d1", "text" => "route via PaymentIntent", "rationale" => "keys exist" } },
                               { "op" => "add", "path" => "/open_questions/-", "value" => "sandbox reset?" },
                               { "op" => "add", "path" => "/tasks/0/notes", "value" => "use existing gateway" }
                             ] }))
    xml = led.to_xml
    assert_includes xml, '<task id="t1" status="doing">Design retry — notes: use existing gateway</task>'
    assert_includes xml, '<finding id="f1" source_step="3">retry not &lt; idempotent</finding>'
    assert_includes xml, '<decision id="d1" rationale="keys exist">route via PaymentIntent</decision>'
    assert_includes xml, "<question>sandbox reset?</question>"
    refute_includes xml, "<environment_notes>"
  end

  # ---- history refresh ----

  def test_refresh_keeps_exactly_one_current_row_after_the_goal_row
    led = ledger
    history = [
      { role: "system", content: "sys" },
      { role: "user", content: "<user_task>\nShip it\n</user_task>" },
      { role: "assistant", content: "working" }
    ]
    led.refresh_in_history!(history)
    assert_equal(1, history.count { |m| m[:content].to_s.start_with?("<goal_ledger ") })
    goal_idx = history.index { |m| m[:content].to_s.include?("<user_task>") }
    assert_equal(goal_idx + 1, history.index { |m| m[:content].to_s.start_with?("<goal_ledger ") })

    led.update(JSON.generate({ "rev" => 0, "ops" => [add_task_op] }))
    led.refresh_in_history!(history)
    rows = history.select { |m| m[:content].to_s.start_with?("<goal_ledger ") }
    assert_equal 1, rows.size, "refresh never stacks — the single-Σ-row invariant"
    assert_includes rows.first[:content], 'rev="1"'
  end

  # ---- concurrency ----

  def test_concurrent_reads_during_a_turn_thread_write_never_crash
    led = ledger
    stop = false
    reader = Thread.new do
      led.to_xml until stop
    end
    20.times { |i| led.update(JSON.generate({ "rev" => i, "ops" => [add_task_op(id: "t#{i}")] })) }
    stop = true
    reader.join
    assert_equal 20, led.snapshot[:rev]
  end

  # ---- knob helpers ----

  def test_knob_helpers_resolve_both_config_dialects
    assert GL::Ledger.enabled?(nil), "key-absent = ON"
    assert GL::Ledger.enabled?({})
    refute GL::Ledger.enabled?({ "goal" => { "ledger" => { "enabled" => false } } })
    assert_equal 2, GL::Ledger.max_patch_retries(nil)
    assert_equal 5, GL::Ledger.max_patch_retries({ "goal" => { "ledger" => { "max_patch_retries" => 5 } } })
  end
end
