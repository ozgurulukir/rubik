# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/orchestrator/goal_ledger"

# Loop#resume! / Loop#resume_from (issue #106): in-process resume history
# prefix'i nesne-özdeş tutar; cross-process resume Σ penceresini kurar ve
# sayaçları damga meta'sından geri yükler.
class TestGoalLoopResume < Minitest::Test
  GL = Rubik::Orchestrator::GoalLedger

  # Scripted per-call outcomes: response text strings or exception instances.
  class ScriptedProvider < Rubik::LLM::BaseProvider
    def initialize(script)
      super()
      @script = script.dup
    end

    def complete(_messages, _opts = {})
      step = @script.shift
      raise step if step.is_a?(Exception)

      Rubik::LLM::Response.new(text: step.to_s)
    end
  end

  def setup
    @root = Dir.mktmpdir("goal-loop-resume")
    @store = Rubik::Storage::Store.new(root: @root, project: "loop-resume")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def registry_with_finish
    registry = Rubik::Tools::Registry.new
    registry.register(Rubik::Tools::FinishTool.new)
    registry
  end

  def build_loop(provider)
    Rubik::Orchestrator::Loop.new(provider: provider, tool_registry: registry_with_finish,
                                  max_steps: 10, context_limit: 16_000, max_output_tokens: 2_000)
  end

  def suspended_ledger
    ledger = GL::Ledger.create!(goal_text: "Fix the payment module", store: @store)
    ledger.suspend!(goal_id: "goal-1", steps: 12, max_steps: 100, extensions: 0,
                    tokens: { input: 5, output: 6 }, reason: "DNS failure",
                    suspended_at: Time.now.utc.iso8601, attempt: 2)
    ledger
  end

  def test_in_process_resume_keeps_the_history_prefix_object_identical
    loop_inst = build_loop(ScriptedProvider.new(['{"tool": "finish", "args": {"message": "back online"}}']))
    # Suspend-boundary state (request-boundary contract): the transport
    # failure escapes before turn_executor.call, so @history ends at a
    # complete-message boundary. Reconstructed here to pin resume identity.
    loop_inst.instance_variable_set(:@goal_mode, true)
    loop_inst.history << { role: "system", content: "goal system prompt" }
    loop_inst.history << { role: "user", content: "Ship it" }
    loop_inst.instance_variable_set(:@step_count, 2)

    prefix = loop_inst.history.dup
    res = loop_inst.resume!(reason: "Network error calling api.example.com",
                            suspended_at: Time.now - 100, attempt: 1)

    assert res[:ok], "resume must continue the same loop to completion"
    assert loop_inst.goal_mode?, "resume must keep the goal-mode flag"
    assert_equal 3, loop_inst.step_count, "counter continued from the restored 2 (the resumed step itself consumes one)"
    prefix.each_with_index do |row, i|
      assert_same row, loop_inst.history[i], "history prefix must be object-identical after in-process resume"
    end
    marker = loop_inst.history.find { |m| m[:content].to_s.start_with?("<goal_resumed ") }
    assert marker, "the goal_resumed marker must be in the continued history"
    assert_includes marker[:content], 'attempt="1"'
    assert_includes marker[:content], 'downtime="1m 40s"'
    assert_includes marker[:content], "Network error calling api.example.com"
    assert_operator loop_inst.history.index(marker), :==, prefix.size,
                    "the marker must sit exactly at the suspend boundary"
  end

  def test_resume_from_builds_the_sigma_window_and_restores_counters
    ledger = suspended_ledger

    loop_inst = build_loop(ScriptedProvider.new(['{"tool": "finish", "args": {"message": "rehydrated"}}']))
    res = loop_inst.resume_from(goal_text: "Fix the payment module", ledger: ledger,
                                reason: "DNS failure", suspended_at: Time.now - 30,
                                attempt: 2, counters: { steps: 12, max_steps: 100,
                                                        tokens: { "input" => 7, "output" => 9 } })

    assert res[:ok]
    assert loop_inst.goal_mode?, "@goal_mode must be set by resume_from itself"
    assert_equal 13, loop_inst.step_count, "counters restored (12) and continued (+1) — a fresh loop would sit at 1"
    assert_equal 100, loop_inst.max_steps
    assert_operator loop_inst.total_tokens[:input], :>=, 7, "restored tokens are the accumulation BASE (the turn adds usage)"

    roles = loop_inst.history.map { |r| r[:role] }
    assert_equal "system", roles[0], "window row 0: the goal-mode system prompt"
    assert_equal ["user", "user", "user"], roles[1, 3], "window rows 1..3: task → Σ row → marker (turn rows follow)"
    assert_includes loop_inst.history[1][:content], "<user_task>"
    assert_includes loop_inst.history[2][:content], '<goal_ledger rev="0"'
    assert_includes loop_inst.history[3][:content], 'attempt="2"'
    assert_includes loop_inst.history[3][:content], 'downtime="30s"'
  end

  def test_resume_from_keeps_the_single_sigma_row_invariant_at_the_first_step
    # refresh_in_history! anchors Σ after the <user_task> row; the window
    # must present the SAME shape so the first resumed step's refresh
    # repositions (not duplicates) the row.
    ledger = suspended_ledger
    loop_inst = build_loop(ScriptedProvider.new(['{"tool": "finish", "args": {"message": "done"}}']))
    loop_inst.resume_from(goal_text: "g", ledger: ledger, reason: "r", attempt: 1,
                          counters: { steps: 0, max_steps: 10, tokens: {} })

    refreshed = loop_inst.history.dup
    ledger.refresh_in_history!(refreshed)
    ledger_rows = refreshed.count { |m| m[:content].to_s.start_with?("<goal_ledger ") }
    assert_equal 1, ledger_rows, "single-Σ-row invariant must hold at the first resumed step"
  end
end
