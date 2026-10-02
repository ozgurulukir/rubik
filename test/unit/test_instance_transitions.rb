# frozen_string_literal: true

require_relative "../test_helper"

# The Instance lifecycle vocabulary: TRANSITIONS is the single home of the
# state machine, transition! its only mutation path, and the predicates the
# only control-flow surface. These pins hold the partitions the migrated
# consumers rely on (supervisor filters, dependency verdicts, reaper sweep).
class TestInstanceTransitions < Minitest::Test
  # Legal chains from :pending to every reachable origin state, so table
  # walks never fabricate state by poking @state.
  PATHS = {
    pending: [].freeze,
    running: [:running].freeze,
    waiting_input: [:running, :waiting_input].freeze,
    waiting_budget: [:running, :waiting_budget].freeze,
    budget_exhausted: [:running, :waiting_budget, :budget_exhausted].freeze,
    paused_error: [:running, :paused_error].freeze,
    canceling: [:running, :canceling].freeze,
    completed: [:running, :completed].freeze,
    failed: [:running, :failed].freeze
  }.freeze

  def setup
    @ws_root = mint_test_root
    @root_context = Rubik::Runtime::Context.new
    @inst = new_instance
  end

  def teardown
    @root_context.dispose unless @root_context.disposed?
    remove_temp_dir(@ws_root) if @ws_root
  end

  def new_instance(**overrides)
    Rubik::Orchestrator::Subagent::Instance.new(id: "subagent-fsm", parent_id: "agent-0", role: "Fsm Worker",
                                                type_name: "research", prompt: "Work", context: @root_context,
                                                tool_registry: nil, root_dir: @ws_root, **overrides)
  end

  def wait_until
    deadline = Time.now + 5
    until (value = yield)
      return false if Time.now >= deadline

      sleep 0.05
    end
    value
  end

  def inst_at(origin)
    inst = new_instance
    PATHS.fetch(origin).each { |step| inst.transition!(step) }
    inst
  end

  def test_instance_is_born_pending_and_deliverable
    assert_equal :pending, @inst.state
    assert_predicate @inst, :pending?
    assert_predicate @inst, :active?
    assert_predicate @inst, :deliverable?
    refute_predicate @inst, :running?
    refute_predicate @inst, :terminal?
    refute_predicate @inst, :parked?
  end

  def test_executing_distinguishes_stepping_from_parked_waits
    @inst.transition!(:running)
    assert_predicate @inst, :executing?
    assert_predicate @inst, :running?

    @inst.transition!(:waiting_budget)
    refute_predicate @inst, :executing?, "a budget-parked worker is not stepping"
    assert_predicate @inst, :running?, "running? deliberately spans the parked waits"

    @inst.transition!(:budget_exhausted)
    refute_predicate @inst, :executing?
    refute_predicate @inst, :running?, "exhaustion is outside running? (active? exclusion pin)"

    @inst.transition!(:running)
    @inst.transition!(:paused_error)
    refute_predicate @inst, :executing?
    assert_predicate @inst, :error_paused?
  end

  def test_awaiting_human_covers_waiting_input_only
    @inst.transition!(:running)
    refute_predicate @inst, :awaiting_human?

    @inst.transition!(:waiting_input)
    assert_predicate @inst, :awaiting_human?
    assert_predicate @inst, :running?, "a question-waiting worker is still mid-flight"

    @inst.transition!(:running)
    refute_predicate @inst, :awaiting_human?
  end

  def test_awaiting_budget_covers_waiting_budget_and_exhausted
    @inst.transition!(:running)
    refute_predicate @inst, :awaiting_budget?

    @inst.transition!(:waiting_budget)
    assert_predicate @inst, :awaiting_budget?
    assert_predicate @inst, :parked?

    @inst.transition!(:budget_exhausted)
    assert_predicate @inst, :awaiting_budget?
    assert_predicate @inst, :parked?
  end

  def test_parked_is_error_paused_or_awaiting_budget
    [:waiting_budget, :budget_exhausted, :paused_error].each do |origin|
      inst = inst_at(origin)
      assert_predicate inst, :parked?, "#{origin} is a resume_all target"
    end

    [:pending, :running, :waiting_input, :completed, :failed].each do |origin|
      inst = inst_at(origin)
      refute_predicate inst, :parked?, "#{origin} is not parkable"
    end
  end

  def test_terminal_states_refuse_grant_resume_and_delivery
    # :completed via the real nil-provider fast path (no @state poking).
    @inst.start_async
    wait_until { @inst.completed? }
    assert_refuses_revival(@inst, deliverable: false)

    # :disposed via the real kill path.
    dead = inst_at(:pending)
    dead.kill
    assert_predicate dead, :disposed?
    assert_refuses_revival(dead, deliverable: false)

    # :canceling through the guarded seam: the kill race window is not
    # externally holdable (kill synchronously proceeds to cleanup), so the
    # seam is the honest driver for exactly this window.
    racing = inst_at(:canceling)
    assert_refuses_revival(racing, deliverable: true)
  end

  def test_settled_states_are_the_redeployable_core
    @inst.start_async
    wait_until { @inst.terminal_and_settled? }
    assert_predicate @inst, :settled?
    assert_predicate @inst, :redeployable?

    # :disposed is terminal but NOT settled — no outcome was recorded and
    # the reaper's tombstone flow (not redeploy) owns it.
    dead = new_instance
    dead.kill
    assert_predicate dead, :terminal?
    refute_predicate dead, :settled?
    refute_predicate dead, :redeployable?
  end

  def test_transition_table_rejects_undeclared_edge
    error = assert_raises(Rubik::Orchestrator::Subagent::Instance::StateError) do
      @inst.transition!(:completed)
    end

    assert_match(/pending -> completed/, error.message, "the message names both endpoints")
    assert_includes error.message, @inst.id
    assert_equal :pending, @inst.state, "a rejected transition must not mutate state"
  end

  def test_transition_to_same_state_is_a_no_op
    @inst.transition!(:running)
    assert_equal :running, @inst.transition!(:running)
    assert_equal :running, @inst.state

    double_killed = inst_at(:canceling)
    assert_equal :canceling, double_killed.transition!(:canceling), "re-kill self-loop is a no-op"
  end

  def test_disposed_absorbs_every_live_state
    Rubik::Orchestrator::Subagent::Instance::TRANSITIONS.each_key do |origin|
      next if origin == :disposed

      inst = inst_at(origin)
      inst.transition!(:disposed)
      assert_predicate inst, :disposed?, "#{origin} must dispose"
      error = assert_raises(Rubik::Orchestrator::Subagent::Instance::StateError) { inst.transition!(:running) }
      assert_match(/disposed -> running/, error.message)
    end
  end

  def test_transition_table_accepts_every_declared_edge
    Rubik::Orchestrator::Subagent::Instance::TRANSITIONS.each do |origin, targets|
      targets.each do |target|
        inst = inst_at(origin)
        assert_equal target, inst.transition!(target), "#{origin} -> #{target} is declared"
      end
    end
  end

  private

  def assert_refuses_revival(inst, deliverable:)
    assert_predicate inst, :terminal?
    assert_equal false, inst.extend_budget(10), "terminal states refuse grants"
    assert_equal false, inst.resume!, "terminal states refuse resume"
    assert_equal deliverable, inst.deliverable?, "deliverable? is active? plus :budget_exhausted (:canceling stays open)"
  end
end
