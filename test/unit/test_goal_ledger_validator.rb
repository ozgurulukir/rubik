# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/orchestrator/goal_ledger"

# Taxonomy kalbi: :conflict (stale rev — %68 premature overwrite), bütün-
# doküman rewrite reddi, null-means-delete reddi, çoklu-reason teşhis ve
# atomiklik (ret → current doc byte-identical). Fabrikalar GERÇEK wire
# şeklini pinler (JSON.generate); doğrulama beklentileri üretim şeması
# örneği (Schema.goal_skeleton) üzerinden kurulur.
class TestGoalLedgerValidator < Minitest::Test
  GL = Rubik::Orchestrator::GoalLedger

  def base_doc(rev: 7)
    {
      "rev" => rev,
      "objective" => "Ship the ledger seam",
      "tasks" => [
        { "id" => "t1", "title" => "Design", "status" => "done", "notes" => nil, "verify" => nil },
        { "id" => "t2", "title" => "Implement", "status" => "doing", "notes" => nil, "verify" => nil },
        { "id" => "t3", "title" => "Test", "status" => "todo", "notes" => nil, "verify" => nil },
        { "id" => "t4", "title" => "Review", "status" => "todo", "notes" => nil, "verify" => nil }
      ],
      "findings" => [{ "id" => "f1", "text" => "seam is pure", "source_step" => 3 }],
      "decisions" => [{ "id" => "d1", "text" => "use an RFC 6902 subset", "rationale" => "small models" }],
      "open_questions" => ["which provider?"],
      "environment_notes" => []
    }
  end

  def patch_json(ops:, rev: 7)
    JSON.generate({ "rev" => rev, "ops" => ops })
  end

  def validate(ops, rev: 7, doc: base_doc)
    GL::Validator.validate(patch_json(rev: rev, ops: ops), schema: GL::Schema.goal_skeleton, current_doc: doc)
  end

  # ---- happy path ----

  def test_appending_a_task_via_tasks_dash_yields_the_incremented_rev_and_a_frozen_document
    verdict = validate([{ "op" => "add", "path" => "/tasks/-",
                          "value" => { "id" => "t5", "title" => "Land", "status" => "todo" } }])
    assert_equal :ok, verdict[0]
    doc = verdict[1]
    rev = verdict[2]
    assert_equal 8, rev
    assert_equal doc["rev"], rev
    assert_equal 5, doc["tasks"].size
    assert_equal "t5", doc["tasks"][4]["id"]
    assert_predicate doc, :frozen?
    assert_raises(FrozenError) { doc["objective"] = "tamper" }
    assert_raises(FrozenError) { doc["tasks"][4]["title"] = "tamper" }
  end

  def test_sequential_ops_observe_the_state_of_their_predecessors
    verdict = validate([
                         { "op" => "add", "path" => "/tasks/-", "value" => { "id" => "t5", "title" => "Land", "status" => "todo" } },
                         { "op" => "replace", "path" => "/tasks/4/status", "value" => "doing" }
                       ])
    assert_equal :ok, verdict[0]
    assert_equal "doing", verdict[1]["tasks"][4]["status"], "the second op must see the first op's insert"
  end

  def test_an_add_at_an_existing_index_inserts_per_rfc_6902_semantics
    verdict = validate([{ "op" => "add", "path" => "/open_questions/0", "value" => "first?" }])
    assert_equal :ok, verdict[0]
    assert_equal "first?", verdict[1]["open_questions"][0]
    assert_equal "which provider?", verdict[1]["open_questions"][1]
  end

  # ---- :conflict ----

  def test_a_stale_rev_patch_is_rejected_as_conflict_without_mutating_the_ledger
    doc = base_doc
    verdict = validate([{ "op" => "replace", "path" => "/tasks/2/status", "value" => "done" }], rev: 5, doc: doc)
    reason = verdict[1].first
    assert_equal :rejected, verdict[0]
    assert_equal :conflict, reason[:class]
    assert_includes reason[:message], "5"
    assert_includes reason[:hint], "stale"
    assert_equal 7, doc["rev"], "the ledger is untouched"
    assert_equal "todo", doc["tasks"][2]["status"]
  end

  def test_a_non_integer_ledger_rev_is_a_conflict_not_a_crash
    verdict = GL::Validator.validate(
      patch_json(rev: 7, ops: [{ "op" => "replace", "path" => "/objective", "value" => "x" }]),
      schema: GL::Schema.goal_skeleton, current_doc: { "rev" => nil }
    )
    assert_equal :conflict, verdict[1].first[:class]
  end

  # ---- whole-document / managed guards ----

  def test_a_full_rewrite_attempt_is_rejected_with_a_root_not_replaceable_reason
    doc = base_doc
    verdict = validate([{ "op" => "replace", "path" => "/", "value" => { "rev" => 7 } }], doc: doc)
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:message], "root"
    assert_equal base_doc, doc
  end

  def test_a_pointer_to_the_runtime_managed_rev_is_rejected
    ["add", "replace", "remove"].each do |verb|
      op = { "op" => verb, "path" => "/rev" }
      op["value"] = 9 unless verb == "remove"
      verdict = validate([op])
      reason = verdict[1].first
      assert_equal :schema, reason[:class]
      assert_includes reason[:message], "runtime-managed"
    end
  end

  # ---- null-means-delete ----

  def test_a_null_means_delete_attempt_is_rejected_with_an_item_remove_hint
    verdict = validate([{ "op" => "replace", "path" => "/tasks/2/status", "value" => nil }])
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:hint], "remove on the item (/tasks/2)"
    refute_nil verdict[1].first
  end

  def test_null_is_accepted_on_allow_null_fields
    verdict = validate([{ "op" => "replace", "path" => "/tasks/2/notes", "value" => nil }])
    assert_equal :ok, verdict[0]
    assert_nil verdict[1]["tasks"][2]["notes"]
  end

  # ---- section structure ----

  def test_an_unknown_section_is_rejected_listing_the_known_sections
    verdict = validate([{ "op" => "add", "path" => "/notes/-", "value" => "x" }])
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:hint], "tasks"
    assert_includes reason[:hint], "open_questions"
  end

  def test_replacing_a_whole_section_is_rejected_with_per_item_guidance
    verdict = validate([{ "op" => "replace", "path" => "/tasks", "value" => [] }])
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:message], "wholesale section rewrite"
  end

  def test_removing_a_whole_section_is_rejected_as_structural
    verdict = validate([{ "op" => "remove", "path" => "/tasks" }])
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:message], "structural"
  end

  # ---- indices ----

  def test_an_array_index_out_of_range_is_rejected_as_schema
    verdict = validate([{ "op" => "replace", "path" => "/tasks/9/status", "value" => "done" }])
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:message], "0-3"
    assert_includes reason[:hint], "/tasks/-"
  end

  def test_a_non_numeric_index_is_rejected
    verdict = validate([{ "op" => "replace", "path" => "/tasks/two/status", "value" => "done" }])
    assert_includes verdict[1].first[:message], "item index"
  end

  def test_replacing_into_an_empty_list_is_rejected_while_append_works
    verdict = validate([{ "op" => "replace", "path" => "/environment_notes/0",
                          "value" => { "id" => "e1", "text" => "x" } }])
    assert_equal :schema, verdict[1].first[:class]

    ok = validate([{ "op" => "add", "path" => "/environment_notes/-",
                     "value" => { "id" => "e1", "text" => "fresh env note" } }])
    assert_equal :ok, ok[0]
    assert_equal 1, ok[1]["environment_notes"].size
  end

  # ---- ids ----

  def test_a_duplicate_id_within_a_collection_is_rejected_as_schema
    verdict = validate([{ "op" => "add", "path" => "/tasks/-",
                          "value" => { "id" => "t1", "title" => "Dup", "status" => "todo" } }])
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:message], "duplicate tasks id 't1'"
  end

  # ---- enum / caps / types ----

  def test_an_enum_violation_is_rejected_listing_the_four_statuses
    verdict = validate([{ "op" => "replace", "path" => "/tasks/2/status", "value" => "archived" }])
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:message], "todo, doing, done, blocked"
    assert_includes reason[:message], "archived"
  end

  def test_an_over_cap_string_is_rejected_with_the_cap_echoed
    verdict = validate([{ "op" => "replace", "path" => "/objective", "value" => "x" * 401 }])
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:message], "401"
    assert_includes reason[:message], "400"
  end

  def test_a_wrong_type_is_rejected_with_json_type_names
    verdict = validate([{ "op" => "replace", "path" => "/objective", "value" => 42 }])
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:message], "expected string, got integer"
  end

  def test_a_float_where_an_integer_is_expected_is_rejected
    verdict = validate([{ "op" => "add", "path" => "/findings/-",
                          "value" => { "id" => "f2", "text" => "x", "source_step" => 3.5 } }])
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:message], "float"
  end

  # ---- item objects ----

  def test_a_whole_item_add_missing_a_required_field_is_rejected
    verdict = validate([{ "op" => "add", "path" => "/tasks/-", "value" => { "id" => "t9", "title" => "No status" } }])
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:message], "missing required field(s) status"
  end

  def test_a_whole_item_replace_with_a_partial_object_is_rejected
    verdict = validate([{ "op" => "replace", "path" => "/tasks/2", "value" => { "id" => "t3" } }])
    assert_equal :schema, verdict[1].first[:class]
    assert_includes verdict[1].first[:message], "missing required field(s)"
  end

  def test_an_item_with_an_unknown_field_is_rejected_listing_allowed_fields
    verdict = validate([{ "op" => "add", "path" => "/tasks/-",
                          "value" => { "id" => "t9", "title" => "x", "status" => "todo", "priority" => 1 } }])
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:message], "priority"
    assert_includes reason[:hint], "allowed fields"
  end

  def test_a_non_object_item_value_is_rejected_with_the_direct_field_hint
    verdict = validate([{ "op" => "replace", "path" => "/tasks/2", "value" => "done" }])
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:hint], "/tasks/2/status"
  end

  # ---- fields ----

  def test_removing_a_field_is_rejected_with_null_allowed_guidance
    verdict = validate([{ "op" => "remove", "path" => "/tasks/2/notes" }])
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:message], "fields are not removable"
    assert_includes reason[:hint], "notes, verify"
    assert_includes reason[:hint], "/tasks/2"
  end

  def test_an_unknown_field_is_rejected_listing_the_allowed_fields
    verdict = validate([{ "op" => "replace", "path" => "/tasks/2/priority", "value" => 1 }])
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:message], "unknown field 'priority'"
  end

  def test_replacing_the_id_field_with_a_duplicate_is_caught
    verdict = validate([{ "op" => "replace", "path" => "/tasks/2/id", "value" => "t1" }])
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:message], "duplicate tasks id 't1'"
  end

  # ---- root scalars ----

  def test_the_objective_is_replaceable_but_not_removable
    ok = validate([{ "op" => "replace", "path" => "/objective", "value" => "New objective" }])
    assert_equal :ok, ok[0]
    assert_equal "New objective", ok[1]["objective"]

    gone = validate([{ "op" => "remove", "path" => "/objective" }])
    reason = gone[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:message], "required"
    assert_includes reason[:hint], "replace"
  end

  # ---- open_questions (skalar liste) ----

  def test_open_questions_append_replace_and_remove_enforce_the_string_shape
    ok = validate([
                    { "op" => "add", "path" => "/open_questions/-", "value" => "second?" },
                    { "op" => "replace", "path" => "/open_questions/0", "value" => "first, revised?" },
                    { "op" => "add", "path" => "/open_questions/0", "value" => "newest?" }
                  ])
    assert_equal :ok, ok[0]
    assert_equal ["newest?", "first, revised?", "second?"], ok[1]["open_questions"], "replace removed 'which provider?' before the head insert"

    bye = validate([{ "op" => "remove", "path" => "/open_questions/0" }])
    assert_equal :ok, bye[0]
    assert_equal 0, bye[1]["open_questions"].size

    bad = validate([{ "op" => "add", "path" => "/open_questions/-", "value" => 42 }])
    assert_includes bad[1].first[:message], "expected string, got integer"
  end

  def test_open_questions_dash_on_replace_is_rejected
    verdict = validate([{ "op" => "replace", "path" => "/open_questions/-", "value" => "x" }])
    assert_includes verdict[1].first[:message], "append"
    assert_includes verdict[1].first[:hint], "appends"
  end

  def test_deep_paths_beyond_fields_are_rejected
    verdict = validate([{ "op" => "replace", "path" => "/tasks/2/status/extra", "value" => "done" }])
    assert_includes verdict[1].first[:message], "deeper"
  end

  # ---- multi-error + atomiklik ----

  def test_a_multi_error_patch_reports_every_offending_op_in_one_verdict
    verdict = validate([
                         { "op" => "replace", "path" => "/tasks/2/status", "value" => "archived" },
                         { "op" => "add", "path" => "/open_questions/-", "value" => 42 },
                         { "op" => "replace", "path" => "/tasks/9/status", "value" => "done" }
                       ])
    assert_equal :rejected, verdict[0]
    assert_equal 3, verdict[1].size, "no fail-fast: every offending op is diagnosed in one round"
  end

  def test_a_rejected_patch_leaves_the_current_document_byte_identical
    doc = base_doc
    before = Marshal.dump(doc)
    validate([
               { "op" => "replace", "path" => "/tasks/0/status", "value" => "doing" },
               { "op" => "remove", "path" => "/tasks/1" }
             ], doc: doc)
    assert_equal before, Marshal.dump(doc), "atomicity: a rejected patch must not leak any applied op"
  end

  def test_an_accepted_result_increments_rev_by_exactly_one
    verdict = validate([{ "op" => "replace", "path" => "/objective", "value" => "v2" }])
    assert_equal 8, verdict[2]
    assert_equal 8, verdict[1]["rev"]
  end

  def test_validate_never_raises_on_garbage_payloads
    doc = base_doc
    [nil, 42, "not json", "{\"rev\": 7}"].each do |garbage|
      verdict = GL::Validator.validate(garbage, schema: GL::Schema.goal_skeleton, current_doc: doc)
      assert_equal :rejected, verdict[0]
    end
  end

  def test_a_non_schema_argument_is_the_one_programmer_error
    doc = base_doc
    assert_raises(ArgumentError) do
      GL::Validator.validate(patch_json(ops: []), schema: { "not" => "a schema" }, current_doc: doc)
    end
  end

  def test_patch_objects_skip_reparse
    verdict = GL::Patch.parse(patch_json(rev: 7, ops: [{ "op" => "replace", "path" => "/objective", "value" => "via vo" }]))
    assert_equal :ok, verdict[0]
    out = GL::Validator.validate(verdict[1], schema: GL::Schema.goal_skeleton, current_doc: base_doc)
    assert_equal :ok, out[0]
    assert_equal "via vo", out[1]["objective"]
  end
end
