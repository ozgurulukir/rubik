# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Issue #477: direct unit coverage for the named phases of
# Rubik::REPL::InputExecution — adapter-command (bang) execution, free-text
# turn dispatch (arming → routing → display → loop → settle) and the
# error/rollback rescue ladder. Behavior-not-ivars: assertions read the
# shell's public surface (output, conversation_history, recorder events)
# and double out only the LLM provider and the orchestrator loop, never
# spawning real processes.
class TestInputExecutionPhases < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_iexec_test")
    @temp_home = Dir.mktmpdir("rubik_iexec_home")
    @output = StringIO.new
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    @shell = Rubik::REPL::Shell.new(config: @config, output: @output, root_dir: @temp_dir)
    @fake_provider = Object.new
    @router = Object.new
    @router.define_singleton_method(:route) do |**_kw|
      { role: "default", model: "m", provider: @fake_provider,
        context_limit: 4096, max_output_tokens: 1024 }
    end
    @router.instance_variable_set(:@fake_provider, @fake_provider)
    @shell.instance_variable_set(:@router, @router)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
    FileUtils.remove_entry(@temp_home) if @temp_home && File.exist?(@temp_home)
  end

  # Helpers stay public: a blanket `private` would hide the test_ methods
  # from Minitest's runnable-method scan.

  # Installs a fake orchestrator loop so the run phase never touches a real
  # LLM client. `result` is returned by #run; pass a block to raise instead.
  def stub_orchestrator_loop(result: nil, &run_block)
    fake = Object.new
    fake.define_singleton_method(:run) do |_text, **_kw|
      run_block ? run_block.call : result
    end
    @shell.define_singleton_method(:orchestrator_loop) { |_opts| fake }
    fake
  end

  def fake_parsed(name, args = [], raw: nil)
    raw ||= "!#{name}#{" #{args.join(' ')}" unless args.empty?}"
    Struct.new(:command_name, :args, :raw).new(name, args, raw)
  end

  def install_fake_command(name, handler)
    @shell.commands[name.to_s] = { description: "fake", handler: handler }
  end

  def events_of(type)
    @shell.recorder.events.select { |e| e["type"] == type }
  end

  # Minimal bus double: emit_turn_finished needs #post and the bus
  # forwarding path also calls #emit.
  class SpyBus
    attr_reader :posts

    def initialize
      @posts = []
    end

    def post(name, payload = {}, **kwargs)
      @posts << [name, payload, kwargs]
    end
    alias emit post
  end

  # turn_finished rides the event bus, not the session recorder — swap in a
  # spy bus before the turn so the settle/rescue phase emissions are visible.
  def install_turn_event_spy
    spy = SpyBus.new
    @shell.instance_variable_set(:@event_bus, spy)
    spy
  end

  def last_turn_event_kind(spy)
    spy.posts.select { |(name, _p, _kw)| name == Rubik::Events::TURN_FINISHED }.last[1][:kind]
  end

  def test_first_tool_using_turn_keeps_tool_rows_on_a_fresh_window
    install_turn_event_spy
    tool_row = { role: "tool", tool_call_id: "c1", tool_name: "read_file", status: :ok,
                 duration_ms: 1.0, content: "file content" }
    loop_double = Object.new
    loop_double.define_singleton_method(:history) { [tool_row] }
    res = { ok: true, output: "done", tokens: 1, streamed: false, loop_instance: loop_double }

    @shell.settle_free_text_result!("do work", res, orchestrator: nil, theme: nil, md_enabled: false)

    roles = @shell.conversation_history.map { |r| r[:role] }
    assert_equal ["user", "assistant", "tool"], roles,
                 "recording the outcome before the merge keeps tool rows on a fresh window (issue #557)"
  end

  # ------------------------------------------------------------------
  # Adapter-command execution (execute_command)
  # ------------------------------------------------------------------

  def test_tracked_command_output_is_captured_into_history_and_recorder
    calls = []
    install_fake_command("fakecmd", lambda { |_args, ctx|
      calls << :called
      ctx.out.puts "hello from fake"
    })

    @shell.execute_command(fake_parsed("fakecmd", ["a", "b"]))

    assert_equal [:called], calls
    # LLM history gains a user/assistant pair; the bang prefix stays out.
    last_user = @shell.conversation_history.last(2).first
    last_assistant = @shell.conversation_history.last
    assert_equal "user", last_user[:role]
    assert_equal "fakecmd a b", last_user[:content]
    assert_equal "assistant", last_assistant[:role]
    assert_equal "hello from fake", last_assistant[:content]
    # The recorder keeps the literal raw command.
    ev = events_of("repl_command").last
    refute_nil ev, "repl_command must be recorded"
    assert_equal "!fakecmd a b", ev["payload"]["command"]
    assert_equal "hello from fake", ev["payload"]["output"]
    # Handler prints reach the live output through the TeeIO capture.
    assert_includes @output.string, "hello from fake"
  end

  def test_tracked_command_with_empty_output_records_nothing
    install_fake_command("silentcmd", ->(_args, _ctx) {})

    @shell.execute_command(fake_parsed("silentcmd"))

    assert_empty @shell.conversation_history
    assert_empty events_of("repl_command")
  end

  def test_tracked_command_interrupt_rolls_back_history_recording
    install_fake_command("hangcmd", ->(_args, _ctx) { raise Interrupt })

    @shell.execute_command(fake_parsed("hangcmd"))

    # Atomic rollback: a ^C mid-command must leave no dialogue pair behind.
    assert_empty @shell.conversation_history
    assert_empty events_of("repl_command")
    assert_includes @output.string, "Command cancelled by user (^C)"
  end

  def test_untracked_lifecycle_command_skips_history_capture
    # Replace quit's real handler with an observable fake: the untracked
    # branch must run it but never append to conversation history.
    ran = false
    @shell.commands["quit"][:handler] = ->(_args, _ctx) { ran = true }

    @shell.execute_command(fake_parsed("quit"))

    assert ran, "untracked command handler must still execute"
    assert_empty @shell.conversation_history
    assert_empty events_of("repl_command")
  end

  def test_unknown_command_prints_available_list_without_dispatch
    @shell.execute_command(fake_parsed("nosuchcmd"))

    assert_includes @output.string, "Unknown command: !nosuchcmd"
    assert_includes @output.string, "!help"
    assert_empty @shell.conversation_history
  end

  def test_command_hooks_fire_around_dispatch
    before_fired = []
    after_fired = []
    @shell.hooks.register(:before_command) { |name, _args| before_fired << name }
    @shell.hooks.register(:after_command) { |name, _args| after_fired << name }
    install_fake_command("hookcmd", ->(_args, _ctx) {})

    @shell.execute_command(fake_parsed("hookcmd"))

    assert_equal ["hookcmd"], before_fired
    assert_equal ["hookcmd"], after_fired
  end

  # ------------------------------------------------------------------
  # Free-text turn dispatch (execute_free_text named phases)
  # ------------------------------------------------------------------

  def test_successful_turn_settles_into_history_recorder_and_output
    stub_orchestrator_loop(result: { ok: true, output: "final answer", tokens: { input: 3, output: 5 }, streamed: false, loop_instance: nil })

    @shell.execute_free_text("what is two plus two?")

    history = @shell.conversation_history
    assert_equal "user", history.last(2).first[:role]
    assert_equal "what is two plus two?", history.last(2).first[:content]
    assert_equal "assistant", history.last[:role]
    assert_equal "final answer", history.last[:content]
    assert_includes @output.string, "final answer"
    assert events_of("user_turn").any?
    assert events_of("assistant_response").any?
    assert_nil @shell.active_loop, "loop must be cleared in the ensure teardown"
    assert_includes @output.string, "Type `!diff`" if @shell.buffer_manager.dirty?
  end

  def test_streamed_turn_does_not_reprint_the_answer
    stub_orchestrator_loop(result: { ok: true, output: "already streamed", tokens: nil, streamed: true, loop_instance: nil })

    @shell.execute_free_text("stream it")

    assert_equal "already streamed", @shell.conversation_history.last[:content]
    refute_includes @output.string, "already streamed"
  end

  def test_route_failure_aborts_turn_and_records_failed_turn
    @shell.instance_variable_set(:@router,
                                 Object.new.tap do |r|
                                   r.define_singleton_method(:route) { |**_kw| { provider: nil, spec: { "provider" => "x", "name" => "y" } } }
                                 end)
    spy = install_turn_event_spy

    @shell.execute_free_text("turn that cannot route")

    assert_includes @output.string, "Error: Could not initialize model provider"
    assert_includes @output.string, "x/y"
    assert_equal "failed", last_turn_event_kind(spy)
    # The failed turn still lands in the conversation window as a pair.
    assert_equal "assistant", @shell.conversation_history.last[:role]
    assert_includes @shell.conversation_history.last[:content], "[Turn failed:"
    assert_nil @shell.active_loop
  end

  def test_incomplete_loop_result_records_failed_turn
    stub_orchestrator_loop(result: { ok: false, error: "budget blew up" })
    spy = install_turn_event_spy

    @shell.execute_free_text("doomed task")

    assert_includes @output.string, "Task could not be completed: budget blew up"
    assert_includes @shell.conversation_history.last[:content], "[Turn incomplete: budget blew up]"
    assert_equal "incomplete", last_turn_event_kind(spy)
    assert_nil @shell.active_loop
  end

  def test_llm_client_error_records_sanitized_failed_turn
    stub_orchestrator_loop { raise Rubik::LLM::ClientError, "503 upstream gone" }
    spy = install_turn_event_spy

    @shell.execute_free_text("talk to the model")

    assert_includes @output.string, "[Rubik::LLM Error] 503 upstream gone"
    assert_includes @shell.conversation_history.last[:content], "[Turn failed: 503 upstream gone]"
    assert_equal "failed", last_turn_event_kind(spy)
    assert_nil @shell.active_loop
  end

  def test_unexpected_error_records_failed_turn_with_class
    stub_orchestrator_loop { raise ArgumentError, "bad arg" }

    @shell.execute_free_text("trigger a bug")

    assert_includes @output.string, "[Error] ArgumentError: bad arg"
    assert_includes @shell.conversation_history.last[:content], "[Turn failed: ArgumentError: bad arg]"
    assert_nil @shell.active_loop
  end

  def test_interrupt_records_cancelled_turn_and_rolls_back_loop
    stub_orchestrator_loop { raise Interrupt }

    @shell.execute_free_text("long running thing")

    assert_includes @output.string, "Task cancelled by user (^C)"
    cancel_event = events_of("cancelled_turn").last
    refute_nil cancel_event, "^C must record a dedicated cancelled_turn event"
    assert_equal "Interrupted by user (^C)", cancel_event["payload"]["reason"]
    assert_equal "long running thing", cancel_event["payload"]["question"]
    assert_includes @shell.conversation_history.last[:content], "[Turn cancelled by user (^C)]"
    assert_nil @shell.active_loop
  end

  # ------------------------------------------------------------------
  # Run phase: budget-exhausted continue prompt (run_free_text_loop)
  # ------------------------------------------------------------------

  def test_budget_exhaustion_with_decline_returns_result_unchanged
    fake = stub_orchestrator_loop(result: { ok: false, reason: :budget_exhausted, error: "out of steps" })
    continued = false
    fake.define_singleton_method(:continue_loop) do |_n|
      continued = true
      {}
    end
    @shell.define_singleton_method(:ask_yes_no) { |*_a, **_kw| "n" }

    res = @shell.run_free_text_loop(fake, "big task")

    refute continued
    refute res[:ok]
    assert_includes @output.string, "out of steps"
  end

  def test_budget_exhaustion_with_accept_calls_continue_loop
    fake = stub_orchestrator_loop(result: { ok: false, reason: :budget_exhausted, error: "out of steps" })
    continued_with = nil
    fake.define_singleton_method(:continue_loop) do |n|
      continued_with = n
      { ok: true, output: "finished late" }
    end
    @shell.define_singleton_method(:ask_yes_no) { |*_a, **_kw| "y" }

    res = @shell.run_free_text_loop(fake, "big task")

    assert_equal 20, continued_with
    assert res[:ok]
    assert_includes @output.string, "+20"
  end

  # ------------------------------------------------------------------
  # Phase helpers
  # ------------------------------------------------------------------

  def test_turn_step_handler_dispatches_by_step_type
    recorder_calls = []
    @shell.recorder.define_singleton_method(:record_tool_call) { |*a, **kw| recorder_calls << [:call, a, kw] }
    @shell.recorder.define_singleton_method(:record_tool_result) { |*a, **kw| recorder_calls << [:result, a, kw] }
    rendered = []
    renderer = Object.new
    renderer.define_singleton_method(:render) do |info|
      rendered << info[:type]
      "[#{info[:type]}]"
    end
    pushed = []
    md_stream = Object.new
    md_stream.define_singleton_method(:push) do |delta, &blk|
      pushed << delta
      blk.call(delta)
    end
    md_stream.define_singleton_method(:finish) { |&blk| blk&.call("<end>") }

    handler = @shell.turn_step_handler(renderer, md_stream)
    handler.call(type: :chunk, delta: "hel")
    handler.call(type: :tool_call, tool: "read_file", args: { "path" => "x" })
    handler.call(type: :tool_result, tool: "read_file", output: "contents")
    handler.call(type: :weird)

    assert_equal [:chunk, :tool_call, :tool_result, :weird], rendered
    assert_equal ["hel"], pushed
    assert_includes @output.string, "hel"
    assert_equal [:call, :result], recorder_calls.map(&:first)
  end

  def test_task_cancellation_lines_report_wait_vs_cancelled_tree
    waiting = @shell.task_cancellation_lines(nil)
    assert_equal 1, waiting.size
    assert_includes waiting.first, "Wait interrupted"

    outcome = Struct.new(:stopped, :queued_cancelled, :complete?, :remaining)
                    .new([1, 2], [:q1], true, [])
    tree = @shell.task_cancellation_lines(outcome)
    assert_includes tree.first, "2 linked subagents stopped"
    assert_includes tree.first, "1 queued jobs cancelled"
    assert_includes tree.first, "cleanup completed"

    incomplete = Struct.new(:stopped, :queued_cancelled, :complete?, :remaining)
                       .new([1], [], false, [{ id: "s9", state: "stuck" }])
    partial = @shell.task_cancellation_lines(incomplete)
    assert_includes partial.first, "INCOMPLETE"
    assert_includes partial.first, "s9:stuck"
  end

  def test_kill_spinner_never_lets_cleanup_mask_in_flight_errors
    bad_spinner = Object.new
    bad_spinner.define_singleton_method(:kill) { raise ThreadError, "dead mutex" }

    _out, err = capture_io do
      @shell.kill_spinner!(bad_spinner)
      @shell.kill_spinner!(nil)
    end
    assert_includes err, "spinner cleanup failed"
    assert_includes err, "ThreadError"
  end

  # ------------------------------------------------------------------
  # Autonomous notice turn (execute_subagent_notice_turn!)
  # ------------------------------------------------------------------

  def test_notice_turn_with_empty_queue_is_a_no_op
    @shell.define_singleton_method(:drain_pending_wake_notices!) { [] }

    refute @shell.execute_subagent_notice_turn!
    assert_empty @shell.conversation_history
  end

  def test_notice_turn_runs_a_synthetic_turn_and_resets_autonomous_flag
    @shell.define_singleton_method(:drain_pending_wake_notices!) do
      [{ id: "sa1", kind: "budget_pause" }]
    end
    prompts = []
    fake = Object.new
    fake.define_singleton_method(:run) do |text, **_kw|
      prompts << text
      { ok: true, output: "notice handled", tokens: nil, streamed: true, loop_instance: nil }
    end
    @shell.define_singleton_method(:orchestrator_loop) { |_opts| fake }

    assert @shell.execute_subagent_notice_turn!

    assert_equal 1, prompts.size
    assert_includes prompts.first, Rubik::REPL::InputExecution::NOTICE_TURN_MARKER
    assert_includes prompts.first, "sa1:budget_pause"
    refute @shell.instance_variable_get(:@autonomous_turn),
           "the autonomous flag must be reset after the synthetic turn"
  end
end
