# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "tmpdir"

# Wakeloop regression (field incident 2026-10-09): each wake-worthy notice
# stranded at turn end armed another autonomous turn, so a steady subagent
# stream chained maestro turns forever (the prompt never returned) and the
# cycle SURVIVED Ctrl+C — the interrupted turn's own ensure re-armed the
# wake. The settlement invariant pinned here:
#
#   * an autonomous notice turn never spawns another one (chain bound: one
#     evaluation per user action; its stranded notices still reach history),
#   * an interrupted turn settles the wake debt (^C yields a stable prompt),
#   * B3's original intent is preserved: a USER turn's stranded notices
#     still arm exactly one wake.
#
# Drive model: the user's own turn goes through execute_input (the real
# seam, no readline); the synthetic-Enter wake lands as an EMPTY line, so
# read_and_process_line([], nil) reproduces exactly what run_interactive
# does after safe_wakeup! injects "\n".
class TestSubagentReactiveWakeSettlement < Minitest::Test
  # Reline double with the two Plan-109 surfaces (line_buffer, ungetc).
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

    def readline(_prompt, *_)
      ""
    end
  end

  # FakeLLM that emits a subagent completion mid-turn (a pipeline peer
  # settling while maestro works) and optionally raises Interrupt
  # mid-stream. Each call renders a unique marker so the turn count is
  # observable in the output stream.
  class ScenarioLLM
    attr_reader :turns

    def initialize(shell, interrupt_on: nil)
      @shell = shell
      @interrupt_on = interrupt_on
      @turns = 0
    end

    def complete(_history, _opts = {})
      Rubik::LLM::Response.new(text: "TURN-#{@turns += 1}")
    end

    def stream_chat(_history, _opts = {}, &block)
      @turns += 1
      @shell.handle_subagent_event(
        Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT,
        { id: "sub-#{@turns}", role: "Tester", state: :completed }
      )
      raise Interrupt if @interrupt_on && @turns >= @interrupt_on

      block&.call(Rubik::LLM::Chunk.new(text_delta: "TURN-#{@turns}"))
      block&.call(Rubik::LLM::Chunk.new(usage: { input_tokens: 10, output_tokens: 3 }, done: true))
      Rubik::LLM::Response.new(text: "TURN-#{@turns}")
    end
  end

  def build_shell
    temp_dir = Dir.mktmpdir("rubik_wake_settle")
    temp_home = Dir.mktmpdir("rubik_wake_settle_home")
    config = Rubik::Config.new(root_dir: temp_dir, home_dir: temp_home)
    output = StringIO.new
    shell = Rubik::REPL::Shell.new(config: config, output: output, root_dir: temp_dir,
                                   reline: WakeReline.new)
    shell.instance_variable_set(:@running, true)
    (@shells ||= []) << [shell, temp_dir, temp_home]
    shell
  end

  def wire(shell, llm)
    shell.runtime_manager.provide(:llm_client, llm)
    router = shell.router
    router.instance_variable_set(:@test_llm, llm)
    def router.route(**)
      { provider: @test_llm, model: "test-model", context_limit: 8192, max_output_tokens: 1024 }
    end
  end

  def teardown
    (@shells || []).each do |shell, temp_dir, temp_home|
      shell&.stop
      FileUtils.remove_entry(temp_dir) if temp_dir && File.exist?(temp_dir)
      FileUtils.remove_entry(temp_home) if temp_home && File.exist?(temp_home)
    end
    @shells = []
  end

  # A subagent completing during EVERY maestro turn must not chain auto-turns
  # forever: one user turn buys at most ONE autonomous evaluation, and the
  # prompt comes back. The synthetic turn's stranded notices still reach
  # history (no B3 turn-loss) — the backlog waits for the user's next Enter.
  def test_stranded_notice_chain_must_not_run_away
    shell = build_shell
    llm = ScenarioLLM.new(shell)
    wire(shell, llm)

    shell.execute_input("go to work")
    assert_equal 1, llm.turns, "anchor: the user turn itself ran"

    20.times { shell.read_and_process_line([], nil) } # injected Enters

    assert_equal 2, llm.turns,
                 "expected user turn + ONE evaluation, got #{llm.turns} chained auto-turns"
    assert shell.conversation_history.any? { |m| m[:content].to_s.include?("subagent_notifications") },
           "no loss: stranded notices still reach the model channel"
  end

  # Ctrl+C must settle the wake debt: the cancelled turn's stranded notice
  # reaches history but must not re-arm the cycle — the restored prompt is
  # stable, and repeated Enters cannot resurrect the loop.
  def test_interrupt_settles_wake_debt
    shell = build_shell
    llm = ScenarioLLM.new(shell, interrupt_on: 1) # subagent settles, then ^C
    wire(shell, llm)

    shell.execute_input("go to work")
    assert_equal 1, llm.turns, "anchor: the interrupted turn ran once"
    assert_includes shell.output.string, "iptal edildi", "the interrupt must be acknowledged"

    shell.read_and_process_line([], nil) # injected Enter at the restored prompt
    shell.read_and_process_line([], nil)

    assert_equal 1, llm.turns, "after ^C no turn may fire without user input"
    refute shell.pending_wake_notices?, "wake debt must be settled by the interrupt"
    assert shell.conversation_history.any? { |m| m[:content].to_s.include?("subagent_notifications") },
           "no loss: the interrupted turn's stranded notice still reaches history"
  end

  # B3's original intent survives the settlement invariant: a USER turn's
  # stranded notices arm exactly one wake — one evaluation turn runs, then
  # the prompt returns.
  def test_user_turn_stranded_notice_still_arms_exactly_one_wake
    shell = build_shell
    llm = ScenarioLLM.new(shell)
    wire(shell, llm)

    shell.execute_input("go to work")
    assert shell.pending_wake_notices?, "B3: a user turn's stranded notice arms the wake"

    shell.read_and_process_line([], nil)
    assert_equal 2, llm.turns, "exactly one autonomous evaluation turn"

    shell.read_and_process_line([], nil)
    assert_equal 2, llm.turns, "the autonomous turn must not chain another"
  end

  # The ^C branch must also drain ALREADY-QUEUED wake debt (a notice armed
  # from the idle path before the turn started): otherwise the restored
  # prompt re-enters the cycle on the next injected Enter.
  def test_interrupt_drains_prequeued_wake_debt
    shell = build_shell
    llm = ScenarioLLM.new(shell, interrupt_on: 1)
    wire(shell, llm)

    # Idle-path enqueue BEFORE the turn: the debt exists when ^C lands.
    shell.handle_subagent_event(
      Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT,
      { id: "sub-pre", role: "Tester", state: :completed }
    )
    assert shell.pending_wake_notices?, "anchor: the pre-queued debt exists"

    shell.execute_input("go to work") # interrupted mid-turn
    assert_includes shell.output.string, "iptal edildi"

    shell.read_and_process_line([], nil) # injected Enter at the restored prompt
    assert_equal 1, llm.turns, "pre-queued wake debt must not fire a turn after ^C"
    refute shell.pending_wake_notices?, "the ^C settlement must drain queued debt"
  end

  # F2 residue: an event landing in an AUTONOMOUS turn's idle-path windows
  # (before @active_loop is set / after it is cleared) still prints and
  # injects, but must not arm a follow-up wake.
  def test_idle_event_during_autonomous_turn_does_not_arm_wake
    shell = build_shell
    shell.instance_variable_set(:@autonomous_turn, true)
    shell.handle_subagent_event(
      Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT,
      { id: "sub-window", role: "Tester", state: :completed }
    )

    refute shell.pending_wake_notices?, "no wake debt while an autonomous turn is open"
    assert_includes shell.output.string, "[Subagent Completed]", "the user channel still prints"
    assert shell.conversation_history.any? { |m| m[:content].to_s.include?("subagent_notifications") },
           "history injection still happens (no loss)"
  end

  # F3 pin: the whole settlement lives behind respond_to? guards, so a
  # dropped Lifecycle include would silently re-disable the fix. Pin the
  # integration instead of trusting the guard.
  def test_shell_integrates_the_settlement_seam
    assert_respond_to build_shell, :deliver_stranded_loop_notices!
    assert_respond_to build_shell, :clear_pending_wake_notices!
  end
end
