# frozen_string_literal: true

require_relative "../test_helper"

# Pins for the activation seam (architecture review 2026-10-08, Candidate 2):
# spawn and redeploy share ONE birth choreography — the coeffect provides,
# a kernel unit registered BEFORE start_async with a birth state derived
# from instance state (never born dead), and the SS release sweep that a
# redeploy, being a start, now also runs.
class TestSubagentActivation < Minitest::Test
  def setup
    @ws_root = mint_test_root
    @root_context = Rubik::Runtime::Context.new
  end

  def teardown
    @sup&.shutdown_all
    @root_context&.dispose unless @root_context&.disposed?
    remove_temp_dir(@ws_root) if @ws_root
  end

  def new_supervisor(provider: nil, init: nil)
    @sup = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context, root_dir: @ws_root,
      provider: provider || gated_or_done_provider, init: init
    )
  end

  # First call answers immediately (the spawn run completes); every later
  # call parks on the gate until released (the redeploy run stays RUNNING).
  def gated_or_done_provider
    gate = @gate ||= Queue.new
    calls = 0
    provider = Object.new
    provider.define_singleton_method(:complete) do |_h, _o = {}|
      calls += 1
      if calls == 1
        Struct.new(:content, :tool_calls).new("first done", [])
      else
        gate.pop
        Struct.new(:content, :tool_calls).new("second done", [])
      end
    end
    provider
  end

  def fatal_provider
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| raise Rubik::LLM::ClientError, "HTTP 401 Unauthorized" }
    provider
  end

  # Parks the worker mid-turn until the shared gate is released.
  def parked_provider
    gate = @gate ||= Queue.new
    provider = Object.new
    provider.define_singleton_method(:complete) do |_h, _o = {}|
      gate.pop
      Struct.new(:content, :tool_calls).new("done", [])
    end
    provider
  end

  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now >= deadline
    yield
  end

  # ---- the ordering rule: registration precedes start, birth is live ----

  def test_spawn_and_redeploy_units_are_registered_before_start_and_never_born_dead
    init = Rubik::Kernel::Init.new
    registrations = []
    spy = Object.new
    spy.define_singleton_method(:register) do |unit|
      registrations << { unit: unit, state_at_register: unit.instance.state, unit_birth_state: unit.state }
      init.register(unit)
    end
    spy.define_singleton_method(:unregister) { |unit| init.unregister(unit) }
    sup = new_supervisor(init: spy)

    inst = sup.spawn(role: "Born Live", prompt: "first task")
    assert_equal :pending, registrations.dig(0, :state_at_register),
                 "spawn registers the unit BEFORE start_async flips the instance to :running"
    assert(wait_until { inst.terminal_and_settled? })
    first_unit = init.get(inst.id)
    assert_equal :completed, first_unit.state, "kernel board tracks the first run to completion"

    sup.redeploy(inst.id, prompt: "second task")
    live_unit = init.get(inst.id)
    refute_equal first_unit, live_unit, "redeploy mints a FRESH unit"
    assert_equal :completed, registrations.dig(1, :state_at_register),
                 "redeploy registers pre-start, while the prior run is still settled"
    assert_equal :pending, registrations.dig(1, :unit_birth_state),
                 "a settled entry falls back to a live :pending birth — a unit born terminal would freeze the board and let the reaper dispose the live child ctx"
    refute live_unit.dead?

    assert(wait_until { inst.state == :running })
    assert_equal :active, live_unit.state, "start_async's own sync is the single promotion edge (pending -> active)"
  ensure
    @gate << :release
    sup&.shutdown_all
  end

  def test_unit_birth_state_falls_back_to_pending_for_settled_entries
    sup = new_supervisor

    completed = sup.spawn(role: "Settled", prompt: "finish")
    assert(wait_until { completed.terminal_and_settled? })
    assert_equal :pending, sup.send(:unit_birth_state, completed),
                 "STATE_MAP maps :completed to a terminal unit state — the birth must fall back to :pending"

    failed = sup.spawn(role: "Doomed", prompt: "boom", provider: fatal_provider)
    assert(wait_until { failed.terminal_and_settled? && failed.state == :failed })
    assert_equal :pending, sup.send(:unit_birth_state, failed), "failed entries fall back too"

    gate = Queue.new
    running = sup.spawn(role: "Live", prompt: "hold", provider: parked_provider)
    assert(wait_until { running.state == :running })
    assert_equal :active, sup.send(:unit_birth_state, running), "live entries keep their mapped (non-terminal) state"
  ensure
    gate << :release
    sup&.shutdown_all
  end

  # ---- the coeffect half of the seam (thin; heavy e2e lives in
  #      test_subagent_orchestration.rb and must stay green untouched) ----

  def test_activation_provides_asker_and_sender_into_the_fresh_child_ctx
    sup = new_supervisor(provider: parked_provider)
    inst = sup.spawn(role: "Ctx", prompt: "first task")
    assert(wait_until { inst.state == :running })
    assert_equal inst, Rubik::Coeffects.get(inst.context, Rubik::Coeffects::SUBAGENT_QUESTION_ASKER),
                 "spawn provides the asker into the child ctx"
    assert_equal inst.id, Rubik::Coeffects.get(inst.context, Rubik::Coeffects::SUBAGENT_SENDER_ID),
                 "spawn attributes send_message to the real id"

    @gate << :release
    assert(wait_until { inst.terminal_and_settled? })
    sup.redeploy(inst.id, prompt: "second task")
    assert(wait_until { inst.state == :running })
    refute inst.context.disposed?, "redeploy binds a fresh live child context"
    assert_equal inst, Rubik::Coeffects.get(inst.context, Rubik::Coeffects::SUBAGENT_QUESTION_ASKER)
    assert_equal inst.id, Rubik::Coeffects.get(inst.context, Rubik::Coeffects::SUBAGENT_SENDER_ID)
  ensure
    @gate << :release
    sup&.shutdown_all
  end

  # ---- behavior delta 1: a redeploy runs the SS release sweep ----

  def test_redeploy_runs_the_ss_release_sweep
    sup = new_supervisor
    inst = sup.spawn(role: "Swept", prompt: "first task")
    assert(wait_until { inst.terminal_and_settled? })

    sweeps = 0
    sup.define_singleton_method(:release_ready!) do
      sweeps += 1
      super()
    end

    sup.redeploy(inst.id, prompt: "second task")
    assert(wait_until { inst.state == :running })
    assert sweeps >= 1, "redeploy must run the release sweep — SS-queued dependents of the redeployed id release at the first :running flip"
  ensure
    @gate << :release
    sup&.shutdown_all
  end
end
