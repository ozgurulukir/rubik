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
end
