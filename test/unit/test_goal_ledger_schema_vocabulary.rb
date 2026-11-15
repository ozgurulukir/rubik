# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/tools/builtins/goal_ledger"

# SchemaVocabulary (SSOT türetme yüzeyi): sözlük Ledger::PRODUCTION_SCHEMA'dan
# türetilir — elle yazılan enum/alan kopyası YOKTUR (şema tek doğum yeridir).
# Exact-string pin bilinçli drift alarmıdır: şema değişirse bu pin de
# değişmeli, yoksa description/Σ sayfası/tükenme feedback'i bayatlar.
class TestGoalLedgerSchemaVocabulary < Minitest::Test
  GL = Rubik::Orchestrator::GoalLedger

  PRODUCTION = "tasks(id*,title*,status*:todo|doing|done|blocked|stale,notes?,verify?) " \
               "findings(id*,text*,source_step*) decisions(id*,text*,rationale*) " \
               "open_questions:string-list environment_notes(id*,text*,verify?) " \
               "— * required, ? optional; append items via /<section>/-, " \
               "one op per item; wholesale section writes are rejected"

  def root
    @root ||= Dir.mktmpdir("goal-ledger-vocab")
  end

  def teardown
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  def ledger
    GL::Ledger.create!(goal_text: "vocab", store: Rubik::Storage::Store.new(root: root, project: "vocab"))
  end

  def test_the_production_grammar_is_one_pinned_derived_line
    assert_equal PRODUCTION, GL::Ledger.schema_vocabulary, "schema changed → re-pin the derived vocabulary"
  end

  def test_the_sigma_page_embeds_the_escaped_vocabulary_after_the_objective
    led = ledger
    led.update(JSON.generate({ "rev" => 0, "ops" => [
                               { "op" => "add", "path" => "/tasks/-", "value" => { "id" => "t1", "title" => "Design", "status" => "todo" } }
                             ] }))
    xml = led.to_xml
    assert_includes xml, "<vocabulary>#{Rubik::Platform.xml_escape(PRODUCTION)}</vocabulary>"
    assert_operator xml.index("<vocabulary>"), :>, xml.index("<objective>"), "right after the objective line"
    assert_operator xml.index("<vocabulary>"), :<, xml.index("<tasks>"), "before any collection"
  end

  def test_the_vocabulary_is_derived_from_the_schema_not_hardcoded
    schema = GL::Schema.new(
      root_scalars: { "rev" => GL::FieldSpec.new(type: :integer, managed: true) },
      sections: {
        "widgets" => GL::SectionSpec.new(item: GL::ItemSpec.new(
          fields: { "kind" => GL::FieldSpec.new(type: :string, enum: ["a", "b"]), "label" => GL::FieldSpec.new(type: :string, optional: true) },
          id_field: "kind"
        )),
        "tags" => GL::SectionSpec.new(scalar: :string, max_len: 50)
      }
    )
    out = GL::SchemaVocabulary.render(schema)
    assert_includes out, "widgets(kind*:a|b,label?)"
    assert_includes out, "tags:string-list"
    refute_includes out, "tasks", "nothing from the production schema leaks into a custom derivation"
    refute_includes out, "todo"
  end

  def test_the_tool_surfaces_share_the_single_derived_grammar
    assert_equal GL::Ledger.schema_vocabulary, Rubik::Tools::UpdateGoalLedgerTool::GRAMMAR
    assert_includes Rubik::Tools::UpdateGoalLedgerTool::DECLARATION.description, PRODUCTION
  end
end
