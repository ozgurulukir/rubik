# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "tmpdir"

# Plan 109 Faz B: an idle subagent/task event queues a wake and kicks the
# blocked readline; the resulting empty line becomes an autonomous agent-0
# notice-evaluation turn with a marker-prefixed synthetic prompt.
class TestSubagentReactiveWakeup < Minitest::Test
  # Reline double with the two Plan-109 surfaces: line_buffer (emptiness
  # probe) and ungetc (injected Enter recorder).
  class WakeReline
    attr_reader :ungetc_calls
    attr_accessor :line_buffer

    def initialize
      @line_buffer = ""
      @ungetc_calls = []
    end

    def ungetc(char)
      @ungetc_calls << char
    end

    # safe_readline calls readline(prompt, add_history) positionally.
    def readline(_prompt, *_)
      ""
    end
  end

  class FakeLLM
    def complete(_history, _opts = {})
      Rubik::LLM::Response.new(text: "Turn completed successfully.")
    end

    def stream_chat(_history, _opts = {}, &block)
      block&.call(Rubik::LLM::Chunk.new(text_delta: "Turn completed successfully."))
      block&.call(Rubik::LLM::Chunk.new(usage: { input_tokens: 10, output_tokens: 3 }, done: true))
      Rubik::LLM::Response.new(text: "Turn completed successfully.")
    end
  end

  # --- PendingNoticeQueue (queue-only mold) --------------------------------

  def test_pending_queue_fifo_drain_validation_and_clear
    q = Rubik::REPL::PendingNoticeQueue.new
    refute q.any?
    assert_equal [], q.drain_all

    n1 = { kind: :completed, id: "sub-1", role: "R", state: "completed" }
    n2 = { kind: :message, id: "sub-2", role: "S", state: "message" }
    q.enqueue(n1)
    q.enqueue(n2)
    assert q.any?
    assert_equal [n1, n2], q.drain_all
    assert_equal [], q.drain_all, "empty-after-drain by construction"

    error = assert_raises(ArgumentError) { q.enqueue("legacy string") }
    assert_includes error.message, "pending wake notice must be a Hash with :kind"

    q.enqueue(n1)
    q.clear!
    refute q.any?, "clear! empties for the staleness rule"
  end

  # --- TerminalGuard wake primitives ---------------------------------------

  def test_idle_and_empty_requires_reading_and_blank_buffer
    reline = WakeReline.new
    guard = Rubik::REPL::TerminalGuard.new(output: StringIO.new, reline: reline)

    refute guard.idle_and_empty?, "not reading -> not idle"
    guard.with_reading do
      assert guard.idle_and_empty?
      reline.line_buffer = "partial"
      refute guard.idle_and_empty?, "user mid-line -> not idle"
    end
  end

  def test_safe_wakeup_ungetc_when_idle_and_empty
    reline = WakeReline.new
    guard = Rubik::REPL::TerminalGuard.new(output: StringIO.new, reline: reline)

    refute guard.safe_wakeup!
    assert_empty reline.ungetc_calls

    guard.with_reading do
      assert guard.safe_wakeup!
    end
    assert_equal ["\n".ord], reline.ungetc_calls
  end

  def test_safe_wakeup_skipped_when_user_typing
    reline = WakeReline.new
    reline.line_buffer = "half-typed"
    guard = Rubik::REPL::TerminalGuard.new(output: StringIO.new, reline: reline)

    guard.with_reading do
      refute guard.safe_wakeup!
    end
    assert_empty reline.ungetc_calls, "user typing is never disturbed"
  end

  def test_wake_primitives_inert_on_doubles_without_reline_api
    reline = Class.new do
      def readline(_prompt, _history = nil)
        "mock input"
      end
    end.new
    guard = Rubik::REPL::TerminalGuard.new(output: StringIO.new, reline: reline)

    refute guard.idle_and_empty?
    guard.with_reading do
      refute guard.idle_and_empty?
      refute guard.safe_wakeup!
    end
  end

  # --- Lifecycle routing (bare-double harness) -----------------------------

  def test_idle_completed_event_queues_and_still_injects
    shell = wake_shell(nil, reline: WakeReline.new)

    shell.handle_subagent_event(Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT,
                                { id: "sub-1", role: "Tester", state: :completed })

    assert shell.pending_wake_notices?, "wake-worthy idle notice must queue"
    assert_includes shell.output.string, "[Subagent Completed] [sub-1]"
    assert_includes shell.conversation_history.last[:content], "<subagent_notifications>"
    assert_empty shell.terminal_guard.reline.ungetc_calls, "not reading -> no kick (queue alone)"
  end

  def test_idle_event_while_reading_empty_kicks_readline
    reline = WakeReline.new
    shell = wake_shell(nil, reline: reline)

    shell.terminal_guard.with_reading do
      shell.handle_subagent_event(Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT,
                                  { id: "sub-1", role: "Tester", state: :completed })
    end

    assert_equal ["\n".ord], reline.ungetc_calls, "blocked-at-empty-prompt -> injected Enter"
  end

  def test_each_wake_worthy_event_attempts_kick
    # No empty->non-empty coalescing by design: a kick refused earlier
    # (typing/paste) must retry on the next event. Surplus injected
    # Enters degrade to the :empty noop at the interception.
    reline = WakeReline.new
    shell = wake_shell(nil, reline: reline)

    shell.terminal_guard.with_reading do
      3.times do |i|
        shell.handle_subagent_event(Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT,
                                    { id: "sub-#{i}", role: "Tester", state: :completed })
      end
    end

    assert_equal 3, shell.drain_pending_wake_notices!.size
    assert_equal ["\n".ord] * 3, reline.ungetc_calls
  end

  def test_safe_wakeup_refused_while_collecting_paste
    reline = WakeReline.new
    guard = Rubik::REPL::TerminalGuard.new(output: StringIO.new, reline: reline)

    guard.with_collecting do
      guard.with_reading do
        refute guard.safe_wakeup!
      end
    end
    assert_empty reline.ungetc_calls, "a wake Enter must never append a blank line into pasted text"

    # Outside collection the same state wakes normally.
    guard.with_reading do
      assert guard.safe_wakeup!
    end
    assert_equal ["\n".ord], reline.ungetc_calls
  end

  def test_context_compacted_never_queues_nor_kicks
    reline = WakeReline.new
    shell = wake_shell(nil, reline: reline)

    shell.terminal_guard.with_reading do
      shell.handle_subagent_event(Rubik::Orchestrator::Subagent::Notices::COMPACTED_EVENT,
                                  { id: "sub-1", role: "Tester", state: :running, reason: "recovered" })
    end

    refute shell.pending_wake_notices?
    assert_empty reline.ungetc_calls
    assert_includes shell.output.string, "Compacted", "non-wake kinds still print + inject"
  end

  def test_kill_switch_false_keeps_today_behavior
    config = Object.new
    config.define_singleton_method(:fetch) { |key, default = nil| key == "subagents.reactive_wakeup" ? false : default }
    reline = WakeReline.new
    shell = wake_shell(nil, config: config, reline: reline)

    shell.terminal_guard.with_reading do
      shell.handle_subagent_event(Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT,
                                  { id: "sub-1", role: "Tester", state: :completed })
    end

    refute shell.pending_wake_notices?, "kill-switch: queue stays empty"
    assert_empty reline.ungetc_calls
    assert_includes shell.output.string, "[Subagent Completed] [sub-1]", "print still happens"
    assert_includes shell.conversation_history.last[:content], "<subagent_notifications>", "inject still happens"
  end

  def test_active_loop_event_never_queues
    received = []
    mock_loop = Object.new
    mock_loop.define_singleton_method(:enqueue_subagent_notice) { |n| received << n }
    shell = wake_shell(mock_loop)

    shell.handle_subagent_event(Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT,
                                { id: "sub-1", role: "Tester", state: :completed })

    assert_equal 1, received.size
    refute shell.pending_wake_notices?, "active path carries no wake debt"
  end

  def test_unit_event_idle_queues_as_task_kind
    shell = wake_shell(nil)

    shell.handle_unit_event({ type: :task, unit_id: "task-9", to_state: :completed, reason: "exit 0" })

    assert shell.pending_wake_notices?, "background task completions wake too (user decision)"
    assert_includes shell.output.string, "Task Done"
  end

  # --- Empty-line interception + notice turn + staleness (real Shell) ------

  def test_empty_enter_with_pending_runs_notice_turn
    shell = wired_shell
    seed_pending(shell, id: "sub-1", kind: :completed)

    result = shell.read_and_process_line([], nil)

    refute result[:stop]
    assert_includes shell.output.string, "Turn completed successfully.", "the wake must run a real agent turn"
    assert shell.conversation_history.any? { |m| m[:role] == "user" && m[:content].to_s.start_with?("[reactive subagent wake-up]") },
           "marker-prefixed synthetic prompt recorded honestly"
    assert shell.conversation_history.any? { |m| m[:role] == "user" && m[:content].to_s.include?("sub-1:completed") },
           "roster names ids and kinds"
    refute shell.pending_wake_notices?, "queue drained by the notice turn"
  end

  def test_empty_enter_without_pending_is_still_noop
    shell = wired_shell

    result = shell.read_and_process_line([], nil)

    refute result[:stop]
    refute_includes shell.output.string, "Turn completed successfully."
  end

  def test_empty_line_during_heredoc_is_body_not_a_turn
    shell = wired_shell
    seed_pending(shell, id: "sub-1", kind: :completed)

    result = shell.read_and_process_line([], "EOF")

    assert_equal "EOF", result[:delimiter], "heredoc collection must survive the wake"
    assert_equal [""], result[:buffer]
    refute_includes shell.output.string, "Turn completed successfully."
    assert shell.pending_wake_notices?, "pending survives to the heredoc's real turn"
  end

  def test_real_free_text_turn_clears_pending
    shell = wired_shell
    seed_pending(shell, id: "sub-1", kind: :completed)

    shell.execute_input("Hello there")

    assert_includes shell.output.string, "Turn completed successfully."
    refute shell.pending_wake_notices?, "staleness: a real turn consumed the wake debt"
  end

  def test_bang_command_clears_pending
    shell = wired_shell
    seed_pending(shell, id: "sub-1", kind: :completed)

    shell.execute_input("!subagents")

    refute shell.pending_wake_notices?
  end

  def test_empty_noop_does_not_clear_pending
    shell = wired_shell
    seed_pending(shell, id: "sub-1", kind: :completed)

    shell.execute_input("")

    assert shell.pending_wake_notices?, "the :empty noop must not self-clear (it is the interception's landing spot)"
  end

  private

  # Bare-double harness: guard (when a reline is given) and shell share ONE
  # output so print assertions observe the same stream the notices went to.
  def wake_shell(active_loop, config: nil, reline: nil)
    output = StringIO.new
    guard = reline ? Rubik::REPL::TerminalGuard.new(output: output, reline: reline) : nil
    Class.new do
      include Rubik::REPL::Lifecycle

      attr_accessor :active_loop, :output, :running, :replaying, :subagent_notices_mutex,
                    :subagent_notices, :config, :terminal_guard, :conversation_history

      def initialize(active_loop, config, terminal_guard, output)
        @active_loop = active_loop
        @output = output
        @running = true
        @replaying = false
        @subagent_notices_mutex = Mutex.new
        @subagent_notices = []
        @config = config
        @terminal_guard = terminal_guard
        @conversation_history = []
      end
    end.new(active_loop, config, guard, output)
  end

  # Real Shell + FakeLLM + router override (test_non_blocking_repl mold) so
  # the interception exercises the full read_and_process_line -> notice turn
  # -> execute_free_text path. Teardown stops the shells.
  def wired_shell
    temp_dir = Dir.mktmpdir("rubik_wake_test")
    temp_home = Dir.mktmpdir("rubik_wake_home")
    config = Rubik::Config.new(root_dir: temp_dir, home_dir: temp_home)
    output = StringIO.new
    shell = Rubik::REPL::Shell.new(config: config, output: output, root_dir: temp_dir, reline: WakeReline.new)
    shell.instance_variable_set(:@running, true)

    llm = FakeLLM.new
    shell.runtime_manager.provide(:llm_client, llm)
    router = shell.router
    router.instance_variable_set(:@test_llm, llm)
    def router.route(**)
      { provider: @test_llm, model: "test-model", context_limit: 8192, max_output_tokens: 1024 }
    end

    (@wired ||= []) << [shell, temp_dir, temp_home]
    shell
  end

  def seed_pending(shell, id:, kind:)
    state = kind == :completed ? "completed" : "running"
    shell.pending_notice_queue.enqueue({ kind: kind, id: id, role: "Worker", state: state })
  end

  def teardown
    (@wired || []).each do |shell, temp_dir, temp_home|
      shell&.stop
      FileUtils.remove_entry(temp_dir) if temp_dir && File.exist?(temp_dir)
      FileUtils.remove_entry(temp_home) if temp_home && File.exist?(temp_home)
    end
    @wired = []
  end
end
