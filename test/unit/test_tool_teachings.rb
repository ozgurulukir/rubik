# frozen_string_literal: true

require_relative "../test_helper"

# Teachings-registry invariants (architecture review 2026-10-01, candidate 1):
# prompt prose keyed by canonical tool name must stay weldable to the tool
# declarations — a tool rename that forgets the prompt fails here, and the
# buffer-persistence teaching stays present in the operational rules.
class TestToolTeachings < Minitest::Test
  def test_every_teaching_key_resolves_to_a_declared_or_sanctioned_dynamic_tool
    declared = Rubik::Tools::Catalog.names +
               Rubik::Tools::Catalog.dynamic_declarations.map(&:name)
    Rubik::Prompt::ToolTeachings::TEACHINGS.each_key do |key|
      assert_includes declared, key,
                      "teaching key '#{key}' matches no declared tool — the prose and the tool drifted apart"
    end
  end

  def test_operational_rules_carry_the_buffer_persistence_teaching
    rules = Rubik::Prompt::Doctrine.operational_rules_xml
    # Every teaching (not a sample) must render into the rules — a typo'd
    # interpolation key would silently interpolate "" and lose prose.
    Rubik::Prompt::ToolTeachings::TEACHINGS.each_value do |teaching|
      assert_includes rules, teaching, "teaching '#{teaching[0, 40]}...' must render into the operational rules"
    end
  end

  # Vakanüvis işbirliği döngüsü (plan 2026-10-04 §4.7): öğreti yüzeyi üç
  # sözleşmeyi de taşımalı — K5r2 giriş recall (compaction sonrası dahil),
  # K8 subagent brifingi, K9 görev-sonu record + tek-yol memory disiplini.
  def test_chronicler_cooperation_loop_is_taught_across_the_prompt_surface
    teaching = Rubik::Prompt::ToolTeachings.teaching_for("vakanuvis")
    refute_nil teaching
    assert_includes teaching, "At task start", "K5r2: recall at task start"
    assert_includes teaching, "compaction", "K5r2: recall again after compaction"
    assert_includes teaching, "task brief", "K8: paste the digest/link into the subagent brief"
    assert_includes teaching, "end of a task", "K9: record durable knowledge at task end"
    assert_includes teaching, "never through raw storage puts", "K9: memory writes go through record only"

    bullets = Rubik::Prompt::Doctrine.orchestration_guidance_bullets.join("\n")
    assert_includes bullets, "Chronicler briefs", "K8 bullet must render in orchestration guidance"

    goal_header = Rubik::Prompt::Doctrine.role_header(:goal)
    assert_includes goal_header, "vakanuvis(action: 'record'", "goal rule 7 routes memory notes through record"
    assert_includes goal_header, "vakanuvis(action: 'recall'", "goal rule 7 teaches recall re-entry"
    assert_includes goal_header, "when `vakanuvis` is available", "goal rule 7 specifies fallback when vakanuvis is unavailable"
  end

  def test_storage_and_vakanuvis_teachings_agree_on_write_contract
    storage_teaching = Rubik::Prompt::ToolTeachings.teaching_for("storage")
    vakanuvis_teaching = Rubik::Prompt::ToolTeachings.teaching_for("vakanuvis")

    assert_includes storage_teaching, "goals, plans, reviews, and work notes",
                    "storage teaching must frame direct puts around ordinary work artifacts"
    refute_includes storage_teaching, "Persist agent workfiles — goals, plans, memory notes, wiki knowledge, reviews",
                    "storage teaching must not direct raw storage puts for memory notes and wiki knowledge"
    assert_includes storage_teaching, "write durable `memory` cards and compiled `wiki` pages through `vakanuvis` (`record` / `digest`) whenever `vakanuvis` is in your toolbelt",
                    "storage teaching must route durable memory/wiki writes through vakanuvis when available"
    assert_includes storage_teaching, "reserving direct `storage` `put` on `memory`/`wiki` for sessions where `vakanuvis` is unavailable",
                    "storage teaching must define the fallback when vakanuvis is unavailable"
    assert_includes vakanuvis_teaching, "never through raw storage puts when `vakanuvis` is available",
                    "vakanuvis teaching must stay consistent with the storage fallback contract"
  end

  def test_replace_file_content_teaching_uses_schema_advertised_parameter_names
    teaching = Rubik::Prompt::ToolTeachings.teaching_for("replace_file_content")
    schema = Rubik::Tools::ReplaceFileContentTool::DECLARATION.params_schema
    declared_props = schema[:properties].keys.map(&:to_s)
    required_props = schema[:required].map(&:to_s)

    required_props.each do |prop|
      assert_includes teaching, "`#{prop}`",
                      "replace_file_content teaching must name required schema property '#{prop}'"
    end
    refute_includes teaching, "old_content",
                    "teaching must not advertise unindexed alias old_content absent from the schema"
    refute_includes teaching, "new_content",
                    "teaching must not advertise unindexed alias new_content absent from the schema"
    assert_includes declared_props, "target_content"
    assert_includes declared_props, "replacement_content"
  end

  def test_synthesize_tool_teaching_and_schema_explain_params_schema_for_parameterized_and_no_arg_tools
    teaching = Rubik::Prompt::ToolTeachings.teaching_for("synthesize_tool")
    schema = Rubik::Tools::SynthesizeToolTool::DECLARATION.params_schema
    params_schema_desc = schema[:properties][:params_schema][:description]

    assert_includes teaching, "params_schema:",
                    "synthesize_tool teaching example must include params_schema"
    assert_includes teaching, "no arguments",
                    "synthesize_tool teaching must explain when omitting/empty params_schema is appropriate"
    assert_includes params_schema_desc, "accepts arguments"
    assert_includes params_schema_desc, "no arguments"
  end
end
