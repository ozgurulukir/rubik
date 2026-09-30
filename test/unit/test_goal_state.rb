# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestGoalState < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_goal_state_test")
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
  end

  def test_lifecycle_transitions_running_to_terminal_states
    state = Rubik::Orchestrator::GoalState.new
    assert_equal :idle, state.status
    refute state.running?

    state.start!("fix the payment tests", 100)
    assert state.running?
    assert_equal "fix the payment tests", state.goal
    assert_equal 100, state.max_steps
    refute_nil state.started_at

    state.complete!("All tests green\nSecond line is trimmed from the summary")
    assert_equal :completed, state.status
    refute_nil state.finished_at
    assert_equal "All tests green", state.output_summary

    # Double finish (Interrupt race) is a no-op — first terminal state wins.
    state.complete!("overwritten")
    assert_equal :completed, state.status
    assert_equal "All tests green", state.output_summary

    # A fresh !goal run resets the same object's counters.
    state.start!("new goal", 40)
    assert state.running?
    assert_equal 0, state.step_count
    assert_equal 0, state.extensions
    assert_nil state.last_error
    assert_nil state.finished_at
  end

  def test_update_steps_is_monotonic_across_repeated_step_events
    state = Rubik::Orchestrator::GoalState.new
    state.start!("g", 100)

    state.update_steps(5, 100)
    state.update_steps(3, 100) # out-of-order event within the same step
    assert_equal 5, state.step_count

    state.update_steps(6, 120) # live !steps extension raises the ceiling
    assert_equal 120, state.max_steps
    state.update_steps(7, 100) # a stale max must not lower it back
    assert_equal 120, state.max_steps
  end

  def test_extend_increments_extensions_and_raises_max_only_when_running
    state = Rubik::Orchestrator::GoalState.new
    state.start!("g", 100)

    state.extend!(120)
    state.extend!(110) # never lowers the ceiling, still counts as an extension event
    assert_equal 2, state.extensions
    assert_equal 120, state.max_steps

    state.complete!("done")
    state.extend!(200)
    assert_equal 2, state.extensions, "extend! after a terminal state is a no-op"
    assert_equal 120, state.max_steps
  end

  def test_fail_sanitizes_and_bounds_error_text
    state = Rubik::Orchestrator::GoalState.new
    state.start!("g", 10)

    binary = (+"Max steps\xFF\xFE budget exceeded").force_encoding(Encoding::UTF_8)
    state.fail!(binary, tokens: { input: 5, output: 6 })
    assert_equal :failed, state.status
    refute_nil state.last_error
    assert_operator state.last_error.length, :<=, 300
    assert state.last_error.valid_encoding?, "error text must be valid UTF-8 after sanitization"
    assert_equal 5, state.tokens[:input]
    assert_equal 6, state.tokens[:output]
  end

  def test_stop_records_interrupt_reason
    state = Rubik::Orchestrator::GoalState.new
    state.start!("g", 10)
    state.update_steps(4, 10)
    state.stop!("Interrupted by user (^C)")
    assert_equal :stopped, state.status
    assert_equal "Interrupted by user (^C)", state.last_error
  end

  def test_to_xml_escapes_goal_text_and_omits_empty_attributes
    state = Rubik::Orchestrator::GoalState.new
    state.start!('Fix <payments> & "billing"', 100)
    state.update_steps(12, 100)
    state.extend!(120)

    xml = state.to_xml
    assert_includes xml, '<goal_state status="running" steps="12" max_steps="120" extensions="1"'
    assert_includes xml, "<goal>Fix &lt;payments&gt; &amp; &quot;billing&quot;</goal>"
    refute_includes xml, "finished_at", "unfinished run must not emit finished_at"
    refute_includes xml, "last_error", "errorless run must not emit last_error"

    state.fail!("boom")
    xml = state.to_xml
    assert_includes xml, 'status="failed"'
    assert_includes xml, "finished_at="
    assert_includes xml, 'last_error="boom"'
  end

  def test_concurrent_updates_do_not_crash
    state = Rubik::Orchestrator::GoalState.new
    state.start!("g", 100)
    threads = Array.new(8) do |i|
      Thread.new do
        50.times do |j|
          state.update_steps(j % 30, 100)
          state.record_tokens!(input: 1, output: 1) if (i + j).even?
        end
      end
    end
    threads.each(&:join)
    snap = state.snapshot
    assert snap[:steps].between?(0, 100)
    assert_operator snap[:tokens][:input], :>, 0
  end

  def test_read_file_serves_goal_state_xml_from_runtime_context
    ctx = Rubik::Runtime::Context.new
    state = Rubik::Orchestrator::GoalState.new
    state.start!("fix the flaky spec", 100)
    ctx.provide(Rubik::Coeffects::GOAL_STATE, state)

    tool = Rubik::Tools::ReadFileTool.new(@buffer_manager, runtime_context: ctx)
    ["rubik://goal/state", "rubik://goal", "rubik://goal/state.xml"].each do |url|
      res = tool.execute("path" => url)
      assert_includes res.to_s, "<goal_state", "#{url} must serve the goal state"
      assert_includes res.to_s, "fix the flaky spec"
    end
    ctx.dispose
  end

  def test_read_file_returns_honest_not_found_without_goal_state
    plain = Rubik::Tools::ReadFileTool.new(@buffer_manager)
    res = plain.execute("path" => "rubik://goal/state")
    assert_includes res.to_s, "No goal state available"
    refute_includes res.to_s, "<goal_state"

    ctx = Rubik::Runtime::Context.new
    wired = Rubik::Tools::ReadFileTool.new(@buffer_manager, runtime_context: ctx)
    res2 = wired.execute("path" => "rubik://goal")
    assert_includes res2.to_s, "No goal state available"
    ctx.dispose
  end

  def test_read_file_standalone_positional_construction_still_works
    File.write(File.join(@temp_dir, "note.txt"), "hello")
    tool = Rubik::Tools::ReadFileTool.new(@buffer_manager)
    assert_includes tool.execute("path" => "note.txt").to_s, "hello"
  end

  def test_child_context_resolves_goal_state_through_parent_chain
    # Branch-workspace subagents get a read_file bound to a DERIVED context
    # (supervisor bind_tool_buffer); the coeffect must resolve up the chain
    # so coder subagents see the live snapshot during a goal run.
    root = Rubik::Runtime::Context.new
    state = Rubik::Orchestrator::GoalState.new
    state.start!("shared objective", 100)
    root.provide(Rubik::Coeffects::GOAL_STATE, state)

    child = root.extend
    tool = Rubik::Tools::ReadFileTool.new(@buffer_manager, runtime_context: child)
    assert_includes tool.execute("path" => "rubik://goal/state").to_s, "shared objective"
    child.dispose
    root.dispose
  end
end
