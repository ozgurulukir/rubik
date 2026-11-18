# frozen_string_literal: true

require_relative "../test_helper"

# Regressions for issues #552 (teardown-under-lock deadlocks) and #553
# (subagent lifecycle leaks). The lock tests are deterministic: an inverse or
# fiber teardown re-enters its owner from another thread while that owner's
# monitor would be held by the buggy implementation.
class TestRuntimeLocksAndLifecycle < Minitest::Test
  def setup
    @root_context = Rubik::Runtime::Context.new
    @ws_root = mint_test_root
    @bus = Rubik::EventBus.new
  end

  def teardown
    @root_context.dispose unless @root_context.disposed?
    remove_temp_dir(@ws_root) if @ws_root
  end

  # ------------------------------------------------------------------ #552

  def test_dispose_runs_inverses_without_holding_the_context_monitor
    # A teardown inverse (e.g. the supervisor's shutdown_all) may need another
    # thread to re-enter this context — a worker's child dispose ends in
    # parent.prune_child. If dispose held the monitor while draining, that
    # thread blocks and the inverse times out (the old deadlock).
    ctx = Rubik::Runtime::Context.new
    observed = Queue.new
    ctx.on_dispose do
      probe = Thread.new { observed << ctx.disposable_count }
      raise "context monitor held during inverse" unless probe.join(1)
    end

    ctx.dispose

    assert_empty ctx.last_dispose_errors, "dispose must not run inverses under its monitor"
    assert_equal 0, observed.pop
  end

  def test_failing_inverse_does_not_re_resolve_dmesg
    # run_inverse's old `dmesg ||= resolve_dmesg` fallback walked to the parent
    # while the child monitor was held — a child→parent lock inversion. The
    # sentinel is now passed in by the caller; run_inverse must never resolve.
    ctx = Rubik::Runtime::Context.new
    ctx.define_singleton_method(:resolve_dmesg) do
      raise "resolve_dmesg must not be called from run_inverse"
    end

    capture_io { ctx.send(:run_inverse, -> { raise "inverse boom" }) }

    assert_equal 1, ctx.last_dispose_errors.size
    assert_equal "inverse boom", ctx.last_dispose_errors.first.message
  end

  def test_unregister_component_disposes_fiber_outside_the_manager_monitor
    # ComponentFiber#dispose! unwinds a sub-context whose inverses may call
    # back into the manager. Disposing under the manager monitor inverted the
    # manager→Context lock order (#552).
    manager = Rubik::Runtime::Manager.new
    reentered = Queue.new
    manager.register_component("svc") do |sub_ctx|
      sub_ctx.on_dispose do
        probe = Thread.new { reentered << manager.fibers }
        raise "manager monitor held during fiber teardown" unless probe.join(1)
      end
      Object.new
    end
    fiber = manager.fibers["svc"]
    sub_ctx = fiber.sub_context

    manager.unregister_component("svc")

    assert_equal :disposed, fiber.state
    assert_empty sub_ctx.last_dispose_errors, "fiber teardown must run with the manager monitor released"
    assert_equal({}, reentered.pop)
    assert_nil manager.fibers["svc"]
  ensure
    manager.dispose!
  end

  def test_root_context_dispose_terminates_a_live_worker_without_hanging
    # shutdown_all is a root-context disposal inverse. With a live worker the
    # old drain-under-monitor path could deadlock against the worker's child
    # context reaching back via parent.prune_child; REPL exit hung forever.
    cfg = Rubik::Config.new
    cfg.set("subagents.budget_wait_timeout", 0.01)
    cfg.set("subagents.error_wait_timeout", 30)
    tool_resp = Struct.new(:content, :tool_calls).new("working", [{ "id" => "c", "tool" => "dummy", "args" => {} }])
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| tool_resp }
    sup = new_supervisor(provider, config: cfg)
    inst = sup.spawn(role: "Live", prompt: "loop", max_steps: 1)
    assert wait_until { inst.state == :budget_exhausted }, "worker must be live and parked"

    done = Queue.new
    disposer = Thread.new do
      @root_context.dispose
      done << true
    end

    assert disposer.join(3), "root dispose must not hang while a worker thread is live"
    assert done.pop
    assert inst.terminal? || inst.disposed?, "shutdown_all must have killed the live worker"
  ensure
    disposer&.kill if disposer&.alive?
    sup&.shutdown_all
  end

  # ------------------------------------------------------------------ #553

  def test_budget_exhausted_worker_fails_after_the_deadline_and_is_reapable
    cfg = Rubik::Config.new
    cfg.set("subagents.budget_wait_timeout", 0.01)
    cfg.set("subagents.error_wait_timeout", 0.05)
    cfg.set("subagents.reap_finished_after", 0.001)
    tool_resp = Struct.new(:content, :tool_calls).new("working", [{ "id" => "c", "tool" => "dummy", "args" => {} }])
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| tool_resp }
    sup = new_supervisor(provider, config: cfg)
    inst = sup.spawn(role: "Parked", prompt: "loop", max_steps: 1)
    assert(wait_until { inst.state == :budget_exhausted })

    assert wait_until { inst.state == :failed }, "an unanswered budget park must fail after the bounded deadline"
    assert(wait_until { inst.terminal_and_settled? })
    assert_equal [inst.id], sup.reap_finished!(force: true), "a failed (terminal) worker must be reapable"
  ensure
    sup&.shutdown_all
  end

  def test_kill_all_cancels_queued_dependents_and_cascades_to_descendants
    gate = Queue.new
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| gate.pop }
    cfg = Rubik::Config.new
    cfg.set("subagents.max_depth", 4)
    sup = new_supervisor(provider, config: cfg)

    parent = sup.spawn(role: "Parent", prompt: "wait", max_steps: 3)
    child = sup.spawn(role: "Child", prompt: "wait", parent_id: parent.id, max_steps: 3)
    grandchild = sup.spawn(role: "Grandchild", prompt: "wait", parent_id: child.id, max_steps: 3)
    results = sup.spawn_batch([
                                { role: "Root", prompt: "wait", max_steps: 3 },
                                { role: "Dependent", prompt: "never", max_steps: 3, depends_on: ["subagent-4"] },
                                { role: "Transitive", prompt: "never", max_steps: 3, depends_on: ["subagent-5"] }
                              ])
    assert_equal :queued, results[1][0]
    wait_until { child.state == :running && grandchild.state == :running }

    sup.kill_all

    assert grandchild.terminal?, "kill_all must cascade through kill_locked to descendants"
    assert child.terminal?
    assert results[1][1].cancelled?, "kill_all must cancel queued dependents to a fixed point"
    assert results[2][1].cancelled?, "kill_all must cancel transitive dependents"
  ensure
    gate << :release
    sup&.shutdown_all
  end

  def test_archive_reaps_a_missing_transcript_after_bounded_retries
    inst = new_instance
    refute inst.archive!, "first miss keeps the durability gate closed"
    refute inst.archive!, "second miss still retries"
    assert inst.archive!, "third miss reaps with a warning instead of leaking forever"
    assert inst.archived?
  ensure
    inst&.cleanup
  end

  def test_silent_role_matching_is_case_insensitive
    notices = Rubik::Orchestrator::Subagent::Notices
    event = notices::COMPLETED_EVENT

    assert_nil notices.normalize(event, { id: "s1", role: "context pruner", state: "completed" })
    assert_nil notices.normalize(event, { id: "s2", role: "  VAKANÜVIS DISTILLER  ", state: "completed" })
    assert_equal "completed", notices.normalize(event, { id: "s3", role: "Worker", state: "completed" })[:state]
  end

  private

  def new_supervisor(provider, config: nil)
    Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context, event_bus: @bus, root_dir: @ws_root,
      provider: provider, config: config
    )
  end

  def new_instance
    Rubik::Orchestrator::Subagent::Instance.new(
      id: "subagent-archive", parent_id: "agent-0", role: "Archiver",
      type_name: "research", prompt: "work", context: @root_context,
      tool_registry: nil, root_dir: @ws_root
    )
  end
end
