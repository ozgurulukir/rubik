# frozen_string_literal: true

require_relative "../test_helper"

# Pins for the init-0 maestro lifecycle: context-preserving redeploy of
# finished subagents (reuse) and diligent reaping (tombstones, archive
# durability gate, bounded eviction, budget_exhausted immunity).
class TestSubagentReuseAndReap < Minitest::Test
  def setup
    @ws_root = mint_test_root
    @root_context = Rubik::Runtime::Context.new
    @bus = Rubik::EventBus.new
    @sup = new_supervisor
  end

  def teardown
    @sup.shutdown_all
    @root_context.dispose unless @root_context.disposed?
    remove_temp_dir(@ws_root) if @ws_root
  end

  def new_supervisor(provider: done_provider, config: nil, init: nil)
    Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context, event_bus: @bus, root_dir: @ws_root,
      provider: provider, config: config, init: init
    )
  end

  def done_provider(content = "All done")
    resp = Struct.new(:content, :tool_calls).new(content, [])
    provider = Object.new
    provider.define_singleton_method(:complete) { |_hist, _opts = {}| resp }
    provider
  end

  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now >= deadline
    yield
  end

  def spawn_done(sup, role, prompt = "first task")
    inst = sup.spawn(role: role, prompt: prompt, max_steps: 3)
    wait_until { inst.terminal_and_settled? }
    inst
  end

  # ------------------------------------------------------------------ redeploy

  def test_redeploy_round_trip_preserves_context_and_completes_again
    inst = spawn_done(@sup, "Reuser", "research the widgets")

    redeployed = @sup.redeploy(inst.id, prompt: "now summarize findings", max_steps: 5)
    assert_same inst, redeployed, "redeploy reuses the SAME instance — no re-spawn"
    wait_until { inst.terminal_and_settled? && inst.result == "All done" }

    assert_equal :completed, inst.state
    texts = inst.history.map { |m| m[:content].to_s }
    assert texts.any? { |t| t.include?("research the widgets") }, "original task stays in context"
    assert texts.any? { |t| t.include?("[New task from init-0]: now summarize findings") }, "new task is appended"
    assert_equal 1, inst.history.count { |m| m[:role] == "system" }, "no re-seed: exactly one system entry"
    assert_equal 5, inst.max_steps, "budget is re-minted for the new run"
  end

  def test_redeploy_rewrites_transcript_and_index_upserts
    inst = spawn_done(@sup, "Writer")
    @sup.redeploy(inst.id, prompt: "second assignment")
    wait_until { inst.terminal_and_settled? && inst.result == "All done" }

    body = File.read(inst.transcript_uri)
    assert_includes body, "first task"
    assert_includes body, "second assignment", "one transcript accumulates the whole lineage"

    stored = []
    fake_store = Object.new
    fake_store.define_singleton_method(:get) { |_kw| { "id" => "transcript.existing.abc123def456abc0" } }
    fake_store.define_singleton_method(:put) { |**kw| stored << kw }
    Rubik::Storage::TranscriptIndexer.index(fake_store, inst)
    assert_equal 1, stored.size
    assert_equal "transcript.existing.abc123def456abc0", stored.first[:id], "redeploy completion upserts, never duplicates"
  end

  def test_redeploy_refuses_running_instance
    gate = Queue.new
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| gate.pop }
    sup = new_supervisor(provider: provider)
    inst = sup.spawn(role: "Busy", prompt: "blocked work")
    wait_until { inst.state == :running }

    error = assert_raises(ArgumentError) { sup.redeploy(inst.id, prompt: "new task") }
    assert_includes error.message, "live thread"
  ensure
    gate << :release
    sup.shutdown_all
  end

  def test_redeploy_refusal_guidance_for_archived_and_unknown
    inst = spawn_done(@sup, "Gone")
    assert_equal [inst.id], @sup.reap_finished!(force: true)

    error = assert_raises(ArgumentError) { @sup.redeploy(inst.id, prompt: "again") }
    assert_includes error.message, "archived"
    assert_includes error.message, "invoke_subagent", "guidance points to a fresh spawn"

    error = assert_raises(ArgumentError) { @sup.redeploy("subagent-999", prompt: "x") }
    assert_includes error.message, "not found"
  end

  def test_redeploy_swaps_context_registry_and_asker
    gate = Queue.new
    resp_done = Struct.new(:content, :tool_calls).new("All done", [])
    calls = 0
    provider = Object.new
    provider.define_singleton_method(:complete) do |_h, _o = {}|
      calls += 1
      calls == 1 ? resp_done : gate.pop
    end
    sup = new_supervisor(provider: provider)
    inst = sup.spawn(role: "Asker", prompt: "first")
    wait_until { inst.terminal_and_settled? }
    old_ctx = inst.context
    assert old_ctx.disposed?, "sanity: completed run disposed its child ctx"

    sup.redeploy(inst.id, prompt: "follow-up")
    wait_until { inst.state == :running }
    refute_equal old_ctx, inst.context
    refute inst.context.disposed?, "redeploy binds a fresh live child context"
    assert_equal inst, Rubik::Coeffects.get(inst.context, Rubik::Coeffects::SUBAGENT_QUESTION_ASKER),
                 "ask_question works again on the redeployed run (disposed-ctx trap)"
  ensure
    gate << :release
    sup.shutdown_all
  end

  def test_redeploy_registers_fresh_unit_without_state_error
    gate = Queue.new
    resp_done = Struct.new(:content, :tool_calls).new("All done", [])
    calls = 0
    provider = Object.new
    provider.define_singleton_method(:complete) do |_h, _o = {}|
      calls += 1
      calls == 1 ? resp_done : gate.pop
    end
    init = Rubik::Kernel::Init.new
    sup = new_supervisor(provider: provider, init: init)
    inst = sup.spawn(role: "United", prompt: "first task")
    wait_until { inst.terminal_and_settled? }
    old_unit = inst.unit

    sup.redeploy(inst.id, prompt: "second task")
    wait_until { inst.state == :running }
    live_unit = init.get(inst.id)
    refute_equal old_unit, live_unit, "a fresh SubagentUnit replaces the terminal one"
    assert_equal :active, live_unit.state, "unit must be born ACTIVE: a dead-born unit makes the per-turn kernel reaper dispose the live child ctx"
    refute live_unit.dead?

    gate << :release
    wait_until { inst.terminal_and_settled? }
    assert_equal :completed, init.get(inst.id).state, "kernel board tracks the second run to completion"
  end

  def test_redeploy_validates_concurrency
    gate = Queue.new
    resp_done = Struct.new(:content, :tool_calls).new("All done", [])
    calls = 0
    provider = Object.new
    provider.define_singleton_method(:complete) do |_h, _o = {}|
      calls += 1
      calls == 1 ? resp_done : gate.pop
    end
    sup = new_supervisor(provider: provider, config: { "subagents.max_concurrency" => 1 })
    finished = sup.spawn(role: "Idle", prompt: "done task") # terminal: occupies no slot
    wait_until { finished.terminal_and_settled? }
    runner = sup.spawn(role: "Runner", prompt: "blocked work") # fills the single slot
    wait_until { runner.state == :running }

    error = assert_raises(Rubik::Orchestrator::Subagent::ConcurrencyExceededError) { sup.redeploy(finished.id, prompt: "nope") }
    assert_includes error.message, "concurrency"
  ensure
    gate << :release
    sup.shutdown_all
  end

  def test_manage_subagents_redeploy_and_reap_actions
    inst = spawn_done(@sup, "Tooled")
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: @sup)

    out = tool.execute("action" => "redeploy", "conversation_id" => inst.id, "prompt" => "tool-driven task")
    assert out.is_a?(String), "success is a printable String, not an error payload"
    assert_includes out, "context preserved"
    wait_until { inst.terminal_and_settled? }

    err = tool.execute("action" => "redeploy", "conversation_id" => "subagent-77", "prompt" => "x")
    assert err.error?
    assert_includes err.to_s, "not found"

    err = tool.execute("action" => "redeploy", "conversation_id" => inst.id, "prompt" => "  ")
    assert err.error?, "empty prompt is refused"

    reaped = tool.execute("action" => "reap")
    assert reaped.is_a?(String)
    assert_includes reaped, inst.id
  end

  def test_repl_subagents_reuse_and_clean_commands
    inst = spawn_done(@sup, "Repl")
    out = StringIO.new
    ctx = Struct.new(:out).new(out)

    Rubik::REPL::Commands::Subagents.handle_reuse(ctx, @sup, inst.id, ["repl", "task"])
    assert_includes out.string, "context preserved"
    wait_until { inst.terminal_and_settled? }

    Rubik::REPL::Commands::Subagents.handle_clean(ctx, @sup)
    assert_includes out.string, "Reaped"

    out.reopen(StringIO.new)
    Rubik::REPL::Commands::Subagents.handle_reuse(ctx, @sup, inst.id, [])
    assert_includes out.string, "Usage: !subagents reuse"
  end

  # -------------------------------------------------------------------- reaping

  def test_finished_subagent_reaped_after_grace_keeps_queryability
    sup = new_supervisor(config: { "subagents.reap_finished_after" => 0.001 })
    inst = spawn_done(sup, "Reapable")
    wait_until { Time.now - inst.ended_at > 0.005 }

    reaped = sup.reap_finished!
    assert_equal [inst.id], reaped
    refute sup.instances.key?(inst.id), "reaped instance leaves the active registry"
    assert_same inst, sup.get(inst.id), "tombstone keeps status queryable"
    assert_includes sup.list.map(&:id), inst.id, "list still shows the tombstone"
    assert inst.history.empty?, "in-memory context is reclaimed"
    assert File.exist?(inst.transcript_uri), "durable transcript survives the reap"
  end

  def test_archive_refuses_when_transcript_not_durable
    inst = spawn_done(@sup, "Fragile")
    File.delete(inst.transcript_uri)

    assert_equal [], @sup.reap_finished!(force: true), "no transcript — no reap"
    assert @sup.instances.key?(inst.id), "instance stays put for the next sweep"
    refute inst.history.empty?, "history is never dropped before durability"
  end

  def test_archived_transcript_renders_pointer
    inst = spawn_done(@sup, "Pointed")
    @sup.reap_finished!(force: true)

    rendered = inst.format_transcript
    assert_includes rendered, "[No in-memory history"
    assert_includes rendered, inst.transcript_uri, "the pointer names where the full transcript lives"
    assert_includes rendered, "All done", "final result summary survives"
  end

  def test_tombstone_bounded_eviction
    sup = new_supervisor(config: { "subagents.tombstone_limit" => 2 })
    insts = 3.times.map do |i|
      inst = spawn_done(sup, "Wave#{i}", "task #{i}")
      sleep 0.002
      inst
    end

    sup.reap_finished!(force: true)
    assert_nil sup.get(insts.first.id), "eldest tombstone evicted beyond the limit"
    assert_equal :disposed, insts.first.state
    assert sup.get(insts[1].id) && sup.get(insts[2].id), "younger tombstones stay queryable"
  end

  def test_reap_config_zero_disables_auto_but_force_works
    sup = new_supervisor(config: { "subagents.reap_finished_after" => 0 })
    inst = spawn_done(sup, "Linger")
    sleep 0.01

    assert_equal [], sup.reap_finished!, "grace 0 disables the automatic path"
    assert sup.instances.key?(inst.id)
    assert_equal [inst.id], sup.reap_finished!(force: true), "force reap still works"
  end

  def test_budget_exhausted_and_active_never_reaped
    resp_tool = Struct.new(:content, :tool_calls).new("Working", [{ "id" => "c", "tool" => "dummy", "args" => {} }])
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| resp_tool }
    sup = new_supervisor(provider: provider,
                         config: { "subagents.budget_wait_timeout" => 0.01, "subagents.reap_finished_after" => 0.001 })
    inst = sup.spawn(role: "Parked", prompt: "never ends", max_steps: 1)
    wait_until { inst.state == :budget_exhausted }

    assert_equal [], sup.reap_finished!(force: true), "live-thread park states are immune to force reap"
    assert sup.instances.key?(inst.id)
  ensure
    sup.shutdown_all
  end

  def test_completion_driven_sweep_reaps_older_finished_peers
    sup = new_supervisor(config: { "subagents.reap_finished_after" => 0.001 })
    first = spawn_done(sup, "First", "done quickly")
    sleep 0.01

    second = spawn_done(sup, "Second", "also done")

    refute sup.instances.key?(first.id), "second completion sweeps the first past grace (reap_orphans hook)"
    assert sup.get(second.id), "just-finished peer stays queryable (tombstone or registry)"
  end

  # ------------------------------------------------------- config and doctrine

  def test_defaults_expose_reap_knobs
    sub = Rubik::Config::DEFAULT_CONFIG["subagents"]
    assert_equal 300, sub["reap_finished_after"]
    assert_equal 25, sub["tombstone_limit"]
  end

  def test_orchestration_guidance_teaches_reuse_and_cleanup
    xml = Rubik::Prompt::ContextBuilder.build_subagents_xml(Rubik::Orchestrator::Subagent::TypeRegistry.new)
    assert_includes xml, "redeploy", "guidance teaches context reuse"
    assert_includes xml, "reaped automatically", "guidance teaches diligent cleanup"
    assert_includes xml, "transcript", "cleanup bullet names the durable artifact"
  end

  def test_operational_rules_always_carry_maestro_override
    rules = Rubik::Prompt::Doctrine.operational_rules_xml
    assert_equal 2, rules.scan("MAESTRO OVERRIDE").size, "edit/test rules are delegated wholesale in EVERY mode (user ruling 2026-10-01)"
    assert_includes rules, "As init-0 you orchestrate", "rule 7 frames delegation as the default, not an option"
    assert_includes rules, "read-only: shape subagent assignments", "rule 1 scopes direct tools to read-only shaping"
    first_override = rules.index("MAESTRO OVERRIDE")
    mechanics = rules.index("For modifying existing files, prefer")
    assert first_override < mechanics, "the override LEADS rule 2 — a trailing caveat was skipped by weak models (opencode-personal)"
  end
end
