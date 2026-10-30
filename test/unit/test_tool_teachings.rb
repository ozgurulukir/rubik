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

  # Vakanüvis işbirliği döngüsü (plan 2026-10-04 §4.7, issue #339 iki görev doktrini):
  # öğreti yüzeyi iki temel görevi taşır — K5r2 giriş recall, K8 subagent brifingi,
  # K9 görev-sonu record + tek-yol memory disiplini. Modelin algılayamadığı compaction/
  # session-close ritüelleri doktrinden arındırılmıştır.
  def test_chronicler_cooperation_loop_is_taught_across_the_prompt_surface
    teaching = Rubik::Prompt::ToolTeachings.teaching_for("vakanuvis")
    refute_nil teaching
    assert_includes teaching, "At task start", "K5r2: recall at task start"
    refute_includes teaching, "compaction", "compaction ritual removed from prompt doctrine"
    refute_includes teaching, "session close", "session close ritual removed from prompt doctrine"
    assert_includes teaching, "task brief", "K8: paste the digest/link into the subagent brief"
    assert_includes teaching, "end of a task", "K9: record durable knowledge at task end"
    assert_includes teaching, "never through raw storage puts", "K9: memory writes go through record only"

    # Doktrin yalnız iki eylem öğretir (recall ve record)
    assert_includes teaching, "vakanuvis(action: 'recall'"
    assert_includes teaching, "vakanuvis(action: 'record'"
    refute_includes teaching, "action: 'digest'"
    refute_includes teaching, "action: 'forget'"
    refute_includes teaching, "action: 'topics'"
    refute_includes teaching, "action: 'digest_status'"

    # Recall sorgusuna Keywords satırı ekleten çelişki yok
    recall_section = teaching[/(?<=At task start).*?(?=At the end of a task)/m]
    refute_includes recall_section, "Keywords:"
    assert_includes teaching, "use 2-3 core terms"

    bullets = Rubik::Prompt::Doctrine.orchestration_guidance_bullets.join("\n")
    assert_includes bullets, "Chronicler briefs", "K8 bullet must render in orchestration guidance"

    goal_header = Rubik::Prompt::Doctrine.role_header(:goal)
    assert_includes goal_header, "vakanuvis", "goal rule 7 routes memory notes through vakanuvis"
    assert_includes goal_header, "record/recall", "goal rule 7 references chronicler record/recall"
    assert_includes goal_header, "never through raw storage puts", "goal rule 7 specifies no raw storage puts when vakanuvis is active"
  end

  def test_storage_and_vakanuvis_teachings_agree_on_write_contract
    storage_active = Rubik::Prompt::ToolTeachings.teaching_for("storage", vakanuvis_active: true)
    storage_fallback = Rubik::Prompt::ToolTeachings.teaching_for("storage", vakanuvis_active: false)
    vakanuvis_teaching = Rubik::Prompt::ToolTeachings.teaching_for("vakanuvis")

    assert_includes storage_active, "goals, plans, reviews, and work notes",
                    "storage teaching must frame direct puts around ordinary work artifacts"
    refute_includes storage_active, "Persist agent workfiles — goals, plans, memory notes, wiki knowledge, reviews",
                    "storage teaching must not direct raw storage puts for memory notes and wiki knowledge"
    refute_includes storage_active, "memory`/`wiki",
                    "storage teaching with vakanuvis active must not instruct writing memory/wiki"
    refute_includes storage_active, "`storage` `put` on `memory`",
                    "storage teaching with vakanuvis active must contain no storage put for memory"

    assert_includes storage_fallback, "reserving direct `storage` `put` on `memory`/`wiki` for sessions where `vakanuvis` is unavailable",
                    "storage teaching fallback must define write path when vakanuvis is unavailable"
    assert_includes vakanuvis_teaching, "never through raw storage puts",
                    "vakanuvis teaching must stay consistent with the storage fallback contract"
  end

  def test_rule_nine_body_renders_appropriate_write_path_variants
    active_body = Rubik::Prompt::Doctrine.rule_nine_body(active_tools: ["storage", "vakanuvis"])
    refute_includes active_body, "storage` `put` on `memory`",
                    "rendered prompt with vakanuvis active contains no storage put for memory/wiki"
    assert_includes active_body, "vakanuvis(action: 'record'",
                    "rendered prompt with vakanuvis active routes writes through vakanuvis record"

    inactive_body = Rubik::Prompt::Doctrine.rule_nine_body(active_tools: ["storage"])
    assert_includes inactive_body, "reserving direct `storage` `put` on `memory`/`wiki`",
                    "rendered prompt with vakanuvis inactive includes storage fallback write instruction"
    refute_includes inactive_body, "The background chronicler keeps compiled knowledge",
                    "rendered prompt with vakanuvis inactive omits vakanuvis teaching"
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
