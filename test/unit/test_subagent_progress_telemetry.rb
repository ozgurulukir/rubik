# frozen_string_literal: true

require_relative "../test_helper"

# Issue #126: operation-level progress telemetry and actionable wait states.
# Status distinguishes a model wait from tool execution, separates their
# durations with a monotonic clock, and wait reports WHY it returned
# (settled / deadline / pause / queue / unknown).
class TestSubagentProgressTelemetry < Minitest::Test
  OperationTracker = Rubik::Orchestrator::Subagent::OperationTracker

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

  def new_supervisor(provider: nil, registry: nil, buffer_manager: nil)
    @sup = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context, event_bus: @bus, root_dir: @ws_root,
      provider: provider, tool_registry: registry, buffer_manager: buffer_manager
    )
  end

  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.01 until yield || Time.now >= deadline
    yield
  end

  def text_provider(content)
    resp = Struct.new(:content, :tool_calls).new(content, [])
    provider = Object.new
    provider.define_singleton_method(:complete) { |_hist, _opts = {}| resp }
    provider
  end

  # --------------------------------------------------------- tracker core

  def test_tracker_separates_model_and_tool_time_on_an_injected_clock
    now = 100.0
    tracker = OperationTracker.new(clock: -> { now })

    tracker.start(OperationTracker::MODEL, name: "qwen")
    now += 1.5
    assert_in_delta 1.5, tracker.current[:elapsed_seconds], 0.001, "the live operation reports elapsed monotonic time"
    assert_equal "model", tracker.current[:kind]
    now += 0.5
    tracker.finish(OperationTracker::MODEL)

    tracker.start(OperationTracker::TOOL, name: "read_file", detail: "{\"path\":\"a.rb\"}")
    now += 0.25
    tracker.finish(OperationTracker::TOOL)

    timings = tracker.timings
    assert_in_delta 2.0, timings["model_seconds"], 0.001
    assert_in_delta 0.25, timings["tool_seconds"], 0.001
    assert_equal [1, 1], [timings["model_calls"], timings["tool_calls"]]
    assert_nil tracker.current, "an idle execution has no operation"

    now += 3.0
    assert_in_delta 3.0, tracker.last_progress_seconds_ago, 0.001

    tracker.reset!
    assert_nil tracker.current
    assert_nil tracker.last_progress_seconds_ago
    assert_equal 0.0, tracker.timings["model_seconds"], "a redeployed lineage starts clean"
  end

  def test_finish_of_an_untracked_kind_is_a_noop
    tracker = OperationTracker.new
    assert_nil tracker.finish(OperationTracker::TOOL)
  end

  # ------------------------------------------------- slow provider / tool

  def test_slow_provider_exposes_model_wait_and_accumulates_model_time
    provider = Object.new
    provider.define_singleton_method(:complete) do |_h, _o = {}|
      sleep 0.25
      Struct.new(:content, :tool_calls).new("done", [])
    end
    sup = new_supervisor(provider: provider)
    inst = sup.spawn(role: "Waiter", prompt: "think", max_steps: 2)

    assert(wait_until { inst.to_h[:operation] && inst.to_h[:operation][:kind] == "model" },
           "the live model wait must be visible in status")
    op = inst.to_h[:operation]
    assert_operator op[:elapsed_seconds], :>, 0.0
    assert_equal "default", op[:name]
    assert_operator inst.to_h[:last_progress_seconds_ago], :>=, 0.0, "last observable progress is reported"

    assert(wait_until { inst.terminal_and_settled? })
    snapshot = inst.to_h
    assert_nil snapshot[:operation], "a finished run has no in-flight operation"
    assert_operator snapshot[:timings]["model_seconds"], :>=, 0.2, "the model bucket captured the slow call"
    assert_equal 1, snapshot[:timings]["model_calls"]
    # Existing state/pause information is retained alongside the new fields.
    assert_equal "completed", snapshot[:state]
    assert_operator snapshot[:current_step], :>=, 1
    assert_equal 2, snapshot[:max_steps]
  end

  def test_slow_tool_exposes_tool_execution_with_redacted_detail
    slow_tool = Class.new(Rubik::Tools::BaseTool) do
      def execute(_args = {})
        sleep 0.25
        "probe done"
      end
    end.new(Rubik::Tools::Declaration.new(
              name: "slow_probe", description: "slow probe", risk: :read,
              params_schema: { type: "object", properties: { api_key: { type: "string" } } }
            ))
    registry = Rubik::Tools::Registry.new
    registry.register(slow_tool)
    buffer = Rubik::Buffer::Manager.new(root_dir: @ws_root)

    call_count = 0
    resp_tool = Struct.new(:content, :tool_calls).new("Working", [{ "id" => "c1", "tool" => "slow_probe", "args" => { "api_key" => "topsecret-value" } }])
    resp_done = Struct.new(:content, :tool_calls).new("Done", [])
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| (call_count += 1) == 1 ? resp_tool : resp_done }
    sup = new_supervisor(provider: provider, registry: registry, buffer_manager: buffer)
    inst = sup.spawn(role: "Prober", prompt: "probe", type_name: "self", max_steps: 3)

    assert(wait_until { inst.to_h[:operation] && inst.to_h[:operation][:kind] == "tool" },
           "the live tool execution must be visible in status")
    op = inst.to_h[:operation]
    assert_equal "slow_probe", op[:name]
    refute_includes op[:detail].to_s, "topsecret-value", "operation detail is redacted before it reaches status"
    assert_includes op[:detail].to_s, Rubik::Security::Redactor::MASK_STRING
    assert_operator op[:elapsed_seconds], :>, 0.0

    assert(wait_until { inst.terminal_and_settled? })
    snapshot = inst.to_h
    assert_nil snapshot[:operation], "the tool operation clears on completion"
    assert_operator snapshot[:timings]["tool_seconds"], :>=, 0.2, "a slow command shows in the tool bucket"
    assert_equal 1, snapshot[:timings]["tool_calls"]
  end

  # ------------------------------------------------------------ wait reasons

  def test_wait_reports_deadline_while_the_execution_stays_active
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| sleep 5 }
    sup = new_supervisor(provider: provider)
    inst = sup.spawn(role: "Blocked", prompt: "work", max_steps: 2)
    assert(wait_until { inst.state == :running })

    outcome = sup.wait([inst.id], timeout: 1)

    assert_equal :deadline, outcome.reason
    assert_includes outcome.active, inst.id
    assert_equal "running", outcome.rows.first[:state]
    refute outcome.settled?
  end

  def test_wait_reports_settled_for_a_finished_execution
    sup = new_supervisor(provider: text_provider("quick"))
    inst = sup.spawn(role: "Quick", prompt: "work", max_steps: 2)
    assert(wait_until { inst.terminal_and_settled? })

    outcome = sup.wait([inst.id], timeout: 2)
    assert_equal :settled, outcome.reason
    assert_empty outcome.active
  end

  def test_wait_reports_an_actionable_pause
    sup = new_supervisor(provider: always_tool_provider)
    paused = sup.spawn(role: "Budget Paused", prompt: "work", max_steps: 1)
    assert(wait_until { paused.awaiting_budget? }, "the worker parks on its budget")

    outcome = sup.wait([paused.id], timeout: 1)
    assert_equal :paused, outcome.reason
    assert_includes outcome.paused, paused.id
    assert_equal "waiting_budget", outcome.rows.first[:state]
  ensure
    paused&.kill
  end

  def test_wait_reports_a_dependency_queue
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| sleep 5 }
    sup = new_supervisor(provider: provider)
    parent = sup.spawn(role: "Parent", prompt: "work", max_steps: 1)
    assert(wait_until { parent.state == :running })
    dependent = sup.spawn(role: "Dependent", prompt: "later", depends_on: [parent.id])
    assert dependent.queued?

    outcome = sup.wait([dependent.id], timeout: 1)
    assert_equal :queued, outcome.reason
    assert_equal "queued", outcome.rows.first[:state]
  end

  def test_wait_reports_unknown_ids
    sup = new_supervisor
    outcome = sup.wait(["ghost-1"], timeout: 1)
    assert_equal :unknown, outcome.reason
    assert_empty outcome.rows
  end

  def test_wait_surface_renders_the_reason_and_its_actionable_hint
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| sleep 5 }
    sup = new_supervisor(provider: provider)
    inst = sup.spawn(role: "Blocked", prompt: "work", max_steps: 2)
    assert(wait_until { inst.state == :running })
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup, runtime_context: @root_context)

    res = tool.execute("action" => "wait", "conversation_ids" => [inst.id], "timeout" => 1)
    assert_includes res, "wait reason: deadline"
    assert_includes res, "Deadline reached while subagent(s) remain ACTIVE"
    assert_includes res, inst.id
  end

  # ------------------------------------------------------ redeploy reset

  def test_redeploy_clears_the_previous_runs_telemetry
    gate = Queue.new
    gate_provider = Object.new
    gate_provider.define_singleton_method(:complete) { |_h, _o = {}| gate.pop }
    slow = Object.new
    slow.define_singleton_method(:complete) do |_h, _o = {}|
      sleep 0.25
      Struct.new(:content, :tool_calls).new("first", [])
    end
    sup = new_supervisor(provider: gate_provider)

    inst = sup.spawn(role: "Reuser", prompt: "first", max_steps: 2, provider: slow)
    assert(wait_until { inst.terminal_and_settled? })
    assert_operator inst.to_h[:timings]["model_seconds"], :>=, 0.2

    sup.redeploy(inst.id, prompt: "second", max_steps: 2)
    assert(wait_until { inst.run_seq == 2 && inst.to_h[:operation]&.[](:kind) == "model" },
           "the redeployed run tracks its own model wait")

    snapshot = inst.to_h
    assert_equal 0.0, snapshot[:timings]["model_seconds"], "a redeployed lineage starts with empty buckets"
    assert_equal 0, snapshot[:timings]["model_calls"]
  ensure
    gate << Struct.new(:content, :tool_calls).new("second", []) if gate
  end

  private

  def always_tool_provider
    resp = Struct.new(:content, :tool_calls).new("Working", [{ "id" => "c1", "tool" => "dummy", "args" => {} }])
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| resp }
    provider
  end
end
