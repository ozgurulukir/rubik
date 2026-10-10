# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/orchestrator/goal_ledger"

# Plan B doğrulama yüzeyi: spec grammar (kapalı set), tri-state dürüstlük
# (containment kanıtlanamayan her şey unknown — flip YAPMAZ), iç drift
# mutasyonu (rev bump — :conflict drift sinyalidir), sessiz :ledger_drift
# ve DriftNote render'ı. FS testleri gerçek tmpdir workspace üzerindedir.
class TestGoalLedgerVerification < Minitest::Test
  GL = Rubik::Orchestrator::GoalLedger

  def setup
    @root = Dir.mktmpdir("goal-verify")
    @store = Rubik::Storage::Store.new(root: @root, project: "verify-test")
    @bus_events = []
    events = @bus_events
    @bus = Object.new
    @bus.define_singleton_method(:post) { |*args| events << args }
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def ledger(goal_text: "Ship verified", tasks: [], notes: [])
    led = GL::Ledger.create!(goal_text: goal_text, store: @store, dmesg: nil, event_bus: @bus)
    ops = []
    tasks.each do |t|
      value = { "id" => t["id"], "title" => t["id"], "status" => t["status"] }
      value["verify"] = t["verify"] if t["verify"]
      ops << { "op" => "add", "path" => "/tasks/-", "value" => value }
    end
    notes.each do |n|
      value = { "id" => n["id"], "text" => n["text"] }
      value["verify"] = n["verify"] if n["verify"]
      ops << { "op" => "add", "path" => "/environment_notes/-", "value" => value }
    end
    led.update(JSON.generate({ "rev" => 0, "ops" => ops })) unless ops.empty?
    led
  end

  def exists_spec(path)
    { "type" => "file_exists", "path" => path }
  end

  # ---- VerifySpec grammar ----

  def test_verify_spec_accepts_the_closed_predicate_set_and_rejects_unknown_types
    ["file_exists", "file_contains", "marker"].each do |type|
      raw = { "type" => type, "path" => "lib/x.rb" }
      raw["marker"] = "needle" if type == "marker"
      raw["pattern"] = "needle" if type == "file_contains"
      verdict, = GL::VerifySpec.normalize(raw)
      assert_equal :ok, verdict
    end
    verdict, reason = GL::VerifySpec.normalize({ "type" => "http_ok", "path" => "x" })
    assert_equal :invalid, verdict
    assert_includes reason, "unknown verify type"
  end

  def test_verify_spec_requires_workspace_relative_paths_and_rejects_absolute_or_dotdot_escape
    [["/etc/passwd", "workspace-relative"], ["../secrets", "escape"], ["lib/../../x", "escape"]].each do |path, why|
      verdict, reason = GL::VerifySpec.normalize(exists_spec(path))
      assert_equal :invalid, verdict, path
      assert_includes reason, why
    end
    assert_equal :ok, GL::VerifySpec.normalize(exists_spec("lib/deep/x.rb"))[0]
  end

  def test_verify_spec_bounds_path_pattern_and_marker_lengths
    long = "x" * (GL::VerifySpec::PATH_MAX_CHARS + 1)
    assert_equal :invalid, GL::VerifySpec.normalize(exists_spec(long))[0]
    fat = { "type" => "marker", "path" => "a.md", "marker" => "y" * (GL::VerifySpec::NEEDLE_MAX_CHARS + 1) }
    assert_equal :invalid, GL::VerifySpec.normalize(fat)[0]
    assert_equal :invalid, GL::VerifySpec.normalize({ "type" => "marker", "path" => "a.md" })[0]
  end

  def test_marker_is_a_readable_alias_of_file_contains_in_grammar
    _, spec_a = GL::VerifySpec.normalize({ "type" => "file_contains", "path" => "a.rb", "pattern" => "n" })
    _, spec_b = GL::VerifySpec.normalize({ "type" => "marker", "path" => "a.rb", "marker" => "n" })
    assert_equal "n", spec_a[:needle]
    assert_equal "n", spec_b[:needle]
  end

  # ---- tri-state verifier ----

  def test_file_exists_reports_failed_when_workspace_file_is_missing
    led = ledger(tasks: [{ "id" => "t1", "status" => "done", "verify" => exists_spec("lib/gone.rb") }])
    result = GL::Verifier.verify!(led, trigger: :step, root_dir: @root, config: {})
    assert_equal 1, result[:flipped]
    assert_includes led.to_xml, 'status="stale"'
  end

  def test_file_contains_matches_literal_substring_and_never_regex
    File.write(File.join(@root, "routes.rb"), "post /health\n")
    regex_like = { "type" => "marker", "path" => "routes.rb", "marker" => "po.*ealth" }
    led = ledger(notes: [{ "id" => "e1", "text" => "routes", "verify" => regex_like }])
    result = GL::Verifier.verify!(led, trigger: :step, root_dir: @root, config: {})
    assert_equal 1, result[:flipped], "a regex pattern must NOT match its literal being absent"

    literal = { "type" => "marker", "path" => "routes.rb", "marker" => "post /health" }
    led2 = ledger(notes: [{ "id" => "e1", "text" => "routes", "verify" => literal }])
    assert_nil GL::Verifier.verify!(led2, trigger: :step, root_dir: @root, config: {}),
               "a satisfied predicate is silent (ok produces nothing)"
  end

  def test_path_outside_workspace_reports_unknown_never_ok
    escapes = exists_spec("../outside.txt")
    led = ledger(tasks: [{ "id" => "t1", "status" => "done", "verify" => escapes }])
    result = GL::Verifier.verify!(led, trigger: :step, root_dir: @root, config: {})
    assert_equal 0, result[:flipped], "unknown never flips"
    assert_equal 1, result[:unknowns].size
    assert_includes result[:unknowns].first[:reason], "workspace"
  end

  def test_permission_error_reports_unknown_without_flip
    skip "chmod is a no-op on Windows" if Gem.win_platform?
    locked = File.join(@root, "locked.rb")
    File.write(locked, "x")
    File.chmod(0o000, locked)
    led = ledger(tasks: [{ "id" => "t1", "status" => "done",
                           "verify" => { "type" => "marker", "path" => "locked.rb", "marker" => "x" } }])
    result = GL::Verifier.verify!(led, trigger: :step, root_dir: @root, config: {})
    assert_equal 0, result[:flipped]
    assert_equal 1, result[:unknowns].size
  ensure
    File.chmod(0o644, locked) if locked && File.exist?(locked)
  end

  def test_truncated_read_cannot_prove_absence_and_reports_unknown
    big = File.join(@root, "big.log")
    File.write(big, "#{'x' * GL::VerifySpec::READ_CAP_BYTES}NEEDLE")
    spec = { "type" => "marker", "path" => "big.log", "marker" => "NEEDLE" }
    led = ledger(notes: [{ "id" => "e1", "text" => "big", "verify" => spec }])
    result = GL::Verifier.verify!(led, trigger: :step, root_dir: @root, config: {})
    assert_equal 1, result[:unknowns].size, "needle past the cap: absence is unprovable"
    assert_equal 0, result[:flipped]
  end

  def test_spec_overflow_and_malformed_specs_report_unknown
    led = ledger(tasks: [{ "id" => "t1", "status" => "todo", "verify" => { "type" => "file_exists" } }])
    result = GL::Verifier.verify!(led, trigger: :step, root_dir: @root, config: {})
    assert_equal 1, result[:unknowns].size, "malformed spec → unknown, never a crash"
  end

  def test_knob_off_makes_entrypoints_noop_without_touching_the_ledger
    led = ledger(tasks: [{ "id" => "t1", "status" => "done", "verify" => exists_spec("lib/gone.rb") }])
    result = GL::Verifier.verify!(led, trigger: :step, root_dir: @root, config: { "goal" => { "ledger" => { "verify" => false } } })
    assert_nil result
    assert_includes led.to_xml, 'status="done"', "knob off: no flip"
    assert_empty @bus_events
  end

  # ---- drift mutation + persistence + note ----

  def test_failed_task_flips_even_done_to_stale_bumps_rev_and_persists_the_revision
    led = ledger(tasks: [{ "id" => "t1", "status" => "done", "verify" => exists_spec("lib/gone.rb") }])
    led.update(JSON.generate({ "rev" => 1, "ops" => [
                               { "op" => "replace", "path" => "/tasks/0/status", "value" => "done" }
                             ] }))
    rev_before = led.snapshot[:rev]
    GL::Verifier.verify!(led, trigger: :step, root_dir: @root, config: {})

    assert_operator led.snapshot[:rev], :>, rev_before, "internal drift bumps rev (conflict IS the drift signal)"
    row = @store.get(type: "goal", id: led.snapshot[:storage_id])
    assert_equal led.snapshot[:rev], JSON.parse(row["body"])["rev"], "drift persists through the single-writer path"
    assert_equal "stale", JSON.parse(row["body"])["tasks"][0]["status"]
  end

  def test_environment_note_failure_annotates_last_check_without_status_flip
    led = ledger(notes: [{ "id" => "e1", "text" => "note", "verify" => exists_spec("lib/gone.rb") }])
    GL::Verifier.verify!(led, trigger: :step, root_dir: @root, config: {})
    xml = led.to_xml
    assert_includes xml, "environment_notes"
    refute_includes xml, "stale"
  end

  def test_drift_emits_silent_ledger_drift_event_outside_wake_kinds
    led = ledger(tasks: [{ "id" => "t1", "status" => "done", "verify" => exists_spec("lib/gone.rb") }])
    GL::Verifier.verify!(led, trigger: :step, root_dir: @root, config: {})
    refute_empty @bus_events
    event_name, = @bus_events.first
    assert_equal :ledger_drift, event_name
    refute_includes Rubik::REPL::Lifecycle::WAKE_KINDS, :ledger_drift, "silence contract: never a wake"
  end

  def test_drift_note_renders_bounded_and_escapes_xml
    led = ledger(tasks: [{ "id" => "t1", "status" => "done", "verify" => exists_spec("lib/gone <rb>.rb") }])
    GL::Verifier.verify!(led, trigger: :step, root_dir: @root, config: {})
    note = led.send(:render_drift_note)
    refute_nil note
    assert_includes note, "<ledger_drift "
    assert_includes note, "&lt;rb&gt;"
    assert_includes note, "-&gt; stale", "every byte of the note is xml-escaped (-> included)"
  end

  def test_model_can_clear_stale_through_a_normal_delta_patch
    led = ledger(tasks: [{ "id" => "t1", "status" => "done", "verify" => exists_spec("lib/gone.rb") }])
    GL::Verifier.verify!(led, trigger: :step, root_dir: @root, config: {})
    rev = led.snapshot[:rev]
    result = led.update(JSON.generate({ "rev" => rev, "ops" => [
                                        { "op" => "replace", "path" => "/tasks/0/status", "value" => "done" }
                                      ] }))
    assert_equal :applied, result.status, "stale is a regular enum member — the model re-verifies, the harness never heals"
    assert_includes led.to_xml, 'status="done"'
  end

  # ---- reinjection carrier ----

  def test_refresh_carries_the_drift_note_beside_the_sigma_row_once
    led = ledger(tasks: [{ "id" => "t1", "status" => "done", "verify" => exists_spec("lib/gone.rb") }])
    GL::Verifier.verify!(led, trigger: :step, root_dir: @root, config: {})
    history = [{ role: "user", content: "<user_task>\nShip\n</user_task>" }]
    led.refresh_in_history!(history)
    notes = history.select { |m| m[:content].to_s.start_with?("<ledger_drift ") }
    assert_equal 1, notes.size
    assert history.index { |m| m[:content].to_s.start_with?("<goal_ledger ") } <
           history.index { |m| m[:content].to_s.start_with?("<ledger_drift ") }

    led.update(JSON.generate({ "rev" => led.snapshot[:rev], "ops" => [
                               { "op" => "replace", "path" => "/tasks/0/status", "value" => "done" }
                             ] }))
    led.refresh_in_history!(history)
    assert_empty history.select { |m| m[:content].to_s.start_with?("<ledger_drift ") },
                 "an accepted patch clears the one-shot drift note"
  end
end
