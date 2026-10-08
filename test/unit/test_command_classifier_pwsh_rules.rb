# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/classifier/pwsh_rules"

class TestCommandClassifierPwshRules < Minitest::Test
  PwshRules = Rubik::Security::Classifier::PwshRules

  def test_definitions_returns_hash
    defs = PwshRules.definitions
    refute_nil defs
    assert_kind_of Hash, defs
    assert defs.key?("remove-item")
  end

  def test_key_lookup
    assert PwshRules.key?("Remove-Item")
    assert PwshRules.key?("remove-item")
    assert PwshRules.key?("rm")
    assert PwshRules.key?("Get-ChildItem")
    assert PwshRules.key?("ls")
    refute PwshRules.key?("non-existent-command-xyz")
  end

  def test_bracket_lookup
    remove_item = PwshRules["Remove-Item"]
    refute_nil remove_item
    assert_equal "Remove-Item", remove_item.command
    assert_equal :local_effects, remove_item.classification
    assert_equal :medium, remove_item.risk

    # Lookup via alias
    rm_alias = PwshRules["rm"]
    assert_equal remove_item, rm_alias

    # Lookup non-existent
    assert_nil PwshRules["unknown-cmd"]
  end

  def test_build_definitions_creates_fresh_structure
    fresh = PwshRules.build_definitions
    assert fresh.key?("stop-process")
    assert fresh.key?("kill")
    assert fresh.key?("invoke-webrequest")
    assert fresh.key?("curl")
    assert fresh.key?("start-process")
    assert fresh.key?("format-volume")
  end

  def test_dangerous_cmdlets_classification
    dangerous = PwshRules["Format-Volume"]
    refute_nil dangerous
    assert_equal "Format-Volume", dangerous.command
    assert_equal :dangerous, dangerous.classification
    assert_equal :high, dangerous.risk
  end
end
