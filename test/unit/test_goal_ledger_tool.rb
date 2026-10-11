# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/tools/builtins/goal_ledger"

# update_goal_ledger aracı kontratı (plan A): REQUIRES-görünürlük (pruner
# mold'u), sınıflandırılmış ret yankısı (C reason'larının birebir taşıması),
# dürüst tükenme ve coeffect'siz dürüst yokluk hatası.
class TestGoalLedgerTool < Minitest::Test
  GL = Rubik::Orchestrator::GoalLedger

  def setup
    @root = Dir.mktmpdir("goal-ledger-tool")
    @store = Rubik::Storage::Store.new(root: @root, project: "tool-test")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def ctx_with(ledger)
    ctx = Object.new
    resolved = ledger
    ctx.define_singleton_method(:get) { |_key| resolved }
    ctx
  end

  def tool(ledger)
    Rubik::Tools::UpdateGoalLedgerTool.new(runtime_context: ledger ? ctx_with(ledger) : nil)
  end

  def ledger
    GL::Ledger.create!(goal_text: "Ship the tool", store: @store, dmesg: nil)
  end

  def patch(ops, rev: 0)
    JSON.generate({ "rev" => rev, "ops" => ops })
  end

  def add_task
    { "op" => "add", "path" => "/tasks/-", "value" => { "id" => "t1", "title" => "Design", "status" => "todo" } }
  end

  def test_the_tool_is_a_requirer_with_the_goal_ledger_coeffect
    assert_includes Rubik::Tools::UpdateGoalLedgerTool::REQUIRES, Rubik::Coeffects::GOAL_LEDGER
    assert_empty Rubik::Tools::UpdateGoalLedgerTool::DECLARATION.archetypes
  end

  def test_a_running_goal_accepts_a_patch_and_the_result_echoes_the_new_rev_and_storage_uri
    out = tool(ledger).execute("patch" => patch([add_task]))
    refute_predicate out, :error?
    assert_includes out.to_s, "<goal_ledger_applied rev=\"1\""
    assert_includes out.to_s, "rubik://storage/tool-test/goal/"
  end

  def test_each_rejection_returns_the_classified_reason_lines_the_model_can_act_on
    t = tool(ledger)
    conflict = t.execute("patch" => patch([add_task], rev: 9))
    assert_predicate conflict, :error?
    assert_includes conflict.to_s, "[conflict]"
    assert_includes conflict.to_s, "rev 0"

    schema = t.execute("patch" => patch([{ "op" => "add", "path" => "/open_questions/-", "value" => 42 }]))
    assert_includes schema.to_s, "[schema]"
    assert_includes schema.to_s, "expected string, got integer"

    syntax = tool(ledger).execute("patch" => "{nope")
    assert_includes syntax.to_s, "[syntax]"
  end

  def test_rejection_budget_exhaustion_is_honest_state_unchanged_goal_work_may_continue
    t = tool(ledger)
    t.execute("patch" => "{nope")
    t.execute("patch" => "{nope")
    out = t.execute("patch" => "{nope")
    assert_predicate out, :error?
    assert_includes out.to_s, "budget exhausted"
    assert_includes out.to_s, "unchanged at rev 0"
    assert_includes out.to_s, "Goal work may continue"
  end

  def test_no_ledger_yields_an_honest_unavailable_error_not_a_stack_trace
    out = tool(nil).execute("patch" => patch([add_task]))
    assert_predicate out, :error?
    assert_includes out.to_s, "not available"
    assert_includes out.to_s, "goal.ledger.enabled"
  end

  def test_a_missing_or_empty_patch_parameter_is_refused_without_touching_the_ledger
    led = ledger
    refused = tool(led).execute({})
    assert_predicate refused, :error?
    assert_includes refused.to_s, "'patch' parameter is required"
    assert_equal 0, led.snapshot[:rev]
  end
end
