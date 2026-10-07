# frozen_string_literal: true

require_relative "../test_helper"

# Pins for the unified budget-grant core (Candidate 03): grant_budget!
# owns normalize -> floor -> += -> resume -> note -> broadcast,
# with the terminal-state guard covering BOTH grant paths. States are
# driven by real workers (instant nil-provider completion, gated
# providers, genuine budget parks) or the guarded transition! seam for
# the externally-unholdable kill-race window — never by poking @state.
class TestInstanceGrantBudget < Minitest::Test
  def setup
    @ws_root = mint_test_root
    @root_context = Rubik::Runtime::Context.new
    @live = []
  end

  def teardown
    @live.each(&:kill)
    @root_context.dispose unless @root_context.disposed?
    remove_temp_dir(@ws_root) if @ws_root
  end

  def new_instance(max_steps:, **overrides)
    inst = Rubik::Orchestrator::Subagent::Instance.new(
      id: "subagent-grant", parent_id: "agent-0", role: "Grant Worker",
      type_name: "research", prompt: "Work", context: @root_context,
      tool_registry: nil, max_steps: max_steps, root_dir: @ws_root, **overrides
    )
    @live << inst
    inst
  end

  def wait_until
    deadline = Time.now + 5
    until (value = yield)
      return false if Time.now >= deadline

      sleep 0.02
    end
    value
  end

  # A worker that genuinely parks at its step budget: an always-tool_call
  # provider exhausts max_steps and blocks in the budget condvar until
  # the wait timeout (default here: effectively forever, so :waiting_budget
  # is stable; a short timeout lets the test observe real exhaustion).
  def parked_instance(max_steps: 5, budget_wait_timeout: 180)
    resp = Struct.new(:content, :tool_calls).new("Working", [{ "id" => "c1", "tool" => "dummy", "args" => {} }])
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| resp }
    cfg = Rubik::Config.new
    cfg.set("subagents.budget_wait_timeout", budget_wait_timeout)
    inst = new_instance(max_steps: max_steps, provider: provider, config: cfg)
    inst.start_async
    assert wait_until { inst.awaiting_budget? }, "worker must genuinely reach its budget park"
    inst
  end

  def test_extend_budget_grants_and_notes_history
    inst = parked_instance(max_steps: 5)

    assert_equal true, inst.extend_budget(10)
    assert_equal 15, inst.max_steps

    note = inst.history.find { |m| m[:content]&.include?("Granted 10 additional step(s)") }
    refute_nil note, "history must carry the grant note"
    assert_includes note[:content], "Total budget: 15."

    # The resumed worker steps through its grant and re-parks: a full
    # budget burn proves the resume genuinely happened.
    assert wait_until { inst.state == :waiting_budget }, "worker must burn its grant and re-park"
    assert_equal inst.max_steps, inst.current_step, "re-park means the grant was fully consumed"
  end

  def test_extend_budget_refuses_terminal_states
    inst = new_instance(max_steps: 5)
    inst.start_async
    assert wait_until { inst.terminal_and_settled? }, "nil-provider run must complete and settle"

    assert_equal false, inst.extend_budget(10)
    assert_equal 5, inst.max_steps
    assert_predicate inst, :completed?
  end

  def test_post_message_grants_only_when_waiting_or_steps_attached
    gate = Queue.new
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| gate.pop }
    inst = new_instance(max_steps: 5, provider: provider)
    inst.start_async
    assert wait_until { inst.executing? }, "gated worker must reach its provider call"

    inst.post_message("status ping")
    assert_equal 5, inst.max_steps, "a plain message on a running worker must not grant budget"

    inst.post_message("more work", additional_steps: 5)
    assert_equal 10, inst.max_steps

    note = inst.history.find { |m| m[:content]&.include?("Granted 5 additional step(s) with message") }
    refute_nil note
    assert_includes note[:content], "Total budget: 10."
  ensure
    gate << :release
  end

  def test_dead_instance_must_not_resurrect_via_post_message
    inst = new_instance(max_steps: 5)
    inst.start_async
    assert wait_until { inst.terminal_and_settled? }, "nil-provider run must complete and settle"

    inst.post_message("too late", additional_steps: 10)

    assert_equal 5, inst.max_steps, "a dead instance must not resurrect"
    assert_predicate inst, :completed?
    refute_empty inst.instance_variable_get(:@inbox), "the message itself still lands in the inbox"
  end

  # Issue #55 3.2: the redeploy buffer shares the instance monitor with the
  # reaper's archive!, so a settled-and-clean instance buffers normally,
  # an archived one refuses, and a buffered message never lands post-archive.
  def test_buffer_for_redeploy_gates_on_archival_under_one_lock
    inst = new_instance(max_steps: 5)
    inst.start_async
    assert wait_until { inst.terminal_and_settled? }, "nil-provider run must complete and settle"

    assert inst.buffer_for_redeploy("follow-up steering", sender: "agent-0"),
           "settled-but-unreaped instance accepts the redeploy buffer"
    assert_predicate inst, :pending_redeploy_messages?

    inst.archive!
    refute inst.buffer_for_redeploy("after reap"), "an archived instance must refuse the buffer"
    assert_predicate inst, :pending_redeploy_messages?, "the refusal must not partially push"
  end

  def test_grant_floor_normalizes_non_positive_steps
    [nil, 0, -3].each do |raw|
      inst = parked_instance(max_steps: 5)
      inst.extend_budget(raw)

      assert_equal 25, inst.max_steps, "raw #{raw.inspect} must floor to a 20-step grant"
    end
  end

  def test_extend_budget_refuses_canceling_state_kill_race_window
    inst = new_instance(max_steps: 5)
    # The kill race window is not externally holdable (kill synchronously
    # proceeds to cleanup), so the guarded seam drives exactly this window.
    inst.transition!(:running)
    inst.transition!(:canceling)

    assert_equal false, inst.extend_budget(10)
    assert_equal 5, inst.max_steps
    assert_predicate inst, :canceling?, "a grant must not undo a concurrent kill"
  end

  def test_plain_message_to_paused_worker_grants_default_twenty_and_resumes
    inst = parked_instance(max_steps: 5)

    inst.post_message("nudge")

    assert_equal 25, inst.max_steps, "resuming a paused worker floors to the default 20-step grant"
    # A full budget burn proves the resume genuinely happened.
    assert wait_until { inst.state == :waiting_budget }, "worker must burn its grant and re-park"
    assert_equal inst.max_steps, inst.current_step, "re-park means the grant was fully consumed"
  end

  def test_explicit_zero_steps_floors_to_default_grant
    inst = parked_instance(max_steps: 5)

    inst.post_message("nudge", additional_steps: 0)

    assert_equal 25, inst.max_steps, "additional_steps: 0 is truthy but floors to 20"
    assert wait_until { inst.state == :waiting_budget }, "worker must burn its grant and re-park"
    assert_equal inst.max_steps, inst.current_step, "re-park means the grant was fully consumed"
  end

  def test_extend_budget_resumes_budget_exhausted_state
    inst = parked_instance(max_steps: 5, budget_wait_timeout: 0.05)
    assert wait_until { inst.state == :budget_exhausted }, "worker must genuinely time out its budget wait"

    assert_equal true, inst.extend_budget(10)
    assert_equal 15, inst.max_steps

    # The resumed worker consumes the grant and re-exhausts: a full burn
    # proves the resume genuinely happened.
    assert wait_until { inst.state == :budget_exhausted }, "worker must burn its grant and re-exhaust"
    assert_equal inst.max_steps, inst.current_step, "re-exhaustion means the grant was fully consumed"
  end
end
