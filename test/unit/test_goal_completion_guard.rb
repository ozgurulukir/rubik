# frozen_string_literal: true

require_relative "../test_helper"

# Goal-mode premature-completion guard (GoalWait; maestro lifecycle round
# 4). Field incident 2026-10-05: `!goal` printed "Goal Achieved in 3
# steps" after the maestro dispatched a subagent and concluded with plain
# text — the run ended with ok:true while the subagent was still RUNNING.
# These scenarios pin the corrected mechanics: in goal mode a text-only
# conclusion or a finish call over live subagents becomes a bounded
# wait + notice injection + continuation, never a success terminal.
class TestGoalCompletionGuard < Minitest::Test
  include Rubik::TestSupport::TurnScenarioHarness

  # The guard reads active_count and blocks in wait_for; the block hook
  # simulates what the real runtime does while waiting (units settle,
  # notices route into the loop inbox via repl/lifecycle.rb). The ignored
  # root_dir kwarg satisfies the architectural guard: every
  # Supervisor-shaped test construction names an explicit root.
  class FakeSupervisor
    attr_accessor :active_count
    attr_reader :wait_calls

    def initialize(active_count:, root_dir: nil)
      @active_count = active_count
      @root_dir = root_dir
      @wait_calls = []
      @on_wait = nil
    end

    def on_wait(&blk)
      @on_wait = blk
    end

    def wait_for(_ids = nil, timeout: 300, **)
      @wait_calls << timeout
      @on_wait&.call
      []
    end
  end

  # Loop extends a disposable per-run child context; a plain disposable
  # double keeps Kernel#extend out of the way.
  class ChildCtx
    def dispose; end
  end

  SupervisorCtx = Struct.new(:supervisor) do
    def get(key)
      key == Rubik::Coeffects::SUBAGENT_SUPERVISOR ? supervisor : nil
    end

    def extend
      ChildCtx.new
    end
  end

  RuntimeWithCtx = Struct.new(:ctx) do
    def context = ctx
  end

  def setup
    @ws_root = mint_test_root
  end

  def teardown
    remove_temp_dir(@ws_root) if @ws_root
  end

  def test_incident_shape_text_conclusion_with_live_subagent_waits_for_notices
    sup = FakeSupervisor.new(active_count: 1, root_dir: @ws_root)
    events = []
    loop = build_goal_loop(supervisor: sup, responses: [
                             Rubik::LLM::Response.new(text: "The research stage is running in the background. I'll act on the completion notification."),
                             Rubik::LLM::Response.new(text: '{"tool": "finish", "args": {"message": "goal verified and complete"}}')
                           ], on_step: ->(e) { events << e })
    sup.on_wait do
      sup.active_count = 0
      loop.enqueue_subagent_notice(kind: :completed, id: "subagent-1", role: "PR inventory and review",
                                   state: "completed", max_steps: 20)
    end

    res = loop.run("review the open PRs and merge", goal_mode: true)

    assert res[:ok], "completes only after the notice-driven finish turn"
    assert_equal 2, res[:steps], "the implicit wait burns no step: one conclusion turn + one finish turn"
    assert_equal [300], sup.wait_calls, "one bounded wait on the default agent.goal_wait_timeout"

    wait_event = events.find { |e| e[:type] == :goal_wait }
    refute_nil wait_event, "the wait is announced on the on_step channel"
    assert_equal 1, wait_event[:active]
    assert_equal "text", wait_event[:via]

    notice_row = loop.history.reverse.find { |m| m[:role] == "user" && m[:content].to_s.include?("subagent-1") }
    refute_nil notice_row, "the completion notice is drained into history for the model's next turn"
  end

  def test_finish_over_live_subagent_is_converted_to_a_wait
    sup = FakeSupervisor.new(active_count: 1, root_dir: @ws_root)
    events = []
    loop = build_goal_loop(supervisor: sup, responses: [
                             Rubik::LLM::Response.new(text: '{"tool": "finish", "args": {"message": "premature conclusion"}}'),
                             Rubik::LLM::Response.new(text: "all dispatched work has settled; the goal is met")
                           ], on_step: ->(e) { events << e })
    sup.on_wait { sup.active_count = 0 } # settles silently: no notice ever routes

    res = loop.run("fix the failing suite", goal_mode: true)

    assert res[:ok], "the guarded run still ends successfully through a later terminal"
    assert_equal "finish", events.find { |e| e[:type] == :goal_wait }[:via],
                 "the finish interception is attributed to the finish path"
    refute events.any? { |e| e[:type] == :finish },
           "handle_finish_tool must never run over live subagents (no premature auto-apply/finish event)"

    # Reviewer fix: the deferred finish still needs its canonical tool-result
    # row — the loop continues, so the next provider request must see the
    # tool_use paired (strict providers 400 on orphaned ids).
    deferred_rows = loop.history.select { |m| m[:role] == "tool" && m[:tool_name] == "finish" }
    assert_equal 1, deferred_rows.size, "exactly one deferred-finish result row"
    assert_equal Rubik::Orchestrator::ToolHistory::ROW_KEYS, deferred_rows.first.keys
    assert_includes deferred_rows.first[:content], "deferred"
    assert deferred_rows.first[:tool_call_id].to_s.start_with?("call_"),
           "the row pairs with the finish tool_use id minted for the assistant row"

    settled = loop.history.find { |m| m[:role] == "user" && m[:content].to_s.include?("goal_wait_settled") }
    refute_nil settled, "silent settlement nudges the model to conclude deliberately"
  end

  def test_timeout_with_still_live_subagents_holds_the_goal_open
    sup = FakeSupervisor.new(active_count: 1, root_dir: @ws_root)
    config = { "agent.goal_wait_timeout" => 0 } # no blocking in test: every wait nudges immediately
    events = []
    settle_before_finish_step = lambda { |e|
      events << e
      sup.active_count = 0 if e[:type] == :thinking && e[:step] == 3
    }
    loop = build_goal_loop(supervisor: sup, config: config, responses: [
                             Rubik::LLM::Response.new(text: "dispatched the fix stage, waiting"),
                             Rubik::LLM::Response.new(text: "still waiting on the fix stage"),
                             Rubik::LLM::Response.new(text: '{"tool": "finish", "args": {"message": "done"}}')
                           ], on_step: settle_before_finish_step)

    res = loop.run("goal with a long-running stage", goal_mode: true)

    assert res[:ok], "completes once the stage settles and finish passes the guard"
    assert_empty sup.wait_calls, "a zero timeout must skip the blocking wait entirely"
    nudges = loop.history.count { |m| m[:role] == "user" && m[:content].to_s.include?("goal_wait_timeout") }
    assert_equal 2, nudges, "each premature conclusion over live units injects exactly one still-waiting nudge"
    assert_includes loop.history.find { |m| m[:content].to_s.include?("goal_wait_timeout") }[:content],
                    "NOT complete while they run"
  end

  def test_default_mode_text_conclusion_still_completes_immediately
    sup = FakeSupervisor.new(active_count: 3, root_dir: @ws_root)
    loop = build_goal_loop(supervisor: sup, responses: [Rubik::LLM::Response.new(text: "direct answer for the user")])

    res = loop.run("interactive question") # no goal_mode

    assert res[:ok], "interactive semantics are untouched by the guard"
    assert_equal 1, res[:steps]
    assert_empty sup.wait_calls, "the supervisor is never consulted outside goal mode"
  end

  def test_goal_mode_without_subagent_system_completes_normally
    loop = build_goal_loop(supervisor: nil, responses: [Rubik::LLM::Response.new(text: "solo goal, no subagents")])

    res = loop.run("tiny goal", goal_mode: true)

    assert res[:ok], "a nil supervisor (bare loop) makes the guard inert"
    assert_equal 1, res[:steps]
  end

  def test_goal_mode_flag_is_per_run
    loop = build_goal_loop(supervisor: nil, responses: [Rubik::LLM::Response.new(text: "a"), Rubik::LLM::Response.new(text: "b")])

    refute loop.goal_mode?, "fresh loops default to interactive semantics"
    loop.run("goal attempt", goal_mode: true)
    assert loop.goal_mode?, "the flag survives the run (continue_loop resumes it)"
    loop.run("follow-up interactive task")
    refute loop.goal_mode?, "a later run on the same instance must not inherit the flag"
  end

  def test_notice_inbox_empty_probe
    inbox = Rubik::Orchestrator::SubagentNoticeInbox.new
    assert inbox.empty?
    inbox.enqueue(kind: :message, id: "subagent-1")
    refute inbox.empty?
    assert_equal 1, inbox.drain_all.size
    assert inbox.empty?
  end

  def test_drain_returns_the_notices_array
    loop = build_goal_loop(supervisor: nil, responses: [])
    assert_equal [], loop.drain_subagent_notices_into_history!, "empty drain returns the (empty) array"
    loop.enqueue_subagent_notice(kind: :completed, id: "s1", role: "R", state: "completed", max_steps: 5)
    drained = loop.drain_subagent_notices_into_history!
    assert_equal 1, drained.size
    assert(loop.history.any? { |m| m[:role] == "user" && m[:content].to_s.include?("s1") })
  end

  def test_goal_wait_event_renders_a_user_visible_line
    formatter = Rubik::REPL::StepFormatter.new(verbosity: "normal")
    line = formatter.format(type: :goal_wait, active: 2, timeout: 300)
    assert_includes line, "2 subagent(s) still active"
    assert_includes line, "goal held open"
  end

  def test_repl_defense_counts_active_subagents_through_the_coeffect
    sup = FakeSupervisor.new(active_count: 2, root_dir: @ws_root)
    ctx = Struct.new(:runtime_manager).new(RuntimeWithCtx.new(SupervisorCtx.new(sup)))
    assert_equal 2, Rubik::REPL::Commands::AgentExecution.send(:goal_active_subagent_count, ctx)

    assert_equal 0, Rubik::REPL::Commands::AgentExecution.send(:goal_active_subagent_count, Struct.new(:runtime_manager).new(nil)),
                 "no runtime manager => nothing pending (nil-safe absence, not an error)"
    assert_equal 1, Rubik::REPL::Commands::AgentExecution.send(:goal_active_subagent_count, Object.new),
                 "an uninspectable ctx fails CONSERVATIVE (refuses completion), never a false zero"
  end

  def test_wait_timeout_rejects_non_numeric_config_without_disabling_the_wait
    garbage = Object.new
    garbage.define_singleton_method(:safe_config) { |key, _default| key == "agent.goal_wait_timeout" ? "5min" : 300 }
    assert_equal 300, Rubik::Orchestrator::GoalWait.new(Rubik::Orchestrator::ShellDeps.wrap(garbage)).send(:wait_timeout),
                 "garbage must not degrade to a zero wait"

    zero = Object.new
    zero.define_singleton_method(:safe_config) { |key, default| key == "agent.goal_wait_timeout" ? "0" : default }
    assert_equal 0, Rubik::Orchestrator::GoalWait.new(Rubik::Orchestrator::ShellDeps.wrap(zero)).send(:wait_timeout),
                 "an explicit zero (no blocking wait) is honored"
  end

  private

  def build_goal_loop(supervisor:, responses:, config: {}, on_step: nil)
    buffer = Rubik::Buffer::Manager.new(root_dir: @ws_root)
    runtime = supervisor ? RuntimeWithCtx.new(SupervisorCtx.new(supervisor)) : nil
    shell = Struct.new(:buffer_manager, :snapshot_store, :context_index, :lsp_manager, :config, :runtime_manager, :commands).new(
      buffer, nil, nil, nil, config.merge("llm.stream" => false), runtime, nil
    )
    Rubik::Orchestrator::Loop.new(
      provider: ScriptedTurnProvider.new(responses),
      tool_registry: default_registry(buffer),
      max_steps: 6,
      on_step: on_step,
      shell: shell,
      context_limit: 16_000,
      max_output_tokens: 2_000
    )
  end
end
