# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/orchestrator/goal_ledger"

# Şema Mekanizması testleri: FieldSpec/ItemSpec/SectionSpec/Schema
# VO'larının freeze sözleşmesi ve goal_skeleton örnek örneğinin yapısal
# şekli. Üretim şeması feature planının (A) — burada yalnız mekanizma pinli.
class TestGoalLedgerSchema < Minitest::Test
  GL = Rubik::Orchestrator::GoalLedger

  def test_the_goal_skeleton_declares_the_five_sections_and_two_root_scalars
    schema = GL::Schema.goal_skeleton
    assert_equal ["decisions", "environment_notes", "findings", "open_questions", "tasks"], schema.sections.keys.sort
    assert_equal ["objective", "rev"], schema.root_scalars.keys.sort
    assert_predicate schema.root_scalars["rev"], :managed, "rev is runtime-managed — no patch pointer may write it"
    ["tasks", "findings", "decisions", "environment_notes"].each do |name|
      assert_kind_of GL::ItemSpec, schema.sections[name].item
      assert_equal "id", schema.sections[name].item.id_field
    end
    assert_equal :string, schema.sections["open_questions"].scalar
  end

  def test_schema_value_objects_are_deeply_frozen
    schema = GL::Schema.goal_skeleton
    assert_predicate schema, :frozen?
    assert_raises(FrozenError) { schema.sections["tasks"].item.fields["id"].instance_variable_set(:@type, :integer) }
    assert_raises(FrozenError) { schema.sections["tasks"].item.fields["status"].enum << "archived" }
    assert_raises(FrozenError) { schema.sections["sneaky"] = nil }
    assert_raises(FrozenError) { schema.root_scalars["objective"].instance_variable_set(:@max_len, 9_999) }
  end

  def test_field_specs_carry_metadata_for_plan_bs_verify_fields
    verify = GL::Schema.goal_skeleton.sections["tasks"].item.fields["verify"]
    assert_predicate verify, :optional
    assert_predicate verify, :allow_null
    # Plan B: verify bir VerifySpec OBJESİDİR — validator yalnız şekli
    # (object/null) zorlar; içerik tri-state unknown yolunda değerlenir.
    assert_equal :object, verify.type

    status = GL::Schema.goal_skeleton.sections["tasks"].item.fields["status"]
    assert_equal ["todo", "doing", "done", "blocked", "stale"], status.enum
    assert_equal 200, GL::Schema.goal_skeleton.sections["tasks"].item.fields["title"].max_len
  end

  def test_a_section_cannot_be_both_item_list_and_scalar_list
    assert_raises(ArgumentError) do
      GL::SectionSpec.new(item: GL::ItemSpec.new(fields: {}), scalar: :string)
    end
  end

  def test_custom_schemas_freeze_their_key_names_against_caller_mutation
    keys = { "alpha" => GL::FieldSpec.new(type: :string) }
    sections = { "list" => GL::SectionSpec.new(scalar: :string, max_len: 10) }
    schema = GL::Schema.new(root_scalars: keys, sections: sections)
    keys["beta"] = GL::FieldSpec.new(type: :string)
    refute_includes schema.root_scalars.keys, "beta", "the schema snapshot must not see caller-side key mutation"
  end
end
