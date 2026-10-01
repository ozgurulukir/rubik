# frozen_string_literal: true

require_relative "../test_helper"

# Pins for the FS/SS dispatch dependency graph (PM-style constraints):
# deferred specs hold no slot and no cost until released; FS releases on
# predecessor completion (failure cancels dependents), SS on first start;
# DAG cycles are refused before anything is reserved; wait/list/status/kill
# all speak the queued vocabulary.
class TestSubagentDependencies < Minitest::Test
  def setup
    @ws_root = mint_test_root
    @root_context = Rubik::Runtime::Context.new
    @bus = Rubik::EventBus.new
    @sup = new_supervisor(done_provider)
  end

  def teardown
    @sup.shutdown_all
    @root_context.dispose unless @root_context.disposed?
    remove_temp_dir(@ws_root) if @ws_root
  end

  def new_supervisor(provider, config: nil)
    Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context, event_bus: @bus, root_dir: @ws_root,
      provider: provider, config: config
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

  # ---------------------------------------------------------------- releases

  def test_dependency_fs_chain_releases_after_completion
    results = @sup.spawn_batch(
      [{ role: "Researcher", prompt: "research", max_steps: 2 },
       { role: "Engineer", prompt: "build", max_steps: 2, depends_on: ["subagent-1"] }]
    )
    assert_equal :launched, results[0][0]
    assert_equal :queued, results[1][0]
    assert results[1][1].queued?, "dependent is a spec, not an instance, before release"

    wait_until { @sup.get("subagent-2")&.terminal_and_settled? }
    inst = @sup.get("subagent-2")
    assert_equal :completed, inst.state, "FS dependent ran the real spawn choreography after predecessor completed"
    assert_equal "agent-0", inst.parent_id
    refute @sup.get("subagent-1").nil?
  end

  def test_dependency_fs_failed_predecessor_cancels_dependent
    boom = Class.new(StandardError).new("provider exploded")
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| raise boom }
    sup = new_supervisor(provider)
    events = []
    @bus.subscribe(Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT) { |p| events << p }

    results = sup.spawn_batch(
      [{ role: "Doomed", prompt: "crash", max_steps: 2 },
       { role: "Dependent", prompt: "never", max_steps: 2, depends_on: ["subagent-1"] }]
    )
    assert_equal :launched, results[0][0]
    wait_until { sup.get("subagent-1")&.terminal_and_settled? }
    wait_until { results[1][1].cancelled? }

    assert_equal :cancelled, results[1][1].state
    assert_includes results[1][1].last_error.to_s, "predecessor failed"
    notice = events.find { |p| p[:id] == "subagent-2" }
    assert notice, "cancellation is announced on the completion event channel"
    assert_equal :cancelled, notice[:state]
  end

  def test_dependency_ss_release_after_start
    gate = Queue.new
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| gate.pop }
    sup = new_supervisor(provider)

    results = sup.spawn_batch(
      [{ role: "Server", prompt: "long run", max_steps: 3 },
       { role: "Watcher", prompt: "watch", max_steps: 3, depends_on: [{ id: "subagent-1", type: "SS" }] }]
    )
    # The spawn-tail sweep may release B before spawn_batch even returns —
    # the outcome label resolves to the REAL state (stale-label fix).
    assert [:launched, :queued].include?(results[1][0])
    wait_until { sup.get("subagent-1")&.state == :running }
    wait_until { !sup.get("subagent-2").nil? }
    refute_nil sup.get("subagent-2"), "SS dependent releases once the predecessor is running"
  ensure
    gate << :release
    sup&.shutdown_all
  end

  def test_dependency_immediate_release_on_terminal_predecessor
    inst = @sup.spawn(role: "First", prompt: "done quickly", max_steps: 2)
    wait_until { inst.terminal_and_settled? }

    results = @sup.spawn_batch([{ role: "Follower", prompt: "follow", max_steps: 2, depends_on: [inst.id] }])
    assert_equal :launched, results[0][0], "FS on an already-completed predecessor is satisfied at dispatch"
    refute_equal inst.id, results[0][1].id, "the follower is a NEW instance on the reserved id"
    wait_until { results[0][1].terminal_and_settled? }
    assert_equal :completed, results[0][1].state
  end

  def test_dependency_cross_batch_release
    first = @sup.spawn(role: "Cross A", prompt: "task a", max_steps: 2)
    results = @sup.spawn_batch([{ role: "Cross B", prompt: "task b", max_steps: 2, depends_on: [first.id] }])
    assert_equal :queued, results[0][0]

    wait_until { first.terminal_and_settled? }
    wait_until { @sup.get(results[0][1].id)&.terminal_and_settled? }
    assert_equal :completed, @sup.get(results[0][1].id).state
  end

  # ------------------------------------------------------------- validation

  def test_dependency_cycle_refused_in_one_batch
    error = assert_raises(ArgumentError) do
      @sup.spawn_batch(
        [{ role: "A", prompt: "a", depends_on: ["subagent-2"] },
         { role: "B", prompt: "b", depends_on: ["subagent-1"] }]
      )
    end
    assert_includes error.message, "cycle"
    assert_includes error.message, "subagent-1"
    assert_empty @sup.list.select { |i| i.respond_to?(:queued?) }, "nothing reserved on a refused batch"
    assert_equal 0, @sup.instance_variable_get(:@counter), "counter is not advanced by a refused batch"
  end

  def test_dispatch_refusals
    error = assert_raises(ArgumentError) do
      @sup.spawn(role: "X", prompt: "x", depends_on: ["subagent-99"])
    end
    assert_includes error.message, "Unknown dependency"

    error = assert_raises(ArgumentError) do
      @sup.spawn(role: "X", prompt: "x", depends_on: [{ id: "subagent-99", type: "FF" }])
    end
    assert_includes error.message, "Unsupported dependency type"

    boom = Class.new(StandardError).new("nope")
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| raise boom }
    sup = new_supervisor(provider)
    failed = sup.spawn(role: "Fails", prompt: "die", max_steps: 2)
    wait_until { failed.terminal_and_settled? }

    error = assert_raises(ArgumentError) do
      sup.spawn(role: "Y", prompt: "y", depends_on: [failed.id])
    end
    assert_includes error.message, "already failed"
  ensure
    sup&.shutdown_all
  end

  # ------------------------------------------------- concurrency and slots

  def test_deferred_specs_consume_no_concurrency_slots
    gate = Queue.new
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| gate.pop }
    sup = new_supervisor(provider, config: { "subagents.max_concurrency" => 1 })
    blocker = sup.spawn(role: "Blocker", prompt: "hold slot", max_steps: 3)
    wait_until { blocker.state == :running }

    results = sup.spawn_batch(
      [{ role: "One", prompt: "a", depends_on: [blocker.id] },
       { role: "Two", prompt: "b", depends_on: ["subagent-2"] },
       { role: "Three", prompt: "c", depends_on: ["subagent-3"] }]
    )
    assert_equal [:queued, :queued, :queued], results.map(&:first),
                 "a queued chain reserves ids without touching the concurrency gate"
    ids = results.map { |_o, s| s.id }
    assert_equal ["subagent-2", "subagent-3", "subagent-4"], ids
  ensure
    gate << :release
    sup&.shutdown_all
  end

  def test_concurrency_gate_at_release_requeues_then_launches
    gate = Queue.new
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| gate.pop }
    sup = new_supervisor(provider, config: { "subagents.max_concurrency" => 1 })
    blocker = sup.spawn(role: "Solo", prompt: "occupy", max_steps: 3)
    wait_until { blocker.state == :running }

    results = sup.spawn_batch(
      [{ role: "Free", prompt: "no deps", max_steps: 2 },
       { role: "Chained", prompt: "after free", max_steps: 2, depends_on: ["subagent-2"] }]
    )
    assert_equal [:queued, :queued], results.map(&:first),
                 "X queued by the full slot, Y queued by its FS dependency"

    sup.kill(blocker.id) # slot frees; X launches via kill's release sweep
    wait_until { sup.get("subagent-2")&.state == :running }
    assert_equal :queued, results[1][1].state, "Y still waits for X to COMPLETE"

    gate << :release # X completes
    gate << :release # Y (released by the completion sweep) completes too
    wait_until { sup.get("subagent-3")&.terminal_and_settled? }
    assert_equal :completed, sup.get("subagent-3").state, "X completed -> Y launches and completes"
  ensure
    sup&.shutdown_all
  end

  # ------------------------------------------------ surfaces: wait/list/etc

  def test_wait_on_queued_id_blocks_until_chain_settles
    results = @sup.spawn_batch(
      [{ role: "Root", prompt: "root work", max_steps: 2 },
       { role: "Leaf", prompt: "leaf work", max_steps: 2, depends_on: ["subagent-1"] }]
    )
    rows = @sup.wait_for([results[1][1].id], timeout: 8)
    assert_equal 1, rows.size, "a queued id is not dropped from wait results"
    assert_equal "completed", rows.first[:state], "wait blocks through release and completion"
  end

  def test_list_includes_queued_rows_with_deps
    gate = Queue.new
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| gate.pop }
    sup = new_supervisor(provider)
    blocker = sup.spawn(role: "Blocker", prompt: "hold", max_steps: 3)
    wait_until { blocker.state == :running }
    sup.spawn_batch([{ role: "Waiting", prompt: "w", depends_on: [blocker.id] }])

    row = sup.list.find { |i| i.id == "subagent-2" }
    refute_nil row
    assert row.respond_to?(:queued?), "duck-typed spec renders without branching"
    assert_equal false, row.running?
    assert_equal ["#{blocker.id}:FS"], row.depends_on
    assert_equal "queued", row.to_h[:state]
  ensure
    gate << :release
    sup&.shutdown_all
  end

  def test_kill_predecessor_cancels_dependents_and_queued_drop
    gate = Queue.new
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| gate.pop }
    sup = new_supervisor(provider)
    sup_spawn = sup.spawn_batch(
      [{ role: "Pred", prompt: "p", max_steps: 3 },
       { role: "Dep", prompt: "d", depends_on: ["subagent-1"], max_steps: 3 }]
    )
    assert_equal :queued, sup_spawn[1][0]

    assert sup.kill("subagent-1"), "killing a predecessor cancels its deferred dependents"
    wait_until { sup_spawn[1][1].cancelled? }
    assert_equal :cancelled, sup_spawn[1][1].state

    # Kill of the queued spec itself just drops it. Dispatching on a
    # CANCELLED spec id is refused (liveness contract, reviewer finding 1).
    blocker = sup.spawn(role: "Blocker", prompt: "hold slot", max_steps: 3)
    wait_until { blocker.state == :running }
    other = sup.spawn_batch([{ role: "Solo", prompt: "s", depends_on: [blocker.id] }])
    assert_equal :queued, other[0][0]
    assert sup.kill(other[0][1].id), "queued spec is killable"
    assert_nil sup.get(other[0][1].id)

    error = assert_raises(ArgumentError) do
      sup.spawn_batch([{ role: "Zombie", prompt: "z", depends_on: [sup_spawn[1][1].id] }])
    end
    assert_includes error.message, "cancelled"
  ensure
    gate << :release
    sup&.shutdown_all
  end

  def test_manage_subagents_wait_and_status_on_queued
    gate = Queue.new
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| gate.pop }
    sup = new_supervisor(provider)
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)
    blocker = sup.spawn(role: "Blocker", prompt: "hold", max_steps: 3)
    wait_until { blocker.state == :running }

    sup.spawn_batch([{ role: "Q", prompt: "q", depends_on: [blocker.id], max_steps: 3 }])
    status = tool.execute("action" => "status", "conversation_id" => "subagent-2")
    assert_includes status, '"queued"'
    assert_includes status, "#{blocker.id}:FS"

    gate << :release # blocker completes -> Q releases
    gate << :release # Q completes
    tool.execute("action" => "wait", "conversation_ids" => ["subagent-2"], "timeout" => 5)
    status = tool.execute("action" => "status", "conversation_id" => "subagent-2")
    assert_includes status, '"completed"', "released spec ran to completion and status reflects it"
  ensure
    sup&.shutdown_all
  end

  def test_invoke_subagent_tool_output_distinguishes_launched_and_queued
    tool = Rubik::Tools::InvokeSubagentTool.new(supervisor: @sup)
    out = tool.execute(
      "subagents" => [
        { "role" => "Scout", "prompt" => "explore things", "max_steps" => 2 },
        { "role" => "Builder", "prompt" => "build it", "max_steps" => 2, "depends_on" => ["subagent-1"] }
      ]
    )
    assert_includes out.to_s, "Launched 1 background subagent(s):"
    assert_includes out.to_s, "QUEUED (waiting on: subagent-1:FS)"
  end

  # ------------------------------------------------- reviewer regressions

  def test_launch_failed_spec_cancels_dependents_not_wedge
    sup = new_supervisor(done_provider, config: { "subagents.max_depth" => 1 })
    nested_parent = sup.spawn(role: "Parent", prompt: "p", max_steps: 3)

    # Force a LAUNCH failure: the chained spec spawns with a nested parent
    # -> validate_depth! raises inside launch_claimed!.
    sup.define_singleton_method(:spawn) do |**kwargs|
      kwargs[:parent_id] == "agent-0" ? super(**kwargs) : raise(Rubik::Orchestrator::Subagent::DepthExceededError, "forced")
    end
    results = sup.spawn_batch(
      [{ role: "Child", prompt: "c", parent_id: nested_parent.id, max_steps: 2 },
       { role: "GrandChild", prompt: "g", depends_on: ["subagent-2"], max_steps: 2 }]
    )
    wait_until { results[1][1].state != :queued }

    assert_equal :cancelled, results[0][1].state, "launch failure cancels the spec (fail loud)"
    assert_equal :cancelled, results[1][1].state, "dependent of a launch-failed spec is CANCELLED, never wedged :queued"
  ensure
    sup&.shutdown_all
  end

  def test_failed_predecessor_cascades_transitively
    boom = Class.new(StandardError).new("boom")
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| raise boom }
    sup = new_supervisor(provider)

    results = sup.spawn_batch(
      [{ role: "A", prompt: "a", max_steps: 2 },
       { role: "B", prompt: "b", depends_on: ["subagent-1"], max_steps: 2 },
       { role: "C", prompt: "c", depends_on: ["subagent-2"], max_steps: 2 }]
    )
    wait_until { results[2][1].state != :queued }

    assert_equal :cancelled, results[1][1].state
    assert_equal :cancelled, results[2][1].state, "cascade reaches a fixpoint: C dies with its cancelled parent B"
  ensure
    sup&.shutdown_all
  end
end
