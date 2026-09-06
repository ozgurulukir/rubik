# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/classifier/models"

class TestCommandClassifierModels < Minitest::Test
  Classification = Rubik::Security::Classifier::Classification
  Risk = Rubik::Security::Classifier::Risk

  def test_classification_severity_ordering
    assert_equal 0, Classification.severity(:readonly)
    assert_equal 1, Classification.severity(:local_effects)
    assert_equal 2, Classification.severity(:external_effects)
    assert_equal 3, Classification.severity(:unknown)
    assert_equal 4, Classification.severity(:dangerous)

    # String normalization
    assert_equal 0, Classification.severity("READONLY")
    assert_equal 4, Classification.severity("dangerous")
  end

  def test_classification_max_severity
    assert_equal :readonly, Classification.max_severity
    assert_equal :dangerous, Classification.max_severity(:readonly, :dangerous, :local_effects)
    assert_equal :unknown, Classification.max_severity(:readonly, :local_effects, :unknown)
    assert_equal :external_effects, Classification.max_severity(:readonly, :local_effects, :external_effects)
  end

  def test_risk_severity_ordering
    assert_equal 0, Risk.severity(:low)
    assert_equal 1, Risk.severity(:medium)
    assert_equal 2, Risk.severity(:high)

    assert_equal 0, Risk.severity("LOW")
    assert_equal 2, Risk.severity("HIGH")
  end

  def test_risk_max_severity
    assert_equal :low, Risk.max_severity
    assert_equal :high, Risk.max_severity(:low, :high, :medium)
    assert_equal :medium, Risk.max_severity(:low, :medium)
  end

  def test_redirect_model
    r = Rubik::Security::Classifier::Redirect.new(operator: ">", target: "out.txt", affects_classification: true)
    assert_equal ">", r.operator
    assert_equal "out.txt", r.target
    assert r.affects_classification
  end

  def test_command_invocation_immutability_and_with
    inv = Rubik::Security::Classifier::CommandInvocation.new(
      argv: ["ls", "-la"],
      position_in_pipeline: 0,
      pipeline_length: 1
    )
    assert_equal ["ls", "-la"], inv.argv
    refute inv.is_background

    inv2 = inv.with(is_background: true)
    assert inv2.is_background
    refute inv.is_background
  end

  def test_command_def_model
    cmd = Rubik::Security::Classifier::CommandDef.new(
      command: "test_cmd",
      classification: :readonly,
      risk: :low
    )
    assert_equal "test_cmd", cmd.command
    assert_equal :readonly, cmd.classification
    assert_equal :low, cmd.risk
    assert cmd.strict
    assert_equal :hierarchical, cmd.subcommand_mode
  end

  def test_expression_result_model
    res = Rubik::Security::Classifier::ExpressionResult.new(
      expression: "echo hello",
      classification: :readonly,
      risk: :low
    )
    assert_equal "echo hello", res.expression
    assert_equal :readonly, res.classification
    assert_equal :low, res.risk
    assert_empty res.commands
    assert_empty res.parse_warnings
  end
end
