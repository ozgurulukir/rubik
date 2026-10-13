# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestPlanAndGoal < Minitest::Test
  class MockScriptProvider < Rubik::LLM::BaseProvider
    def initialize(responses)
      super()
      @responses = responses.dup
    end

    def complete(_messages, _opts = {})
      text = @responses.shift || '{"tool": "finish", "args": { "message": "done" }}'
      Rubik::LLM::Response.new(text: text, usage: { input_tokens: 10, output_tokens: 20 })
    end
  end

  # Field incident 2026-10-12: a provider read timeout escaped the !goal
  # handler and left the GoalState running, the ledger unfinalized and the
  # session file silent.
  class ExplodingProvider < Rubik::LLM::BaseProvider
    def initialize(error)
      super()
      @error = error
    end

    def complete(_messages, _opts = {})
      raise @error
    end
  end

  # Issue #106: scripted transport failures first, then normal responses —
  # the suspend/resume lifecycle's provider seam.
  class FlakyThenGoodProvider < Rubik::LLM::BaseProvider
    def initialize(errors, responses = [])
      super()
      @errors = errors.dup
      @responses = responses.dup
    end

    def complete(_messages, _opts = {})
      raise @errors.shift unless @errors.empty?

      text = @responses.shift || '{"tool": "finish", "args": { "message": "done" }}'
      Rubik::LLM::Response.new(text: text, usage: { input_tokens: 10, output_tokens: 20 })
    end
  end

  def setup
    @temp_dir = Dir.mktmpdir("rubik_plan_test")
    @temp_home = Dir.mktmpdir("rubik_plan_home")
    @output = StringIO.new
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    # Plan/goal loops execute scripted DIRECT edits at root - buffer/loop
    # mechanics under test, not the maestro doctrine (test_maestro_gate.rb).
    @config.set("subagents.maestro_gate", false)
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @shell = Rubik::REPL::Shell.new(config: @config, buffer_manager: @buffer_manager, output: @output)
  end

  def teardown
    @shell&.stop
    FileUtils.remove_entry(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
    FileUtils.remove_entry(@temp_home) if @temp_home && File.exist?(@temp_home)
  end

  def test_plan_command_formulates_plan_and_executes_on_approval
    plan_output = "1. Inspect lib/app.rb\n2. Add helper method\n3. Run tests"
    execution_output = '{"tool": "write_file", "args": { "path": "lib/app.rb", "content": "def helper; 42; end" }}'
    finish_output = '{"tool": "finish", "args": { "message": "Plan executed successfully" }}'

    mock_provider = MockScriptProvider.new([plan_output, execution_output, finish_output])
    @shell.instance_variable_get(:@llm_registry).register("ollama", mock_provider)

    @shell.execute_input("!plan Create helper method in lib/app.rb")

    out = @output.string
    assert_includes out, "=== Proposed Plan ==="
    assert_includes out, "1. Inspect lib/app.rb"
    assert_includes out, "Executing approved plan"
    assert @buffer_manager.dirty?
    assert_equal "def helper; 42; end", @buffer_manager.read("lib/app.rb")
  end

  def test_goal_command_executes_autonomous_loop
    responses = [
      '{"tool": "list_files", "args": {}}',
      '{"tool": "write_file", "args": { "path": "lib/calc.rb", "content": "class Calc; def add(a,b); a+b; end; end" }}',
      '{"tool": "run_command", "args": { "command": "echo \'test ok\'" }}',
      '{"tool": "finish", "args": { "message": "Calculator implemented and verified" }}'
    ]

    mock_provider = MockScriptProvider.new(responses)
    @shell.instance_variable_get(:@llm_registry).register("ollama", mock_provider)

    @shell.execute_input("!goal Implement Calculator with addition")

    out = @output.string
    assert_includes out, "[Rubik::Goal] Starting autonomous goal loop"
    assert_includes out, "Goal Achieved"
    assert_includes out, "Calculator implemented and verified"
    assert @buffer_manager.dirty?
    assert_includes @buffer_manager.read("lib/calc.rb"), "class Calc"
  end

  def test_goal_asks_and_extends_budget_on_exhaustion
    @shell.execute_input("!steps goal 2")
    # Steps 1-2 burn the budget; after the approved extension the provider's
    # fallback finish completes the goal.
    provider = MockScriptProvider.new([
                                        '{"tool": "list_files", "args": {}}',
                                        '{"tool": "list_files", "args": {}}'
                                      ])
    @shell.instance_variable_get(:@llm_registry).register("ollama", provider)
    @shell.define_singleton_method(:ask_yes_no) { |*_args| "y" }

    @shell.execute_input("!goal Fix the failing spec")

    out = @output.string
    assert_includes out, "Max steps budget exceeded"
    assert_includes out, "Adım bütçesi +20 artırılıyor", "approved extension must resume the loop"
    assert_includes out, "Goal Achieved in 3 steps", "run must finish on the extended budget"

    goal_turns = @shell.conversation_history.count { |m| m[:content].to_s.include?("Goal: Fix the failing spec") }
    assert_equal 1, goal_turns, "extended run must still record exactly one neutral goal pair"
    @shell.conversation_history.each { |m| refute_includes m[:content].to_s, "!goal" }
  end

  def test_goal_declined_extension_records_paired_failure
    @shell.execute_input("!steps goal 2")
    provider = MockScriptProvider.new([
                                        '{"tool": "list_files", "args": {}}',
                                        '{"tool": "list_files", "args": {}}'
                                      ])
    @shell.instance_variable_get(:@llm_registry).register("ollama", provider)
    # Non-interactive tests: ask_yes_no short-circuits to the default "n".

    @shell.execute_input("!goal Make every test pass")

    out = @output.string
    # Non-interactive ask_yes_no short-circuits to the default "n" — the
    # decline is observable through the ABSENCE of the extension banner.
    refute_includes out, "Adım bütçesi +20 artırılıyor", "declined extension must not resume"
    assert_includes out, "Goal could not be completed"

    contents = @shell.conversation_history.map { |m| m[:content].to_s }
    goal_idx = contents.index { |c| c == "Goal: Make every test pass" }
    refute_nil goal_idx, "failure must still record the neutral goal user turn"
    assert_match(/\A\[Goal attempt ended after 2 steps: /, contents[goal_idx + 1],
                 "failure must pair the goal turn with an assistant outcome note")
    contents.each { |c| refute_includes c, "!goal" }

    # read_history filters to input-side events; the raw session file is the
    # honest witness that an assistant_response event pairs the '!goal' turn.
    lines = File.readlines(@shell.recorder.session_file).map { |l| JSON.parse(l) }
    assert lines.any? { |e| e["type"] == "assistant_response" && e["payload"]["content"].to_s.include?("[Goal attempt ended after 2 steps") },
           "recorder must pair the '!goal' user_turn with an assistant_response for restore"
  end

  def test_failed_goal_session_restores_as_paired_dialogue
    @shell.execute_input("!steps goal 2")
    provider = MockScriptProvider.new([
                                        '{"tool": "list_files", "args": {}}',
                                        '{"tool": "list_files", "args": {}}'
                                      ])
    @shell.instance_variable_get(:@llm_registry).register("ollama", provider)
    @shell.execute_input("!goal Restore me paired")

    session_file = @shell.recorder.session_file
    refute_nil session_file

    out2 = StringIO.new
    shell2 = Rubik::REPL::Shell.new(config: @config, buffer_manager: Rubik::Buffer::Manager.new(root_dir: @temp_dir), output: out2)
    res = Rubik::Session::Manager.restore_session(shell2, session_file)
    assert res[:ok], "session restore must succeed: #{res[:error]}"

    contents = shell2.conversation_history.map { |m| m[:content].to_s }
    goal_idx = contents.index { |c| c == "Goal: Restore me paired" }
    refute_nil goal_idx, "restored history must hydrate the goal turn"
    assert_match(/\[Goal attempt ended/, contents[goal_idx + 1].to_s,
                 "restored goal turn must be followed by its failure note, not dangle unpaired")
    contents.each { |c| refute_includes c, "!goal" }
  ensure
    shell2&.stop
  end

  def test_goal_run_provides_live_goal_state_coeffect
    provider = MockScriptProvider.new([
                                        '{"tool": "list_files", "args": {}}',
                                        '{"tool": "finish", "args": { "message": "done" }}'
                                      ])
    @shell.instance_variable_get(:@llm_registry).register("ollama", provider)

    @shell.execute_input("!goal Track my state")

    state = @shell.runtime_manager.context.get(Rubik::Coeffects::GOAL_STATE)
    refute_nil state, "!goal must publish GoalState under the GOAL_STATE coeffect"
    assert_equal "Track my state", state.goal
    assert_equal :completed, state.status
    assert_operator state.step_count, :>, 0

    # Repeated runs reuse the swap semantics: same key, fresh state, still
    # exactly one delete-inverse registered.
    @shell.execute_input("!goal Track my state again")
    state2 = @shell.runtime_manager.context.get(Rubik::Coeffects::GOAL_STATE)
    assert_equal "Track my state again", state2.goal
    assert_equal :completed, state2.status
  end

  def test_goal_provider_client_error_fails_goal_and_pairs_session
    @shell.instance_variable_get(:@llm_registry).register(
      "ollama",
      ExplodingProvider.new(Rubik::LLM::ClientError.new("read timeout after 120s calling api.z.ai (model/server still working? request not retried)"))
    )

    # The provider error must terminate the goal through the failure channel,
    # never escape the bang-command dispatch.
    @shell.execute_input("!goal Review commit 2b0364e8")

    out = @output.string
    assert_includes out, "Goal could not be completed"
    assert_includes out, "read timeout after 120s"

    state = @shell.runtime_manager.context.get(Rubik::Coeffects::GOAL_STATE)
    assert_equal :failed, state.status, "provider error must fail the GoalState, not leave it running"
    assert_includes state.last_error, "read timeout after 120s"

    contents = @shell.conversation_history.map { |m| m[:content].to_s }
    goal_idx = contents.index { |c| c == "Goal: Review commit 2b0364e8" }
    refute_nil goal_idx, "failed run must still record the neutral goal user turn"
    assert_match(/\A\[Goal attempt ended after \d+ steps: read timeout after 120s/, contents[goal_idx + 1].to_s,
                 "provider failure must pair the goal turn with an assistant outcome note")

    lines = File.readlines(@shell.recorder.session_file).map { |l| JSON.parse(l) }
    assert lines.any? { |e| e["type"] == "assistant_response" && e["payload"]["content"].to_s.include?("read timeout after 120s") },
           "recorder must witness the provider-failure outcome for session restore"
  end

  def test_goal_unexpected_error_also_terminates_goal
    @shell.instance_variable_get(:@llm_registry).register(
      "ollama", ExplodingProvider.new(StandardError.new("boom"))
    )

    @shell.execute_input("!goal Explode mid-run")

    out = @output.string
    assert_includes out, "Goal could not be completed"
    assert_includes out, "boom"

    state = @shell.runtime_manager.context.get(Rubik::Coeffects::GOAL_STATE)
    assert_equal :failed, state.status
    assert_includes state.last_error, "boom"

    contents = @shell.conversation_history.map { |m| m[:content].to_s }
    goal_idx = contents.index { |c| c == "Goal: Explode mid-run" }
    assert_match(/\A\[Goal attempt ended after \d+ steps: .*boom/, contents[goal_idx + 1].to_s)
  end

  def test_command_dispatch_kills_leaked_spinner_on_both_branches
    kills = 0
    fake_spinner = Object.new
    fake_spinner.define_singleton_method(:kill) { kills += 1 }
    renderer = @shell.ui_renderer
    renderer.define_singleton_method(:spinner) { fake_spinner }

    # Untracked lifecycle branch (quit/exit/clear/reset/goal).
    @shell.execute_input("!clear")
    assert_equal 1, kills, "untracked command dispatch must kill a leaked spinner"

    # Tracked branch (!help) keeps the same guarantee.
    @shell.execute_input("!help")
    assert_equal 2, kills, "tracked command dispatch must keep its spinner guarantee"
  end

  # AGENTS.md §5: cleanup must never mask the in-flight exception. A spinner
  # whose tick thread died holding the mutex raises ThreadError from kill —
  # that must surface as a stderr report while the command's real failure
  # propagates, on both dispatch branches.
  def test_spinner_cleanup_failure_does_not_mask_command_errors
    raising_spinner = Object.new
    raising_spinner.define_singleton_method(:kill) { raise ThreadError, "spinner tick thread died holding the mutex" }
    renderer = @shell.ui_renderer
    original_spinner = renderer.method(:spinner)
    renderer.define_singleton_method(:spinner) { raising_spinner }
    begin
      @shell.register_command("explode", description: "always raises") { |*_args| raise StandardError, "kaboom" }
      # Overriding a lifecycle command routes the dispatch through the untracked branch.
      @shell.register_command("clear", description: "overridden to raise") { |*_args| raise StandardError, "kaboom" }

      error = nil
      _out, err = capture_io do
        error = assert_raises(StandardError) { @shell.execute_input("!clear") }
      end
      assert_equal "kaboom", error.message, "the spinner ThreadError must never replace the real command failure"
      assert_includes err, "spinner cleanup failed", "cleanup failure must be reported to stderr, not swallowed"
      assert_includes err, "ThreadError"

      error = nil
      capture_io do
        error = assert_raises(StandardError) { @shell.execute_input("!explode") }
      end
      assert_equal "kaboom", error.message, "tracked dispatch must keep the same never-masks guarantee"
    ensure
      renderer.define_singleton_method(:spinner, original_spinner)
    end
  end

  def test_goal_records_tool_steps_to_session_for_diagnosability
    mock_provider = MockScriptProvider.new([
                                             '{"tool": "list_files", "args": {}}',
                                             '{"tool": "finish", "args": { "message": "done" }}'
                                           ])
    @shell.instance_variable_get(:@llm_registry).register("ollama", mock_provider)

    @shell.execute_input("!goal Chronicle my tool steps")

    lines = File.readlines(@shell.recorder.session_file).map { |l| JSON.parse(l) }
    assert lines.any? { |e| e["type"] == "tool_call" && e["payload"]["tool"] == "list_files" },
           "goal on_step must record tool calls so a long goal run is diagnosable from the session"
    assert lines.any? { |e| e["type"] == "tool_result" && e["payload"]["tool"] == "list_files" },
           "goal on_step must record tool results so a long goal run is diagnosable from the session"
  end

  # ---- issue #106: suspend / resume ----

  def suspended_goal_via_transient_transport_failure
    @shell.instance_variable_get(:@llm_registry).register(
      "ollama",
      FlakyThenGoodProvider.new(
        [Rubik::LLM::ClientError.new("Network error calling api.example.com: SocketError (gave up after 2 retries)", transient: true)]
      )
    )
    @shell.execute_input("!goal Survive the DNS outage")
  end

  def test_transient_transport_error_suspends_goal_and_keeps_repl_alive
    suspended_goal_via_transient_transport_failure

    out = @output.string
    assert_includes out, "Suspended after", "a transient transport failure must suspend, not fail"
    assert_includes out, "!goal resume"

    state = @shell.runtime_manager.context.get(Rubik::Coeffects::GOAL_STATE)
    assert_equal :suspended, state.status, "GoalState must sit at SUSPENDED (≙ PENDING), counters preserved"
    assert_operator state.step_count, :>, 0
    assert_nil state.snapshot[:finished_at], "suspend is not terminal"

    registry = @shell.runtime_manager.context.get(Rubik::Coeffects::GOAL_REGISTRY)
    refute_nil registry, "the first suspension must provide the GOAL_REGISTRY coeffect"
    assert_equal 1, registry.size, "suspend/resume cycles rotate ONE entry (zero-restart)"
    assert_equal "Survive the DNS outage", registry.latest.goal_text

    contents = @shell.conversation_history.map { |m| m[:content].to_s }
    assert contents.any? { |c| c.start_with?("[Goal suspended after") },
           "the suspend must pair the goal turn in the session record (PR #105 discipline)"

    # Ω disiplini: anahtar başına tek delete-inverse — ikinci askı döngüsü
    # (provide-swap) accumulator'ı baseline'da tutmalı (§6 zero-restart).
    inverses_before = @shell.runtime_manager.context.instance_variable_get(:@service_inverses).size
    suspended_goal_via_transient_transport_failure
    assert_equal inverses_before,
                 @shell.runtime_manager.context.instance_variable_get(:@service_inverses).size,
                 "re-suspend must swap provide values, never stack inverses"
    # Ayrı !goal koşuları ayrı goal_id taşır (iki girdi); AYNI koşunun
    # suspend/resume döngüleri tek girdiyi döndürür (unit: 1000 döngü pin).
    registry = @shell.runtime_manager.context.get(Rubik::Coeffects::GOAL_REGISTRY)
    assert_equal 2, registry.size
    assert_equal "Survive the DNS outage", registry.latest.goal_text, "resume revives the MOST RECENT suspension"
  end

  def test_goal_resume_revives_the_same_loop_in_process
    suspended_goal_via_transient_transport_failure
    registry = @shell.runtime_manager.context.get(Rubik::Coeffects::GOAL_REGISTRY)
    suspended_loop = registry.latest.loop
    suspended_state = registry.latest.goal_state

    @shell.instance_variable_get(:@llm_registry).register(
      "ollama",
      FlakyThenGoodProvider.new([], ['{"tool": "finish", "args": {"message": "recovered and finished"}}'])
    )
    @shell.execute_input("!goal resume")

    out = @output.string
    assert_includes out, "Resuming 'Survive the DNS outage'"
    assert_includes out, "Goal Achieved"
    assert_same suspended_loop, registry.latest&.loop || suspended_loop, "the revived instance is the surviving Loop"
    assert_equal :completed, suspended_state.status, "resume ≙ Activating: the SAME GoalState runs to completion"

    assert registry.empty?, "terminal paths must delete the registry entry (no suspended row survives)"

    lines = File.readlines(@shell.recorder.session_file).map { |l| JSON.parse(l) }
    assert(lines.any? { |e| e["type"] == "assistant_response" && e["payload"]["content"].to_s.include?("[Goal suspended after") })
    # The resumed turn is driven by the SURVIVING loop — the provider
    # captured at suspend time (its fallback finish, "done"), NOT the
    # provider registered after. That continuity IS the in-process contract.
    assert lines.any? { |e| e["type"] == "assistant_response" && e["payload"]["content"].to_s.include?("done") },
           "the completion pair must come from the revived loop's own provider"
  end

  def test_resume_then_interrupt_abandons_the_suspension_as_stopped
    # State machine (issue #106): SUSPENDED —resume + immediate ^C→ :stopped
    # (the abandon path; no separate cancel command). The terminal stamp
    # overwrites the suspend stamp and the registry entry dies with it.
    suspended_goal_via_transient_transport_failure
    registry = @shell.runtime_manager.context.get(Rubik::Coeffects::GOAL_REGISTRY)
    entry = registry.latest
    state = entry.goal_state
    ledger = entry.ledger
    # The resumed turn runs the SURVIVING loop's own provider — arm IT with
    # the interrupt.
    entry.loop.provider.instance_variable_get(:@errors) << Interrupt.new

    @shell.execute_input("!goal resume")

    assert_equal :stopped, state.status, "^C on resume must land the abandon terminal"
    assert registry.empty?, "abandoning must delete the registry entry"
    assert ledger.snapshot[:finalized], "the abandon must finalize the ledger"
    store = @shell.runtime_manager.context.get(Rubik::Coeffects::STORAGE_STORE)
    assert_equal "stopped", store.get(type: "goal", id: ledger.snapshot[:storage_id])["status"],
                 "no suspended row may survive the abandon"
  end

  def test_permanent_transport_error_still_fails_goal_unchanged
    # The #105 regression pin, now with the flag EXPLICITLY false: a 4xx /
    # moderation / read-timeout class error must keep today's terminal path.
    @shell.instance_variable_get(:@llm_registry).register(
      "ollama",
      ExplodingProvider.new(Rubik::LLM::ClientError.new("HTTP Request failed with code 400: -20058 moderation", transient: false))
    )
    @shell.execute_input("!goal Moderation-blocked objective")

    out = @output.string
    assert_includes out, "Goal could not be completed"
    refute_includes out, "Suspended after", "a permanent error must never suspend"

    state = @shell.runtime_manager.context.get(Rubik::Coeffects::GOAL_STATE)
    assert_equal :failed, state.status
  end

  def test_goal_list_shows_suspended_rows_from_storage
    store = Rubik::Storage::Store.new(root: File.join(@temp_dir, "store"), project: "list-test")
    @shell.runtime_manager.provide(Rubik::Coeffects::STORAGE_STORE, store)
    ledger = Rubik::Orchestrator::GoalLedger::Ledger.create!(goal_text: "Park this one", store: store)
    ledger.suspend!(goal_id: "g-1", steps: 5, max_steps: 100, extensions: 0,
                    tokens: { input: 1, output: 1 }, reason: "DNS", suspended_at: Time.now.utc.iso8601, attempt: 1)

    @shell.execute_input("!goal list")

    out = @output.string
    assert_includes out, "=== Suspended goals ==="
    assert_includes out, ledger.snapshot[:storage_id]
    assert_includes out, "Park this one"
  end

  def test_cross_process_resume_rehydrates_from_the_sigma_stamp
    # Faz 2a acceptance: kill process → restart → resume. A fresh Shell
    # (empty session registry) rehydrates the suspended Σ row.
    store = Rubik::Storage::Store.new(root: File.join(@temp_dir, "store"), project: "cross-test")
    @shell.runtime_manager.provide(Rubik::Coeffects::STORAGE_STORE, store)
    ledger = Rubik::Orchestrator::GoalLedger::Ledger.create!(goal_text: "Outlive the restart", store: store)
    suspended_id = ledger.snapshot[:storage_id]
    ledger.suspend!(goal_id: "g-42", steps: 9, max_steps: 100, extensions: 0,
                    tokens: { input: 2, output: 3 }, reason: "DNS outage",
                    suspended_at: Time.now.utc.iso8601, attempt: 1)

    out2 = StringIO.new
    shell2 = Rubik::REPL::Shell.new(config: @config, buffer_manager: Rubik::Buffer::Manager.new(root_dir: @temp_dir), output: out2)
    shell2.runtime_manager.provide(Rubik::Coeffects::STORAGE_STORE, store)
    shell2.instance_variable_get(:@llm_registry).register(
      "ollama",
      FlakyThenGoodProvider.new([], ['{"tool": "finish", "args": {"message": "resumed across processes"}}'])
    )
    shell2.execute_input("!goal resume")

    out = out2.string
    assert_includes out, "Cross-process resume of 'Outlive the restart'"
    assert_includes out, "Subagent conversations did not survive", "the honest-continuity sentence"
    assert_includes out, "Goal Achieved"

    state = shell2.runtime_manager.context.get(Rubik::Coeffects::GOAL_STATE)
    assert_equal :completed, state.status
    assert_equal 10, state.step_count, "counters restored from the stamp (9) and continued (+1)"

    row = store.get(type: "goal", id: suspended_id)
    refute_equal "suspended", row["status"], "no suspended stamp may survive a resumed run"
    assert_equal "completed", row["status"], "the terminal finalize overwrites the stamp on the SAME row"
  ensure
    shell2&.stop
  end

  def test_resume_redirects_drift_at_the_first_resumed_step
    # Test invariant 4 (issue #106): a verify target that changed during
    # suspension is a SIGNAL, not a failure — the first resumed step's
    # boundary verification flips the task stale (rev bump), so the model's
    # next ΔΣ patch conflicts and it replans on the fresh world.
    store = Rubik::Storage::Store.new(root: File.join(@temp_dir, "store"), project: "drift-test")
    @shell.runtime_manager.provide(Rubik::Coeffects::STORAGE_STORE, store)
    flag = File.join(@temp_dir, "scratch", "flag.txt")
    FileUtils.mkdir_p(File.dirname(flag))
    File.write(flag, "present")

    ledger = Rubik::Orchestrator::GoalLedger::Ledger.create!(goal_text: "Watch the flag", store: store)
    ledger.update(JSON.generate({
                                  "rev" => 0,
                                  "ops" => [{ "op" => "add", "path" => "/tasks/-",
                                              "value" => { "id" => "t1", "title" => "Guard the flag", "status" => "doing",
                                                           "verify" => { "type" => "file_exists", "path" => "scratch/flag.txt" } } }]
                                }))
    rev_at_suspend = ledger.rev
    ledger.suspend!(goal_id: "g-drift", steps: 3, max_steps: 100, extensions: 0,
                    tokens: { input: 1, output: 1 }, reason: "DNS", suspended_at: Time.now.utc.iso8601, attempt: 1)

    # The world drifts while the goal is suspended.
    FileUtils.rm_rf(flag)

    out2 = StringIO.new
    shell2 = Rubik::REPL::Shell.new(config: @config, buffer_manager: Rubik::Buffer::Manager.new(root_dir: @temp_dir), output: out2)
    shell2.runtime_manager.provide(Rubik::Coeffects::STORAGE_STORE, store)
    shell2.instance_variable_get(:@llm_registry).register(
      "ollama",
      FlakyThenGoodProvider.new([], ['{"tool": "finish", "args": {"message": "replanned on drift"}}'])
    )
    shell2.execute_input("!goal resume")

    state = shell2.runtime_manager.context.get(Rubik::Coeffects::GOAL_STATE)
    assert_equal :completed, state.status
    rehydrated = shell2.runtime_manager.context.get(Rubik::Coeffects::GOAL_LEDGER)
    assert_operator rehydrated.rev, :>, rev_at_suspend, "the drift flip must bump the rev"
    task = rehydrated.snapshot_doc["tasks"].first
    assert_equal "stale", task["status"], "the first resumed step's verification must flip the drifted task"
    assert_equal "failed", task.dig("verify", "last_check", "state")
  ensure
    shell2&.stop
  end

  def test_goal_command_accepts_steps_flag
    provider = MockScriptProvider.new([
                                        '{"tool": "finish", "args": { "message": "completed with custom steps" }}'
                                      ])
    @shell.instance_variable_get(:@llm_registry).register("ollama", provider)

    @shell.execute_input("!goal --steps 175 Run custom step goal")

    out = @output.string
    assert_includes out, "Budget: 175 steps", "custom step flag must set the initial goal budget"
    state = @shell.runtime_manager.context.get(Rubik::Coeffects::GOAL_STATE)
    assert_equal 175, state.max_steps
  end

  def test_goal_auto_continues_without_prompt_when_configured
    @shell.execute_input("!steps goal 2")
    @config.set("agent.goal_auto_continue_limit", 1)
    provider = MockScriptProvider.new([
                                        '{"tool": "list_files", "args": {}}',
                                        '{"tool": "list_files", "args": {}}'
                                      ])
    @shell.instance_variable_get(:@llm_registry).register("ollama", provider)

    @shell.execute_input("!goal Auto continue goal")

    out = @output.string
    assert_includes out, "Otonom devam hakkı (1/1) kullanılarak +20 adım ekleniyor", "must auto-continue without prompting"
    assert_includes out, "Goal Achieved in 3 steps"
    state = @shell.runtime_manager.context.get(Rubik::Coeffects::GOAL_STATE)
    assert_equal 22, state.max_steps, "auto-extension must raise the visible goal budget (2 + 20)"
    assert_equal 1, state.extensions, "the auto path must be GoalState#extend! itself — continue_loop alone hides it (mutation-tested gap)"
  end

  def test_goal_rejects_non_positive_or_valueless_steps_flag
    provider = MockScriptProvider.new(['{"tool": "finish", "args": { "message": "must not run" }}'])
    @shell.instance_variable_get(:@llm_registry).register("ollama", provider)

    @shell.execute_input("!goal --steps 0 Zero budget must not start")
    @shell.execute_input("!goal --steps=abc Equals form with non-numeric value must not start")
    @shell.execute_input("!goal -s Missing value must not start")

    out = @output.string
    assert_equal 3, out.scan("--steps pozitif bir tam sayı bekliyor").length, "every invalid --steps form must be rejected"
    refute_includes out, "Starting autonomous goal loop", "no goal may start from an invalid flag"
  end
end
