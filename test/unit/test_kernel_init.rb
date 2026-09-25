# frozen_string_literal: true

require_relative "../test_helper"

class TestKernelInit < Minitest::Test
  def setup
    @dmesg = Rubik::Kernel::Dmesg.new
    @dispatcher = Rubik::Kernel::Dispatcher.new(dmesg: @dmesg)
    @parent_ctx = Rubik::Runtime::Context.new
    @init = Rubik::Kernel::Init.new(context: @parent_ctx, dmesg: @dmesg, dispatcher: @dispatcher)
  end

  def teardown
    @init.stop
    @dispatcher.stop
    @parent_ctx.dispose unless @parent_ctx.disposed?
  end

  def test_unit_state_machine_valid_transitions_and_dmesg_telemetry
    unit = Rubik::Kernel::Unit.new(id: "test-u1", type: :task, dmesg: @dmesg, dispatcher: @dispatcher)
    assert_equal :pending, unit.state
    assert unit.pending?
    assert_nil unit.started_at
    assert_nil unit.finished_at

    unit.transition_to!(:active)
    assert_equal :active, unit.state
    assert unit.active?
    assert unit.running?
    refute_nil unit.started_at

    unit.transition_to!(:paused_error, reason: "network timeout")
    assert_equal :paused_error, unit.state
    assert unit.paused?
    assert_equal "network timeout", unit.reason

    unit.transition_to!(:active, reason: "retried")
    assert_equal :active, unit.state
    assert unit.active?

    unit.transition_to!(:completed, reason: "done")
    assert_equal :completed, unit.state
    assert unit.dead?
    refute_nil unit.finished_at

    unit.transition_to!(:reaped)
    assert_equal :reaped, unit.state
    assert unit.reaped?

    # Verify Dmesg logging
    records = @dmesg.tail(10, subsystem: :kernel)
    assert_operator records.size, :>=, 5
    transitions = records.map(&:message).select { |m| m.include?("test-u1 state transition") }
    assert_equal 5, transitions.size
  end

  def test_unit_state_machine_invalid_transitions_raise_error
    unit = Rubik::Kernel::Unit.new(id: "test-u2", type: :task)
    unit.transition_to!(:active)
    unit.transition_to!(:completed)

    # Completed unit can only transition to :reaped
    assert_raises(Rubik::Kernel::Unit::StateError) do
      unit.transition_to!(:active)
    end

    unit.transition_to!(:reaped)

    # Reaped unit cannot transition to anything
    assert_raises(Rubik::Kernel::Unit::StateError) do
      unit.transition_to!(:active)
    end

    assert_raises(ArgumentError) do
      unit.transition_to!(:invalid_state)
    end
  end

  def test_dispatcher_receives_unit_state_changed_events
    events = []
    @dispatcher.subscribe(:unit_state_changed) { |payload| events << payload }

    unit = Rubik::Kernel::Unit.new(id: "disp-1", type: :subagent, dispatcher: @dispatcher)
    unit.transition_to!(:active)
    unit.transition_to!(:failed, reason: "budget exhausted")

    @dispatcher.sync_drain(1.0)

    assert_equal 2, events.size
    assert_equal "disp-1", events[0][:unit_id]
    assert_equal :pending, events[0][:from_state]
    assert_equal :active, events[0][:to_state]

    assert_equal "disp-1", events[1][:unit_id]
    assert_equal :active, events[1][:from_state]
    assert_equal :failed, events[1][:to_state]
    assert_equal "budget exhausted", events[1][:reason]
  end

  def test_init_manages_concurrent_process_and_subagent_units
    mock_task = Struct.new(:id, :status, :started_at, :ended_at).new("task-10", :running, Time.now, nil)
    mock_inst = Struct.new(:id, :state, :started_at, :ended_at, :context).new("subagent-20", :running, Time.now, nil, nil)

    proc_unit = Rubik::Kernel::ProcessUnit.new(mock_task)
    sub_unit = Rubik::Kernel::SubagentUnit.new(mock_inst)

    @init.register(proc_unit)
    @init.register(sub_unit)

    assert_equal 2, @init.size
    assert_same proc_unit, @init.get("task-10")
    assert_same sub_unit, @init["subagent-20"]

    active_units = @init.units_by_state(:active)
    assert_equal 2, active_units.size

    # Synchronize state when underlying child tasks complete
    mock_task.status = :completed
    mock_task.ended_at = Time.now
    mock_inst.state = :completed
    mock_inst.ended_at = Time.now

    completed_units = @init.units_by_state(:completed)
    assert_equal 2, completed_units.size
  end

  def test_init_zombie_reaping_and_subcontext_disposal
    sub_ctx1 = @parent_ctx.extend
    sub_ctx2 = @parent_ctx.extend

    u1 = Rubik::Kernel::Unit.new(id: "unit-z1", type: :process, context: sub_ctx1)
    u2 = Rubik::Kernel::Unit.new(id: "unit-z2", type: :subagent, context: sub_ctx2)

    @init.register(u1)
    @init.register(u2)

    u1.transition_to!(:active)
    u2.transition_to!(:active)

    u1.transition_to!(:completed)
    u2.transition_to!(:failed, reason: "syntax error")

    refute sub_ctx1.disposed?
    refute sub_ctx2.disposed?

    reaped = @init.reap_dead_units!

    assert_equal 2, reaped.size
    assert_equal :reaped, u1.state
    assert_equal :reaped, u2.state
    assert sub_ctx1.disposed?
    assert sub_ctx2.disposed?

    # Second reaping run reaps nothing
    assert_empty @init.reap_dead_units!
  end

  def test_init_resume_all_recovers_paused_units
    u1 = Rubik::Kernel::Unit.new(id: "paused-1", type: :subagent, state: :paused_error)
    u2 = Rubik::Kernel::Unit.new(id: "paused-2", type: :subagent, state: :waiting_budget)
    u3 = Rubik::Kernel::Unit.new(id: "active-3", type: :process, state: :active)

    @init.register(u1)
    @init.register(u2)
    @init.register(u3)

    assert_equal 2, @init.units_by_state(:paused_error, :waiting_budget).size

    resumed = @init.resume_all
    assert_equal 2, resumed.size
    assert_equal :active, u1.state
    assert_equal :active, u2.state
    assert_equal :active, u3.state
  end

  def test_init_kill_and_kill_all_lifo_order
    order_killed = []

    u1 = Rubik::Kernel::Unit.new(id: "u-1", type: :task, state: :active)
    u2 = Rubik::Kernel::Unit.new(id: "u-2", type: :task, state: :active)
    u3 = Rubik::Kernel::Unit.new(id: "u-3", type: :task, state: :active)

    [u1, u2, u3].each do |u|
      u.define_singleton_method(:kill) do |reason = "killed"|
        order_killed << id
        transition_to!(:failed, reason: reason)
      end
      @init.register(u)
    end

    @init.kill("u-2")
    assert_equal ["u-2"], order_killed
    assert_equal :failed, u2.state

    order_killed.clear
    @init.kill_all

    # LIFO: u3 then u1 (u2 is already failed, so won't be killed again or is handled)
    assert_equal ["u-3", "u-1"], order_killed
  end

  def test_context_disposal_cascades_lifo_shutdown_on_init
    order_killed = []

    ctx = Rubik::Runtime::Context.new
    init = Rubik::Kernel::Init.new(context: ctx, dmesg: @dmesg)

    u1 = Rubik::Kernel::Unit.new(id: "c-1", type: :process, state: :active, context: ctx.extend)
    u2 = Rubik::Kernel::Unit.new(id: "c-2", type: :subagent, state: :active, context: ctx.extend)

    [u1, u2].each do |u|
      u.define_singleton_method(:kill) do |reason = "killed"|
        order_killed << id
        transition_to!(:failed, reason: reason)
      end
      init.register(u)
    end

    refute init.stopped?

    ctx.dispose

    assert init.stopped?
    assert_equal ["c-2", "c-1"], order_killed # LIFO
    assert_equal :reaped, u1.state
    assert_equal :reaped, u2.state
    assert u1.context.disposed?
    assert u2.context.disposed?
  end

  def test_task_manager_and_supervisor_register_units_with_init
    init = Rubik::Kernel::Init.new(context: @parent_ctx, dmesg: @dmesg)

    tm = Rubik::Runtime::TaskManager.new(context: @parent_ctx, init: init)
    assert_same init, tm.init

    sub_ctx = @parent_ctx.extend
    task = tm.start("echo hello", ctx: sub_ctx)
    unit = init.get(task.id)

    refute_nil unit
    assert_equal :process, unit.type
    assert_equal task.id, unit.id
  end
end
