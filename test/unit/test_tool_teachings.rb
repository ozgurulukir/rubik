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
end
