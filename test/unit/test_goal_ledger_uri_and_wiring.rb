# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/tools/uri_resolver"

# URI okuma yüzeyi + !goal bağlantısı (goal-ledger planı A): tek goal
# adapter slotunda state/ledger iç dispatch, parent-chain çözümü, dürüst
# not-found, /state regresyonu ve finish payload'ının additive ledger_id'i.
class TestGoalLedgerUriAndWiring < Minitest::Test
  GL = Rubik::Orchestrator::GoalLedger

  def setup
    @root = Dir.mktmpdir("goal-ledger-uri")
    @store = Rubik::Storage::Store.new(root: @root, project: "uri-test")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def ledger
    @ledger ||= GL::Ledger.create!(goal_text: "Fix payments", store: @store, dmesg: nil)
  end

  def ctx_with(coeffects)
    ctx = Object.new
    ctx.define_singleton_method(:get) { |key| coeffects[key] }
    ctx
  end

  def stub_shell(mgr, _rctx)
    shell = Object.new
    def shell.buffer_manager = nil
    def shell.snapshot_store = nil
    def shell.context_index = nil
    def shell.lsp_manager = nil
    def shell.config = nil
    shell.define_singleton_method(:runtime_manager) { mgr }
    shell
  end

  def resolve(uri, coeffects)
    Rubik::Tools::UriResolver.resolve(uri, ctx: ctx_with(coeffects))
  end

  # ---- URI surface ----

  def test_goal_ledger_uri_serves_the_current_sigma_xml
    ledger.update(JSON.generate({ "rev" => 0, "ops" => [
                                  { "op" => "add", "path" => "/findings/-", "value" => { "id" => "f1", "text" => "seam pure", "source_step" => 2 } }
                                ] }))
    body = resolve(Rubik::Uris.goal_ledger, Rubik::Coeffects::GOAL_LEDGER => ledger)
    assert_includes body.to_s, '<goal_ledger rev="1"'
    assert_includes body.to_s, "seam pure"
    xml_variant = resolve("#{Rubik::Uris.goal_ledger}.xml", Rubik::Coeffects::GOAL_LEDGER => ledger)
    assert_equal body.to_s, xml_variant.to_s
  end

  def test_child_contexts_resolve_the_ledger_through_the_parent_chain
    parent = Rubik::Runtime::Context.new
    parent.provide(Rubik::Coeffects::GOAL_LEDGER, ledger)
    child = parent.extend
    body = Rubik::Tools::UriResolver.resolve(Rubik::Uris.goal_ledger, ctx: child)
    assert_includes body.to_s, "<goal_ledger "
  ensure
    child&.dispose
    parent.dispose
  end

  def test_honest_not_found_when_no_ledger_exists
    out = resolve(Rubik::Uris.goal_ledger, {})
    assert_predicate out, :error?
    assert_includes out.to_s, "No goal ledger available"
    assert_includes out.to_s, "goal.ledger.enabled"
  end

  def test_goal_state_still_resolves_after_the_adapter_dispatch_extension
    state = Rubik::Orchestrator::GoalState.new
    state.start!("legacy goal", 5)
    body = resolve(Rubik::Uris.goal_state, Rubik::Coeffects::GOAL_STATE => state)
    assert_includes body.to_s, "<goal_state"
    refute_includes body.to_s, "ledger_id"
  end

  def test_ledger_grammar_does_not_leak_into_the_state_regex
    refute Rubik::Uris::GOAL_STATE.match?(Rubik::Uris.goal_ledger)
    refute Rubik::Uris::GOAL_LEDGER.match?(Rubik::Uris.goal_state)
    assert Rubik::Uris::GOAL_LEDGER.match?("#{Rubik::Uris.goal_ledger}.xml")
  end

  # ---- goal_state.ledger_id additive surface ----

  def test_ledger_id_appears_only_when_set
    state = Rubik::Orchestrator::GoalState.new
    refute_includes state.to_xml, "ledger_id"
    refute state.snapshot.key?(:ledger_id)

    state.start!("wired", 3)
    state.ledger_id = "goal.1.abc123"
    assert_includes state.to_xml, 'ledger_id="goal.1.abc123"'
    assert_equal "goal.1.abc123", state.snapshot[:ledger_id]
  end

  # ---- step-top refresh through the loop hook ----

  def test_step_top_refresh_injects_one_current_row_into_the_loop_history
    led = ledger
    Object.new
    mgr = Object.new
    rctx = Rubik::Runtime::Context.new
    rctx.provide(Rubik::Coeffects::GOAL_LEDGER, led)
    mgr.define_singleton_method(:context) { rctx }
    stub_shell(mgr, rctx)

    loop_inst = Rubik::Orchestrator::Loop.new(
      provider: Object.new, tool_registry: Rubik::Tools::Registry.new,
      max_steps: 2, on_step: nil, shell: stub_shell(mgr, rctx)
    )
    loop_inst.instance_variable_set(:@history, [{ role: "user", content: "<user_task>\nFix payments\n</user_task>" }])

    led.update(JSON.generate({ "rev" => 0, "ops" => [
                               { "op" => "add", "path" => "/tasks/-", "value" => { "id" => "t1", "title" => "Design", "status" => "doing" } }
                             ] }))
    loop_inst.send(:refresh_goal_ledger_row!)
    loop_inst.send(:refresh_goal_ledger_row!)
    rows = loop_inst.history.select { |m| m[:content].to_s.start_with?("<goal_ledger ") }
    assert_equal 1, rows.size, "repeated refresh never stacks rows"
    assert_includes rows.first[:content], 'rev="1"'
    assert_includes rows.first[:content], "Design"
    rctx.dispose
  end

  def test_step_top_refresh_is_a_noop_without_the_coeffect
    Object.new
    mgr = Object.new
    rctx = Rubik::Runtime::Context.new
    mgr.define_singleton_method(:context) { rctx }
    stub_shell(mgr, rctx)

    loop_inst = Rubik::Orchestrator::Loop.new(
      provider: Object.new, tool_registry: Rubik::Tools::Registry.new,
      max_steps: 2, on_step: nil, shell: stub_shell(mgr, rctx)
    )
    history = [{ role: "user", content: "<user_task>\nbare\n</user_task>" }]
    loop_inst.instance_variable_set(:@history, history)
    loop_inst.send(:refresh_goal_ledger_row!)
    assert_equal 1, history.size, "OFF path: the loop history is untouched"
    rctx.dispose
  end
end
