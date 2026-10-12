# frozen_string_literal: true

require_relative "../test_helper"

# GoalLedger alt-ailesi satır cap'leri (test_module_hygiene geleneğinin
# yeni alt-aileye eklenmesi — mevcut hygiene testine dokunulmadı):
# orchestrator/*.rb glob'u shim'i OTOMATİK kapsar (< 400); alt dizin
# dosyalarının cap'leri burada pinlenir.
class TestGoalLedgerHygiene < Minitest::Test
  BASE = File.expand_path("../../lib/rubik/orchestrator", __dir__)

  def line_count(rel)
    File.readlines(File.join(BASE, rel)).size
  end

  def test_goal_ledger_stays_the_namespace_shim_under_90_lines
    assert line_count("goal_ledger.rb") < 90, "goal_ledger.rb must stay the namespace shim under 90 lines"
  end

  def test_the_patch_schema_and_validator_pages_each_stay_under_400_lines
    ["goal_ledger/patch.rb", "goal_ledger/schema.rb", "goal_ledger/validator.rb", "goal_ledger/ledger.rb"].each do |rel|
      count = line_count(rel)
      assert count < 400, "#{rel} must stay under 400 lines, got #{count}"
    end
  end

  # Askı yaşam döngüsü + Σ XML render sayfaları (issue #106 ile doğdu):
  # suspend/resume damga mantığı ve SAF render tek sayfalarda kalır.
  def test_the_suspend_and_render_pages_stay_small
    {
      "goal_ledger/suspend_lifecycle.rb" => 160,
      "goal_ledger/xml_render.rb" => 90
    }.each do |rel, cap|
      count = line_count(rel)
      assert count < cap, "#{rel} must stay under #{cap} lines, got #{count}"
    end
  end

  def test_the_verification_pages_stay_small
    {
      "goal_ledger/verify_spec.rb" => 140,
      "goal_ledger/verifier.rb" => 320,
      "goal_ledger/drift.rb" => 220
    }.each do |rel, cap|
      count = line_count(rel)
      assert count < cap, "#{rel} must stay under #{cap} lines, got #{count}"
    end
  end
end
