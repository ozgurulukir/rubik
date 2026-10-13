# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Issue #125: foreground task cancellation propagates to owned subagents.
# A turn publishes a TaskCancellation token; spawns inherit it (transitively),
# detach: true opts out, and ^C stops exactly the owned tree within the
# configured grace period while reporting remaining work explicitly.
class TestTaskCancellation < Minitest::Test
  TaskCancellation = Rubik::Orchestrator::TaskCancellation

  def setup
    @ws_root = mint_test_root
    @root_context = Rubik::Runtime::Context.new
    @bus = Rubik::EventBus.new
    @sup = nil
  end

  def teardown
    @sup&.shutdown_all
    @root_context&.dispose unless @root_context&.disposed?
    remove_temp_dir(@ws_root) if @ws_root && File.directory?(@ws_root)
  end

  def new_supervisor(provider: nil)
    @sup = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context, event_bus: @bus, root_dir: @ws_root, provider: provider
    )
    # Production provides the supervisor into the runtime context (ServiceCatalog);
    # tools resolve it through the child-context chain.
    @root_context.provide(Rubik::Coeffects::SUBAGENT_SUPERVISOR, @sup)
    @sup
  end

  def gate_provider
    gate = Queue.new
    provider = Object.new
    provider.define_singleton_method(:complete) { |_hist, _opts = {}| gate.pop }
    [provider, gate]
  end

  def text_provider(content)
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

  # ------------------------------------------------------------- token leaf

  def test_token_cancellation_is_idempotent_and_records_the_first_reason
    token = TaskCancellation.new
    refute token.cancelled?
    refute token.detached?

    assert token.cancel!("^C")
    refute token.cancel!("second reason"), "the first cancellation wins"
    assert token.cancelled?
    assert_equal "^C", token.reason
    refute_nil token.cancelled_at

    detached = TaskCancellation.detached
    assert detached.detached?
    refute detached.cancel!("^C"), "detached work cannot be cancelled"
    refute detached.cancelled?, "a detached token never cancels"
  end

  # ------------------------------------------------------------ ownership

  def test_spawn_inherits_the_owner_token_into_its_child_context
    token = TaskCancellation.new
    provider, gate = gate_provider
    new_supervisor(provider: provider)
    inst = @sup.spawn(role: "Owned", prompt: "work", owner: token)
    assert_same token, inst.owner_task
    assert_same token, Rubik::Coeffects.get(inst.context, Rubik::Coeffects::TASK_CANCELLATION),
                "the instance's own context carries its task token"

    detached = @sup.spawn(role: "Detached", prompt: "work", owner: nil)
    assert_nil detached.owner_task
    refute_same token, Rubik::Coeffects.get(detached.context, Rubik::Coeffects::TASK_CANCELLATION),
                "a detached spawn gets its own never-cancelled token"
    assert Rubik::Coeffects.get(detached.context, Rubik::Coeffects::TASK_CANCELLATION).detached?
  ensure
    gate << Struct.new(:content, :tool_calls).new("done", []) if gate
  end

  def test_nested_spawn_through_the_rebound_tool_inherits_the_instance_task
    token = TaskCancellation.new
    parent = nil
    nested_result = nil
    spawner = Object.new
    spawner.define_singleton_method(:complete) do |_hist, _opts = {}|
      # The parent's own worker thread performs a nested spawn mid-run: the
      # scoped registry rebinds the tool to the parent's child ctx, so the
      # invoked tool resolves the INSTANCE's task token.
      nested_result ||= Rubik::Tools::InvokeSubagentTool.new(runtime_context: parent.context)
                                                        .execute("role" => "Child", "prompt" => "child work")
      Struct.new(:content, :tool_calls).new("parent done", [])
    end
    sup = new_supervisor(provider: spawner)
    parent = sup.spawn(role: "Parent", prompt: "work", owner: token, max_steps: 2)
    assert(wait_until { nested_result })

    child = sup.instances.values.find { |i| i.role == "Child" }
    refute_nil child, "the nested spawn must succeed: #{nested_result}"
    assert_same token, child.owner_task, "the nested spawn inherits the parent's task ownership"
    assert(wait_until { child.terminal_and_settled? })
  end

  def test_cancel_owned_stops_only_the_owned_tree
    token = TaskCancellation.new
    other = TaskCancellation.new
    provider, gate = gate_provider
    sup = new_supervisor(provider: provider)

    owned = sup.spawn(role: "Owned", prompt: "work", owner: token)
    nested = sup.spawn(role: "Nested", prompt: "work", owner: token, parent_id: owned.id)
    detached = sup.spawn(role: "Detached", prompt: "work", owner: nil)
    unrelated = sup.spawn(role: "Unrelated", prompt: "work", owner: other)
    assert(wait_until { [owned, nested, detached, unrelated].all? { |i| i.state == :running } })

    outcome = sup.cancel_owned(token, timeout: 2.0)

    assert outcome.cancelled
    assert_includes outcome.stopped, owned.id
    assert_includes outcome.stopped, nested.id
    assert outcome.complete?, "nothing owned is left winding down: #{outcome.remaining.inspect}"
    assert_equal :disposed, owned.state
    assert_equal :disposed, nested.state
    refute_includes outcome.stopped, detached.id
    refute_includes outcome.stopped, unrelated.id
    assert_equal :running, detached.state, "explicitly detached work survives"
    assert_equal :running, unrelated.state, "another task's work survives"
  ensure
    gate << Struct.new(:content, :tool_calls).new("done", []) if gate
  end

  def test_cancel_owned_reports_remaining_work_when_cleanup_does_not_complete
    token = TaskCancellation.new
    new_supervisor
    stuck = Object.new
    def stuck.owner_task = @token
    def stuck.terminal_and_settled? = false
    def stuck.active? = true
    def stuck.kill = true
    def stuck.state = :canceling
    def stuck.id = "subagent-stuck"
    stuck.instance_variable_set(:@token, token)
    @sup.instances["subagent-stuck"] = stuck

    outcome = @sup.cancel_owned(token, timeout: 0.05)

    refute outcome.complete?, "an unsettled execution must be reported, not hidden"
    assert_equal [{ id: "subagent-stuck", state: "canceling" }], outcome.remaining
  end

  def test_queued_specs_of_a_cancelled_task_never_start
    token = TaskCancellation.new
    provider, gate = gate_provider
    sup = new_supervisor(provider: provider)
    parent = sup.spawn(role: "Parent", prompt: "blocks", owner: token, max_steps: 1)
    assert(wait_until { parent.state == :running })

    dependent = sup.spawn(role: "Dependent", prompt: "later", owner: token, depends_on: [parent.id])
    assert dependent.respond_to?(:queued?) && dependent.queued?, "precondition: the dependent is queued"

    outcome = sup.cancel_owned(token, timeout: 0.2)

    assert_includes outcome.queued_cancelled, dependent.id
    assert dependent.cancelled?, "a queued spec of the cancelled task is cancelled, never launched"
    assert_nil sup.instances[dependent.id], "it never became an instance"
  ensure
    gate << Struct.new(:content, :tool_calls).new("done", []) if gate
  end

  def test_new_owned_work_is_refused_after_cancellation_and_detached_work_gets_through
    token = TaskCancellation.new
    token.cancel!("^C")
    sup = new_supervisor

    error = assert_raises(Rubik::Orchestrator::Subagent::TaskCancelledError) do
      sup.spawn(role: "Late", prompt: "too late", owner: token)
    end
    assert_includes error.message, "cancelled"
    assert_includes error.message, "detach: true"

    error = assert_raises(Rubik::Orchestrator::Subagent::TaskCancelledError) do
      sup.spawn_batch([{ role: "Late", prompt: "too late" }], owner: token)
    end
    assert_includes error.message, "new owned work is refused"

    detached = sup.spawn(role: "Detached", prompt: "independent", owner: nil)
    assert detached
  end

  # ---------------------------------------------- one outcome per execution

  def test_operator_kill_announces_cancellation_exactly_once
    events = []
    @bus.subscribe(Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT) { |payload| events << payload }
    provider, gate = gate_provider
    sup = new_supervisor(provider: provider)
    inst = sup.spawn(role: "Doomed", prompt: "work")
    assert(wait_until { inst.state == :running })

    sup.kill(inst.id)
    assert(wait_until { events.any? { |p| p[:id] == inst.id } })
    assert(wait_until { inst.terminal_and_settled? || inst.disposed? })
    sleep 0.05

    terminal = events.select { |p| p[:id] == inst.id }
    assert_equal 1, terminal.size, "one terminal outcome per execution (no duplicate settle notice)"
    assert_equal :cancelled, terminal.first[:state]

    # The completion choreography must honor the cancellation: the guidance for
    # a cancelled execution is not a result-retrieval hint.
    notice = Rubik::Orchestrator::Subagent::Notices.normalize(
      Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT, terminal.first
    )
    assert_includes Rubik::Orchestrator::Subagent::Notices.guidance_for(notice), "cancelled"
    refute_includes Rubik::Orchestrator::Subagent::Notices.guidance_for(notice), "Retrieve the full result"
  ensure
    gate << Struct.new(:content, :tool_calls).new("done", []) if gate
  end

  def test_kill_after_settlement_does_not_add_a_second_outcome
    events = []
    @bus.subscribe(Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT) { |payload| events << payload }
    sup = new_supervisor(provider: text_provider("finished"))
    inst = sup.spawn(role: "Settled", prompt: "work", max_steps: 2)
    assert(wait_until { inst.terminal_and_settled? })

    sup.kill(inst.id)
    sleep 0.05

    terminal = events.select { |p| p[:id] == inst.id }
    assert_equal 1, terminal.size
    assert_equal "completed", terminal.first[:state].to_s, "the settled outcome stands; the kill adds none"
  end

  # -------------------------------------------------- cleanup once, LIFO

  def test_owned_cleanup_runs_once_in_lifo_order_and_survives_a_failing_inverse
    order = []
    token = TaskCancellation.new
    provider, gate = gate_provider
    sup = new_supervisor(provider: provider)
    inst = sup.spawn(role: "Cleanup", prompt: "work", owner: token)
    assert(wait_until { inst.state == :running })

    inst.context.register_disposable { order << :first }
    inst.context.register_disposable do
      order << :boom
      raise "inverse failure"
    end
    inst.context.register_disposable { order << :last }

    sup.cancel_owned(token, timeout: 1.0)

    assert_equal [:last, :boom, :first], order, "LIFO order, and the failing inverse never stops the drain"
    assert inst.context.disposed?
    assert_equal 0, inst.context.disposable_count, "cleanup ran to completion exactly once"
  ensure
    gate << Struct.new(:content, :tool_calls).new("done", []) if gate
  end

  # ------------------------------------------------------------- UI facts

  def test_ui_distinguishes_an_interrupted_wait_from_a_cancelled_task_tree
    shell = Rubik::REPL::Shell.new(config: Rubik::Config.new(root_dir: @ws_root), output: StringIO.new, root_dir: @ws_root)
    wait_lines = shell.send(:task_cancellation_lines, nil)
    assert_includes wait_lines.first, "Bekleme kesildi"
    refute_includes wait_lines.first, "Görev ağacı"

    outcome = Rubik::Orchestrator::Subagent::TaskOwnershipSupervisor::CancellationOutcome.new(
      cancelled: true, stopped: ["subagent-1", "subagent-2"], remaining: [], queued_cancelled: []
    )
    lines = shell.send(:task_cancellation_lines, outcome)
    assert_includes lines.first, "Görev ağacı iptal edildi"
    assert_includes lines.first, "2 bağlı alt ajan durduruldu"
    assert_includes lines.first, "temizlik tamamlandı"

    stuck = Rubik::Orchestrator::Subagent::TaskOwnershipSupervisor::CancellationOutcome.new(
      cancelled: true, stopped: ["subagent-1"], remaining: [{ id: "subagent-2", state: "canceling" }],
      queued_cancelled: ["subagent-3"]
    )
    lines = shell.send(:task_cancellation_lines, stuck)
    assert_includes lines.first, "temizlik TAMAMLANMADI"
    assert_includes lines.first, "subagent-2:canceling"
    assert_includes lines.first, "1 kuyruk işi iptal edildi"
  ensure
    shell&.stop
  end
end
