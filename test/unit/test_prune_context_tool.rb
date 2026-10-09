# frozen_string_literal: true

require_relative "../test_helper"

# prune_context aracı (test_vakanuvis_tool emsali): DECLARATION pin'leri,
# REQUIRES coeffect gizleme/açılma, eylem yüzeymi (prune makbuzu / status
# raporu), kapalıyken empatik hata, sembol-anhtarlı argümanlar ve rescue
# yolları.
class TestPruneContextTool < Minitest::Test
  def test_declaration_pins_the_root_desk_shape
    decl = Rubik::Tools::PruneContextTool::DECLARATION
    assert_equal "prune_context", decl.name
    assert_equal ["pruner"], decl.aliases
    assert_equal :write, decl.risk
    assert_empty decl.archetypes, "orchestrator-plane only (no subagent archetype carries it)"
    refute decl.write_grant
    refute decl.maestro_blocked, "vakanüvis emsali: root-direct desk, explicit"
    assert_equal [Rubik::Coeffects::PRUNER], Rubik::Tools::PruneContextTool::REQUIRES
    enum = decl.params_schema[:properties][:action][:enum]
    assert_equal ["prune", "status"], enum.sort
  end

  def test_registry_hides_the_tool_until_the_coeffect_is_satisfied
    root = Dir.mktmpdir("rubik_pruner_hide")
    begin
      ctx = Rubik::Runtime::Context.new
      source = Rubik::Tools::Registry.build_default(
        buffer_manager: Rubik::Buffer::Manager.new(root_dir: root), runtime_manager: nil, root_dir: root
      )
      hidden = Rubik::Tools::Registry.new(coeffect_ctx: ctx)
      source.list.each { |t| hidden.register(t) }
      refute_includes hidden.schemas.map { |s| s[:name] }, "prune_context",
                      "unsatisfied PRUNER coeffect must hide the tool (knob off by default)"

      ctx.provide(Rubik::Coeffects::PRUNER, FakeHarness.new)
      assert_includes hidden.schemas.map { |s| s[:name] }, "prune_context"
      ctx.dispose
    ensure
      remove_temp_dir(root)
    end
  end

  def test_actions_delegate_to_the_harness
    harness = FakeHarness.new
    tool = Rubik::Tools::PruneContextTool.new(harness)
    receipt = tool.execute({ "action" => "prune", "reason" => "cleanup" })
    assert_includes receipt, "did NOT wait for the LLM"
    assert_equal ["cleanup"], harness.prune_reasons

    status = tool.execute({ action: "status" })
    assert_includes status, "Context pruner:"
  end

  def test_disabled_harness_teaches_the_knob
    tool = Rubik::Tools::PruneContextTool.new(nil)
    out = tool.execute({ "action" => "status" })
    assert out.is_a?(Rubik::Tools::ToolOutput) || out.to_s.include?("subagents.pruner.enabled")
    assert_includes out.to_s, "subagents.pruner.enabled"
  end

  def test_unknown_action_and_crash_paths_return_tool_errors
    harness = FakeHarness.new(crash: true)
    tool = Rubik::Tools::PruneContextTool.new(harness)
    unknown = tool.execute({ "action" => "explode" })
    assert_includes unknown.to_s, "Unknown prune_context action"

    crashed = tool.execute({ "action" => "status" })
    assert_includes crashed.to_s, "failed"
  end

  # Behavior-only fake: the tool delegates, the harness decides.
  class FakeHarness
    attr_reader :prune_reasons

    def initialize(crash: false)
      @crash = crash
      @prune_reasons = []
    end

    def prune(reason: "manual")
      raise "boom" if @crash

      @prune_reasons << reason
      "Prune queued (async): the pruner will propose a plan. This call did NOT wait for the LLM."
    end

    def status_text
      raise "boom" if @crash

      "Context pruner:\n  window: 3 entries"
    end

    def dmesg = nil
  end
end
