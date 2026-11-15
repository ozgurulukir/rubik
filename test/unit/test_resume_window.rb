# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/orchestrator/resume_window"

# ResumeWindow (issue #475): the Loop-side resume window collaborator.
# Marker stamping, downtime formatting, Σ-window prefix construction and the
# §6 ctx.extend lifecycle — testable WITHOUT running a turn.
class TestResumeWindow < Minitest::Test
  GL = Rubik::Orchestrator::GoalLedger

  def build_loop
    Rubik::Orchestrator::Loop.new(provider: nil, tool_registry: Rubik::Tools::Registry.new,
                                  max_steps: 10, context_limit: 16_000, max_output_tokens: 2_000)
  end

  # ── marker stamping ──────────────────────────────────────────────────

  def test_marker_carries_the_exact_attributes_and_sits_at_history_end
    loop_inst = build_loop
    loop_inst.history << { role: "system", content: "s" }
    loop_inst.instance_variable_set(:@step_count, 7)

    Rubik::Orchestrator::ResumeWindow.new(loop_inst).stamp_resume_marker!(
      reason: "Network error", suspended_at: Time.now - 100, attempt: 3
    )

    marker = loop_inst.history.last
    assert_equal({ role: "user", content: marker[:content] }, marker)
    assert_includes marker[:content], 'downtime="1m 40s"'
    assert_includes marker[:content], 'reason="Network error"'
    assert_includes marker[:content], 'attempt="3"'
    assert_includes marker[:content], 'steps_done="7"'
  end

  def test_marker_monotonicity_across_repeated_resume_cycles
    loop_inst = build_loop
    window = Rubik::Orchestrator::ResumeWindow.new(loop_inst)
    5.times do |i|
      window.stamp_resume_marker!(reason: "r#{i}", suspended_at: Time.now - i, attempt: i + 1)
    end

    markers = loop_inst.history.select { |r| r[:content].to_s.start_with?("<goal_resumed ") }
    assert_equal 5, markers.size, "each resume cycle stamps exactly one marker — none lost, none duplicated"
    assert_equal((1..5).to_a, markers.map { |m| m[:content][/attempt="(\d+)"/, 1].to_i },
                 "markers accumulate in strict chronological (append) order")
  end

  def test_marker_truncates_the_reason_at_300_chars
    loop_inst = build_loop
    Rubik::Orchestrator::ResumeWindow.new(loop_inst).stamp_resume_marker!(
      reason: "x" * 500, suspended_at: nil, attempt: 1
    )
    assert_includes loop_inst.history.last[:content], "reason=\"#{'x' * 300}\""
    refute_includes loop_inst.history.last[:content], "x" * 301
  end

  def test_unknown_suspend_time_yields_honest_downtime
    window = Rubik::Orchestrator::ResumeWindow.new(build_loop)
    assert_equal "unknown", window.send(:format_downtime, nil)
    assert_equal "unknown", window.send(:format_downtime, 0)
    assert_equal "unknown", window.send(:format_downtime, "garbage")
  end

  def test_downtime_formatting_buckets
    now = Time.now
    window = Rubik::Orchestrator::ResumeWindow.new(build_loop)
    assert_equal "45s", window.send(:format_downtime, now - 45)
    assert_equal "4m 12s", window.send(:format_downtime, now - 252)
    assert_equal "1h 03m", window.send(:format_downtime, now - 3780)
    assert_equal "0s", window.send(:format_downtime, now + 999), "clock skew clamps to 0"
  end

  # ── Σ-window prefix construction ─────────────────────────────────────

  def test_cross_process_prefix_shapes_system_task_sigma_rows
    @root = Dir.mktmpdir("resume-window")
    store = Rubik::Storage::Store.new(root: @root, project: "resume-window")
    ledger = GL::Ledger.create!(goal_text: "Fix it", store: store)
    loop_inst = build_loop
    window = Rubik::Orchestrator::ResumeWindow.new(loop_inst)

    window.build_cross_process_prefix!(goal_text: "Fix it", ledger: ledger,
                                       system_prompt: "goal system prompt")

    roles = loop_inst.history.map { |r| r[:role] }
    assert_equal ["system", "user", "user"], roles
    assert_equal "goal system prompt", loop_inst.history[0][:content]
    assert_includes loop_inst.history[1][:content], "<user_task>"
    assert_includes loop_inst.history[2][:content], "<goal_ledger "
  ensure
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  # ── §6 ctx.extend lifecycle ──────────────────────────────────────────

  def test_in_process_resume_lifecycle_disposes_old_then_extends_then_closes
    runtime = Rubik::Runtime::Manager.new
    loop_inst = build_loop
    loop_inst.instance_variable_set(:@runtime_manager, runtime)
    window = Rubik::Orchestrator::ResumeWindow.new(loop_inst)
    old_ctx = loop_inst.loop_context = runtime.context.extend

    window.reopen_context!
    assert old_ctx.disposed?, "the suspended run's sub-context must be disposed BEFORE the fresh extend (§6)"
    fresh_ctx = loop_inst.loop_context
    refute_equal old_ctx, fresh_ctx
    refute fresh_ctx.disposed?

    window.close_context!
    assert fresh_ctx.disposed?, "ensure-side close disposes exactly the window's own context"
  ensure
    runtime&.context&.dispose
  end

  def test_cross_process_resume_lifecycle_extends_a_fresh_child
    runtime = Rubik::Runtime::Manager.new
    loop_inst = build_loop
    loop_inst.instance_variable_set(:@runtime_manager, runtime)
    window = Rubik::Orchestrator::ResumeWindow.new(loop_inst)
    assert_nil loop_inst.loop_context, "a fresh loop has no prior sub-context"

    window.open_context!
    refute loop_inst.loop_context.disposed?
    window.close_context!
    assert loop_inst.loop_context.disposed?
  ensure
    runtime&.context&.dispose
  end
end
