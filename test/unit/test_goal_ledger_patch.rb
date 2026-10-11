# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/orchestrator/goal_ledger"

GL = Rubik::Orchestrator::GoalLedger

# GL::Patch parse katmanı (SKILL.state patch seam'inin ilk savunma
# hattı): model girdisinde ASLA raise yok — her başarısızlık reason
# verisidir. Küçük-model hata taksonomisinin %12'si (JSON syntax) ve %20'si
# (şema kavrama) bu katmanda sınıflanır; fabrikalar GERÇEK wire şeklini
# pinler (JSON.generate ile string üretir — sembol-key Ruby hash değil).
class TestGoalLedgerPatch < Minitest::Test
  def patch_json(ops:, rev: 7)
    JSON.generate({ "rev" => rev, "ops" => ops })
  end

  def op(verb, path, value: :absent)
    h = { "op" => verb, "path" => path }
    h["value"] = value unless value == :absent
    h
  end

  # ---- well-formed ----

  def test_a_well_formed_patch_parses_with_rev_and_normalized_frozen_ops
    verdict = GL::Patch.parse(patch_json(ops: [
                                           op("replace", "/tasks/2/status", value: "done"),
                                           op("add", "/findings/-", value: { "id" => "f9", "text" => "new", "source_step" => 7 })
                                         ]))
    assert_equal :ok, verdict[0]
    patch = verdict[1]
    assert_equal 7, patch.rev
    assert_equal 2, patch.ops.size
    first = patch.ops[0]
    assert_equal :replace, first[:op]
    assert_equal "/tasks/2/status", first[:path]
    assert_equal ["tasks", "2", "status"], first[:tokens]
    assert_equal "done", first[:value]
    assert_predicate patch, :frozen?
    assert_predicate first, :frozen?
    assert_predicate first[:tokens], :frozen?
    assert_predicate first[:value], :frozen?
  end

  # ---- :syntax ----

  def test_invalid_json_is_rejected_as_syntax_with_a_strict_json_fix_hint
    verdict = GL::Patch.parse("{rev: 7}")
    assert_equal :rejected, verdict[0]
    reason = verdict[1].first
    assert_equal :syntax, reason[:class]
    assert_includes reason[:hint], "strict JSON"
  end

  def test_a_trailing_comma_or_single_quoted_string_is_rejected_as_syntax
    refute_equal :ok, GL::Patch.parse('{"rev": 7, "ops": [ ],}')[0]
    refute_equal :ok, GL::Patch.parse("{'rev': 7, 'ops': []}")[0]
  end

  def test_an_oversized_body_is_rejected_as_syntax_with_the_cap_echoed
    big = patch_json(ops: [op("add", "/findings/-", value: { "text" => "x" * 33_000 })])
    assert_operator big.bytesize, :>, GL::MAX_PATCH_BYTES
    verdict = GL::Patch.parse(big)
    reason = verdict[1].first
    assert_equal :syntax, reason[:class]
    assert_includes reason[:message], GL::MAX_PATCH_BYTES.to_s
  end

  # ---- header schema ----

  def test_a_patch_with_more_than_64_ops_is_rejected_as_schema
    ops = Array.new(GL::MAX_OPS + 1) { |i| op("add", "/open_questions/-", value: "q#{i}") }
    verdict = GL::Patch.parse(patch_json(ops: ops))
    assert_equal :schema, verdict[1].first[:class]
    assert_includes verdict[1].first[:message], GL::MAX_OPS.to_s
  end

  def test_an_empty_ops_array_is_rejected_as_schema
    verdict = GL::Patch.parse(patch_json(ops: []))
    assert_equal :schema, verdict[1].first[:class]
    assert_includes verdict[1].first[:message], "non-empty"
  end

  def test_missing_rev_or_ops_or_unknown_top_level_keys_are_rejected_as_schema
    missing_rev = JSON.generate({ "ops" => [op("add", "/open_questions/-", value: "q")] })
    assert_equal :schema, GL::Patch.parse(missing_rev)[1].first[:class]

    missing_ops = JSON.generate({ "rev" => 7 })
    assert_equal :schema, GL::Patch.parse(missing_ops)[1].first[:class]

    unknown = JSON.generate({ "rev" => 7, "ops" => [op("add", "/open_questions/-", value: "q")], "why" => 1 })
    verdict = GL::Patch.parse(unknown)
    assert_equal :schema, verdict[1].first[:class]
    assert_includes verdict[1].first[:message], "why"
  end

  def test_a_non_integer_rev_is_rejected_as_schema
    { true => "boolean", 3.0 => "float", "7" => "string" }.each do |bad, type|
      body = JSON.generate({ "rev" => bad, "ops" => [op("add", "/open_questions/-", value: "q")] })
      verdict = GL::Patch.parse(body)
      reason = verdict[1].first
      assert_equal :schema, reason[:class]
      assert_includes reason[:message], type
    end
  end

  # ---- op shape ----

  def test_an_unknown_op_verb_is_rejected_listing_the_allowed_vocabulary
    verdict = GL::Patch.parse(patch_json(ops: [op("move", "/tasks/1", value: 2)]))
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:hint], "add, replace, remove"
  end

  def test_a_remove_op_carrying_a_value_is_rejected_with_a_replace_redirect_hint
    verdict = GL::Patch.parse(patch_json(ops: [op("remove", "/tasks/1", value: nil)]))
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:hint], "replace"
  end

  def test_an_add_op_missing_its_value_is_rejected_as_schema
    verdict = GL::Patch.parse(patch_json(ops: [op("add", "/open_questions/-")]))
    assert_equal :schema, verdict[1].first[:class]
    assert_includes verdict[1].first[:message], "missing its value"
  end

  def test_unknown_op_keys_are_rejected_listing_the_allowed_keys
    verdict = GL::Patch.parse(patch_json(ops: [{ "op" => "add", "path" => "/open_questions/-", "value" => "q", "from" => "/x" }]))
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:message], "from"
  end

  def test_a_non_object_op_is_rejected_as_schema
    verdict = GL::Patch.parse(patch_json(ops: ["replace"]))
    assert_equal :schema, verdict[1].first[:class]
  end

  # ---- pointers ----

  def test_a_pointer_without_a_leading_slash_is_rejected
    verdict = GL::Patch.parse(patch_json(ops: [op("add", "open_questions/-", value: "q")]))
    assert_equal :schema, verdict[1].first[:class]
    assert_includes verdict[1].first[:message], "JSON pointer"
  end

  def test_an_invalid_escape_is_rejected
    verdict = GL::Patch.parse(patch_json(ops: [op("add", "/open~2questions/-", value: "q")]))
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:hint], "~0"
  end

  def test_a_hyphen_token_outside_the_final_position_is_rejected
    verdict = GL::Patch.parse(patch_json(ops: [op("replace", "/tasks/-/status", value: "done")]))
    reason = verdict[1].first
    assert_equal :schema, reason[:class]
    assert_includes reason[:message], "append position"
  end

  def test_a_hyphen_on_replace_or_remove_is_rejected_even_in_final_position
    ["replace", "remove"].each do |verb|
      verdict = GL::Patch.parse(patch_json(ops: [op(verb, "/tasks/-", value: "x")].compact))
      assert_equal :schema, verdict[1].first[:class]
    end
  end

  def test_the_whole_root_pointer_is_rejected_at_parse_time
    verdict = GL::Patch.parse(patch_json(ops: [op("replace", "/", value: {})]))
    assert_equal :schema, verdict[1].first[:class]
    assert_includes verdict[1].first[:message], "root"

    empty = GL::Patch.parse(patch_json(ops: [op("replace", "", value: {})]))
    assert_equal :schema, empty[1].first[:class]
  end

  def test_tilde_escapes_unescape_to_their_literal_meaning
    verdict = GL::Patch.parse(patch_json(ops: [op("add", "/open~1questions/-", value: "q")]))
    assert_equal :ok, verdict[0]
    assert_equal ["open/questions", "-"], verdict[1].ops[0][:tokens]
  end

  def test_multi_error_patches_report_every_offending_op
    verdict = GL::Patch.parse(patch_json(ops: [
                                           op("move", "no-slash", value: 1),
                                           op("remove", "/tasks/1", value: nil),
                                           op("add", "/open_questions/-", value: "ok")
                                         ]))
    assert_equal :rejected, verdict[0]
    assert_equal 2, verdict[1].size
    assert_equal 0, verdict[1][0][:op_index]
    assert_equal 1, verdict[1][1][:op_index]
  end

  def test_parse_never_raises_on_garbage_input
    [nil, 42, Object.new, "]]][[[", "\xFF\xFE invalid"].each do |garbage|
      verdict = GL::Patch.parse(garbage)
      assert_equal :rejected, verdict[0]
    end
  end
end
