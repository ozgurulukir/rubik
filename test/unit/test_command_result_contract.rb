# frozen_string_literal: true

require_relative "../test_helper"

# Issue #127: command exit status and result metadata survive BOTH dispatch
# paths. A failed command is an error outcome with a machine-readable exit
# code — never inferred from display text — and authorization denial states
# that nothing executed.
class TestCommandResultContract < Minitest::Test
  class DummyLoop
    attr_accessor :step_count, :max_steps, :history, :invalid_tool_count, :total_tokens, :last_turn_streamed,
                  :buffer_manager, :shell, :lsp_manager, :tool_registry, :config, :on_step

    def initialize(registry)
      @step_count = 1
      @max_steps = 10
      @history = []
      @invalid_tool_count = 0
      @total_tokens = 0
      @last_turn_streamed = false
      @buffer_manager = nil
      @shell = nil
      @lsp_manager = nil
      @tool_registry = registry
      @config = nil
      @on_step = ->(_evt) {}
    end
  end

  def setup
    @tmp = Dir.mktmpdir("rubik_cmd_result")
    @guard = Object.new
    @guard.define_singleton_method(:verify_command_safety!) { |_cmd| nil }
  end

  def teardown
    remove_temp_dir(@tmp) if @tmp && File.directory?(@tmp)
  end

  def runner_for(success:, exit_code:, output:)
    runner = Object.new
    result = { ok: success, exit_code: exit_code, output: output, duration: 0.01 }
    runner.define_singleton_method(:run) { |_cmd, **_opts| result }
    runner
  end

  def tool_for(runner)
    Rubik::Tools::RunCommandTool.new(guard: @guard, runner: runner, root_dir: @tmp)
  end

  # ---------------------------------------------------- tool-level contract

  def test_exit_zero_yields_success_with_exit_code_zero
    result = tool_for(runner_for(success: true, exit_code: 0, output: "all good")).execute("command" => "echo hi")

    assert_kind_of Rubik::Tools::Result, result
    assert_equal :ok, result.status
    assert_equal 0, result.exit_code
    assert_includes result.output, "[OK] all good"
    assert_equal true, result.metadata["executed"]
    refute result.metadata["timed_out"]
  end

  def test_nonzero_exit_is_an_error_with_machine_readable_exit_code
    result = tool_for(runner_for(success: false, exit_code: 3, output: "boom")).execute("command" => "false")

    assert_equal :error, result.status
    assert_equal 3, result.exit_code
    refute result.ok?
    assert_includes result.output, "[EXIT 3]"
    assert_includes result.error, "3"
    assert_equal true, result.metadata["executed"]
    refute result.metadata["timed_out"]
  end

  def test_timeout_is_reported_with_its_exit_code_and_metadata
    result = tool_for(runner_for(success: false, exit_code: 124, output: "Execution timed out after 1 seconds"))
             .execute("command" => "sleep 10", "timeout" => 1)

    assert_equal :error, result.status
    assert_equal 124, result.exit_code
    assert_equal true, result.metadata["timed_out"]
    assert_includes result.output, "timed out"
  end

  def test_output_text_cannot_fabricate_a_timeout
    [0, 3].each do |code|
      result = tool_for(runner_for(success: code.zero?, exit_code: code, output: "previous operation timed out"))
               .execute("command" => "echo report")
      refute result.metadata["timed_out"], "timeout classification must come from the runner exit code"
      assert_equal code, result.exit_code
    end
  end

  def test_authorization_denial_says_nothing_executed_and_fabricates_no_exit_code
    denying = Object.new
    blocked = Rubik::Security::BlockedWriteError.new("rm -rf / was denied (rule: rm)")
    denying.define_singleton_method(:verify_command_safety!) { |_cmd| raise blocked }
    tool = Rubik::Tools::RunCommandTool.new(guard: denying,
                                            runner: runner_for(success: true, exit_code: 0, output: "SHOULD NOT RUN"),
                                            root_dir: @tmp)

    result = tool.execute("command" => "rm -rf /")

    assert_equal :error, result.status
    assert_nil result.exit_code, "a denied command never fabricates a process exit code"
    assert_equal false, result.metadata["executed"]
    assert_equal "authorization", result.metadata["denied"]
    assert_includes result.output, "Security blocked"
  end

  # ------------------------------------------------- root dispatch parity

  def test_root_dispatch_preserves_exit_code_and_metadata_in_history_and_event
    events = []
    registry = Rubik::Tools::Registry.new
    registry.register(tool_for(runner_for(success: false, exit_code: 3, output: "boom")))
    loop_inst = DummyLoop.new(registry)
    loop_inst.on_step = ->(evt) { events << evt }
    executor = Rubik::Orchestrator::StepExecutor.new(loop_inst)

    result = executor.execute_registered_tool(registry.get("run_command"), "run_command",
                                              { "command" => "false" }, "c1", "manual")

    assert_equal :error, result.status
    assert_equal 3, result.exit_code

    row = loop_inst.history.last
    assert_equal :error, row[:status]
    assert_equal 3, row[:exit_code]
    assert_equal true, row[:metadata]["executed"]
    assert_includes row[:content], 'exit_code="3"', "the Result XML envelope exposes the machine-readable exit code"

    event = events.find { |e| e[:type] == :tool_result }
    refute_nil event
    assert_equal 3, event[:exit_code]
    assert_equal true, event[:metadata]["executed"]
  end

  # --------------------------------------------- subagent dispatch parity

  def test_subagent_dispatch_preserves_exit_code_metadata_and_truncation
    buffer = Rubik::Buffer::Manager.new(root_dir: @tmp)
    registry = Rubik::Tools::Registry.build_default(buffer_manager: buffer, root_dir: @tmp)
    registry.register(tool_for(runner_for(success: false, exit_code: 3, output: "y" * 30_000)))
    config = Rubik::Config.new(root_dir: @tmp)
    config.set("tools.max_output_chars", 400, persist: false)
    config.set("tools.max_output_lines", 5, persist: false)

    calls = 0
    resp_tool = Struct.new(:content, :tool_calls).new("Working", [{ "id" => "c1", "tool" => "run_command", "args" => { "command" => "false" } }])
    resp_done = Struct.new(:content, :tool_calls).new("Done", [])
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| (calls += 1) == 1 ? resp_tool : resp_done }

    root_context = Rubik::Runtime::Context.new
    sup = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: root_context, event_bus: Rubik::EventBus.new, root_dir: @tmp,
      provider: provider, tool_registry: registry, buffer_manager: buffer, config: config
    )
    inst = sup.spawn(role: "Exec", prompt: "run it", type_name: "coder", max_steps: 3)
    assert(wait_until(5) { inst.terminal_and_settled? })

    row = inst.history.find { |m| m[:role] == "tool" }
    refute_nil row
    assert_equal :error, row[:status], "a failed command is an error outcome, not 'ok with [EXIT 3] text'"
    assert_equal 3, row[:exit_code]
    assert_equal true, row[:metadata]["executed"]
    assert_includes row[:content], "[EXIT 3]"
    assert_operator row[:content].length, :<, 1000, "truncation bounds the display text"

    journal = Rubik::Orchestrator::Subagent::Journal.read(inst.journal_path)
    tool_result = journal.records.find { |r| r["event"] == "tool_result" }
    refute_nil tool_result
    assert_equal 3, tool_result["data"]["exit_code"], "the journal exposes the exit code without parsing display text"
    assert tool_result["data"]["output_truncated"]
  ensure
    sup&.shutdown_all
    root_context&.dispose unless root_context&.disposed?
  end

  private

  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now >= deadline
    yield
  end
end
