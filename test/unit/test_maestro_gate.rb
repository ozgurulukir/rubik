# frozen_string_literal: true

require_relative "../test_helper"

# Pins for the maestro gate: the maestro's direct execution tools (write_file,
# replace_file_content, run_command, run_tests) are REFUSED at the
# StepExecutor boundary and redirected to subagents, in every mode
# (user ruling 2026-10-01, opencode-personal finding). Read-only tools
# and finish stay direct; subagents never hit this path.
class TestMaestroGate < Minitest::Test
  def setup
    @ws_root = mint_test_root
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @ws_root)
    @registry = Rubik::Tools::Registry.build_default(buffer_manager: @buffer_manager, root_dir: @ws_root)
    @history = []
  end

  def teardown
    remove_temp_dir(@ws_root) if @ws_root
  end

  def executor(config = {})
    shell = Struct.new(:config).new(config.merge("llm.stream" => false))
    registry = @registry
    buffer = @buffer_manager
    history = @history
    invalid_count = 0
    loop_mock = Object.new
    loop_mock.define_singleton_method(:tool_registry) { registry }
    loop_mock.define_singleton_method(:buffer_manager) { buffer }
    loop_mock.define_singleton_method(:shell) { shell }
    loop_mock.define_singleton_method(:lsp_manager) { nil }
    loop_mock.define_singleton_method(:config) { shell.config }
    loop_mock.define_singleton_method(:on_step) { ->(_ev) {} }
    loop_mock.define_singleton_method(:history) { history }
    loop_mock.define_singleton_method(:step_count) { 1 }
    loop_mock.define_singleton_method(:max_steps) { 40 }
    loop_mock.define_singleton_method(:total_tokens) { 0 }
    loop_mock.define_singleton_method(:invalid_tool_count) { invalid_count }
    loop_mock.define_singleton_method(:invalid_tool_count=) { |v| invalid_count = v }
    loop_mock.define_singleton_method(:last_turn_streamed) { false }
    Rubik::Orchestrator::StepExecutor.new(loop_mock)
  end

  def refused_call?(res, tool)
    res.nil? && @history.last[:role] == "tool" && @history.last[:status] == :error &&
      @history.last[:content].include?("Maestro doctrine") && @history.last[:tool_name] == tool
  end

  def test_gate_refuses_all_four_execution_tools
    exec = executor
    { "write_file" => { "path" => "a.rb", "content" => "x" },
      "replace_file_content" => { "path" => "a.rb", "target_content" => "x", "replacement_content" => "y" },
      "run_command" => { "command" => "echo hi" },
      "run_tests" => {} }.each do |tool, args|
      res = exec.execute_single_tool_call({ "tool" => tool, "args" => args, "id" => "c-#{tool}" }, "")
      assert refused_call?(res, tool), "#{tool} must be refused with maestro redirect"
      assert_includes @history.last[:content], "invoke_subagent", "refusal teaches the delegated path"
    end
    assert_empty @buffer_manager.dirty_files, "nothing was staged — the calls never executed"
  end

  def test_gate_blocks_task_start_but_not_task_management
    exec = executor
    res = exec.execute_single_tool_call(
      { "tool" => "manage_task", "args" => { "action" => "start", "command" => "npm run dev" }, "id" => "c-t" }, ""
    )
    assert refused_call?(res, "manage_task"), "task start is a background shell — run_command equivalent"

    # list/status/logs/kill are orchestration-adjacent: they pass through
    # (the TaskManager coeffect is absent in this mock, so the tool itself
    # errors — the point is the GATE did not intercept it).
    @history.clear
    exec.execute_single_tool_call({ "tool" => "manage_task", "args" => { "action" => "list" }, "id" => "c-l" }, "")
    refute_includes @history.last[:content].to_s, "Maestro doctrine", "non-start task actions are not gated"
  end

  def test_gate_keeps_read_only_and_finish_direct
    exec = executor
    exec.execute_single_tool_call({ "tool" => "list_files", "args" => { "path" => "." }, "id" => "c-r" }, "")
    assert_equal :ok, @history.last[:status], "read-only tools stay direct"
    refute_includes @history.last[:content], "Maestro doctrine"

    res = exec.execute_single_tool_call({ "tool" => "finish", "args" => { "message" => "done" } }, "all done")
    assert res[:ok], "finish stays reachable (goal-mode completion)"
  end

  def test_gate_is_config_toggleable
    exec = executor("subagents" => { "maestro_gate" => false })
    exec.execute_single_tool_call({ "tool" => "write_file", "args" => { "path" => "ok.txt", "content" => "y" }, "id" => "c-w" }, "")
    assert_equal :ok, @history.last[:status], "gate off (subagents.maestro_gate: false) restores direct execution"
    assert_equal "y", @buffer_manager.read("ok.txt")
  end

  def test_gate_defaults_on_without_shell_config
    registry = @registry
    buffer = @buffer_manager
    history = @history
    loop_mock = Object.new
    loop_mock.define_singleton_method(:tool_registry) { registry }
    loop_mock.define_singleton_method(:buffer_manager) { buffer }
    loop_mock.define_singleton_method(:shell) { nil }
    loop_mock.define_singleton_method(:config) { nil }
    loop_mock.define_singleton_method(:on_step) { ->(_ev) {} }
    loop_mock.define_singleton_method(:lsp_manager) { nil }
    loop_mock.define_singleton_method(:history) { history }
    loop_mock.define_singleton_method(:step_count) { 1 }
    loop_mock.define_singleton_method(:max_steps) { 40 }
    loop_mock.define_singleton_method(:total_tokens) { 0 }
    invalid_count = 0
    loop_mock.define_singleton_method(:invalid_tool_count) { invalid_count }
    loop_mock.define_singleton_method(:invalid_tool_count=) { |v| invalid_count = v }
    bare = Rubik::Orchestrator::StepExecutor.new(loop_mock)

    res = bare.execute_single_tool_call({ "tool" => "write_file", "args" => { "path" => "a.txt", "content" => "x" }, "id" => "c-b" }, "")
    assert refused_call?(res, "write_file"), "no shell/config -> gate defaults ON (the doctrine is the default)"
  end

  def test_refusal_does_not_burn_invalid_tool_budget
    exec = executor
    3.times { |i| exec.execute_single_tool_call({ "tool" => "write_file", "args" => { "path" => "a.rb", "content" => "x" }, "id" => "c#{i}" }, "") }
    assert_equal 0, @history.count { |h| h[:content].to_s.include?("does not exist") },
                 "refusals are delegations, not invalid calls — no invalid-tool escalation"
  end

  def test_subagent_dispatch_is_never_gated
    inst = Rubik::Orchestrator::Subagent::Instance.new(
      id: "subagent-g", parent_id: "agent-0", role: "Coder", type_name: "coder",
      prompt: "work", context: nil, tool_registry: nil,
      max_steps: 3, root_dir: @ws_root
    )
    # execute_subagent_tool_call reads no lifecycle state — the tool seam
    # needs no running worker, only the budget and registry below.
    inst.instance_variable_set(:@budget, Rubik::Orchestrator::Subagent::Budget.new(max_steps: 3))
    fake = Object.new
    fake.define_singleton_method(:name) { "write_file" }
    fake.define_singleton_method(:execute) { |args| "WROTE #{args['path']}" }
    reg = Rubik::Tools::Registry.new
    reg.register(fake)
    inst.instance_variable_set(:@tool_registry, reg)

    result = inst.execute_subagent_tool_call({ "id" => "c1", "tool" => "write_file", "args" => { "path" => "s.txt" } })
    assert_nil result
    refute_includes inst.history.last[:content], "Maestro doctrine",
                    "subagents execute edit tools directly — the gate lives only on the root StepExecutor"
    assert_includes inst.history.last[:content], "WROTE s.txt"
    # The canonical row superset: subagent rows carry status + duration_ms
    # like every other channel (no wire reader — observability only).
    assert_equal :ok, inst.history.last[:status]
    assert_kind_of Float, inst.history.last[:duration_ms]
    assert_equal "c1", inst.history.last[:tool_call_id]
  end
end
