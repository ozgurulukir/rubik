# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestKernelConsolidation < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_test_p107")
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
  end

  # =========================================================================
  # Faz A: ServiceCatalog Construction Order & Single Dispatcher Thread
  # =========================================================================

  def test_service_catalog_build_wires_dispatcher_directly_into_event_bus
    scope = Rubik::REPL::ServiceCatalog::Scope.new(root_dir: @temp_dir, overrides: {})
    built = Rubik::REPL::ServiceCatalog.build(scope)

    event_bus = built.fetch(:event_bus)
    dispatcher = built.fetch(:dispatcher)
    dmesg = built.fetch(:dmesg)

    assert_same dispatcher, event_bus.dispatcher, "EventBus must be directly constructed with the real dispatcher"
    assert_same dmesg, dispatcher.dmesg, "Dispatcher must be wired with the Dmesg instance"
    assert dispatcher.worker_alive?, "Dispatcher worker thread must be alive"

    built.fetch(:runtime_manager).context.dispose
    refute dispatcher.alive?, "Dispatcher must stop cleanly on context dispose"
  end

  # =========================================================================
  # Faz B: SubagentUnit Live State Synchronization & Telemetry
  # =========================================================================

  def test_subagent_unit_live_state_synchronization_and_dmesg_logging
    dmesg = Rubik::Kernel::Dmesg.new
    dispatcher = Rubik::Kernel::Dispatcher.new(dmesg: dmesg)
    init = Rubik::Kernel::Init.new(dmesg: dmesg, dispatcher: dispatcher)

    inst = Rubik::Orchestrator::Subagent::Instance.new(
      id: "subagent-test-1",
      parent_id: "agent-0",
      role: "Tester",
      type_name: "research",
      prompt: "Perform unit test verification",
      context: nil,
      tool_registry: nil,
      root_dir: @temp_dir
    )

    unit = Rubik::Kernel::SubagentUnit.new(inst, dmesg: dmesg, dispatcher: dispatcher)
    init.register(unit)

    assert_equal :pending, unit.state
    assert_same unit, inst.unit, "Instance should have a back-reference to its SubagentUnit"

    # Simulate transition to running
    inst.instance_variable_set(:@state, :running)
    inst.unit.sync_state!
    assert_equal :active, unit.state

    # Verify Dmesg contains transition record
    records = dmesg.tail(10, subsystem: :kernel)
    transition_record = records.find { |r| r.message.include?("pending -> active") }
    refute_nil transition_record, "Dmesg must record the pending -> active state transition"

    # Simulate budget exhaustion
    inst.instance_variable_set(:@state, :budget_exhausted)
    inst.unit.sync_state!
    assert_equal :budget_exhausted, unit.state

    # Simulate completion
    inst.instance_variable_set(:@state, :completed)
    inst.unit.sync_state!
    assert_equal :completed, unit.state
    assert unit.dead?

    dispatcher.stop
  end

  # =========================================================================
  # Faz C: Turn-Boundary Zombie Reaping
  # =========================================================================

  def test_turn_boundary_reaps_completed_and_failed_units
    dmesg = Rubik::Kernel::Dmesg.new
    init = Rubik::Kernel::Init.new(dmesg: dmesg)

    ctx1 = Rubik::Runtime::Context.new
    ctx1_disposed = false
    ctx1.on_dispose { ctx1_disposed = true }

    unit1 = Rubik::Kernel::Unit.new(id: "task-1", type: :task, context: ctx1, state: :completed)
    init.register(unit1)

    ctx2 = Rubik::Runtime::Context.new
    ctx2_disposed = false
    ctx2.on_dispose { ctx2_disposed = true }

    unit2 = Rubik::Kernel::Unit.new(id: "task-2", type: :task, context: ctx2, state: :active)
    init.register(unit2)

    reaped = init.reap_dead_units!
    assert_equal 1, reaped.size
    assert_equal "task-1", reaped.first.id
    assert_equal :reaped, unit1.state
    assert ctx1_disposed, "Completed unit context must be disposed upon reap"

    refute ctx2_disposed, "Active unit context must not be disposed"
    assert_equal :active, unit2.state
  end

  # =========================================================================
  # Faz D: ProcessUnit Completion Notification Injection
  # =========================================================================

  def test_handle_unit_event_injects_into_active_loop_or_history
    shell = Object.new
    history = []
    active_loop_notices = []

    mock_loop = Object.new
    mock_loop.define_singleton_method(:enqueue_subagent_notice) { |n| active_loop_notices << n }

    # Setup minimal shell state for lifecycle
    shell.instance_variable_set(:@running, true)
    shell.instance_variable_set(:@output, StringIO.new)
    shell.instance_variable_set(:@replaying, false)
    shell.instance_variable_set(:@conversation_history, history)
    shell.instance_variable_set(:@active_loop, mock_loop)
    shell.instance_variable_set(:@subagent_notices_mutex, Mutex.new)
    shell.instance_variable_set(:@subagent_notices, [])

    # Include Lifecycle methods into shell
    shell.extend(Rubik::REPL::Lifecycle)

    # 1. With active loop: notice enqueued into loop
    payload = { type: :process, unit_id: "task-42", to_state: :completed, reason: "exit 0" }
    shell.handle_unit_event(payload)

    assert_equal 1, active_loop_notices.size
    notice = active_loop_notices.first
    assert_equal :task, notice[:kind]
    assert_equal "task-42", notice[:id]
    assert_equal "completed", notice[:state]

    # 2. Without active loop: notice injected into conversation history
    shell.instance_variable_set(:@active_loop, nil)
    payload2 = { type: :task, unit_id: "task-99", to_state: :failed, reason: "exit 1" }
    shell.handle_unit_event(payload2)

    refute_empty history, "Conversation history must receive task notification when no active loop is present"
    last_turn = history.last
    assert_equal "user", last_turn[:role]
    assert_includes last_turn[:content], "task-99"
    assert_includes last_turn[:content], "failed"
  end
end
