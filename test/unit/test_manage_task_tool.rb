# frozen_string_literal: true

require_relative "../test_helper"

class TestManageTaskTool < Minitest::Test
  def setup
    @guard = Rubik::Security::Guard.new(command_allowlist: ["ruby"])
    @context = Rubik::Runtime::Context.new
    @task_manager = Rubik::Runtime::TaskManager.new(guard: @guard, context: @context)
  end

  def teardown
    @task_manager&.kill_all
    @context&.dispose unless @context&.disposed?
  end

  # =========================================================================
  # Tool Metadata & Declaration Tests
  # =========================================================================

  def test_tool_declaration_metadata
    tool = Rubik::Tools::ManageTaskTool.new

    assert_equal "manage_task", tool.name
    assert_equal :execute, tool.risk
    assert_includes tool.aliases, "task"
    assert_includes tool.aliases, "tasks"
    assert_includes tool.aliases, "background_task"
    assert_includes tool.aliases, "bg_task"
    assert_equal [Rubik::Coeffects::TASK_MANAGER], Rubik::Tools::ManageTaskTool::REQUIRES

    schema = tool.params_schema
    assert_equal "object", schema[:type]
    assert_equal ["action"], schema[:required]
    assert_equal ["start", "list", "status", "logs", "send_input", "kill"], schema[:properties][:action][:enum]
  end

  # =========================================================================
  # TaskManager Resolution Tests
  # =========================================================================

  def test_resolves_task_manager_from_direct_injection
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager)
    res = tool.execute("action" => "list")

    assert_equal "No background tasks currently running or tracked.", res.to_s
  end

  def test_resolves_task_manager_from_runtime_context
    ctx = Rubik::Runtime::Context.new
    ctx.provide(Rubik::Coeffects::TASK_MANAGER, @task_manager)

    tool = Rubik::Tools::ManageTaskTool.new(runtime_context: ctx)
    res = tool.execute("action" => "list")

    assert_equal "No background tasks currently running or tracked.", res.to_s
  ensure
    ctx&.dispose
  end

  def test_returns_error_when_task_manager_unavailable
    tool = Rubik::Tools::ManageTaskTool.new
    res = tool.execute("action" => "list")

    assert res.error?
    assert_includes res.to_s, "TaskManager is not available in the runtime context."
  end

  # =========================================================================
  # Action: start
  # =========================================================================

  def test_start_missing_command
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager)
    res = tool.execute("action" => "start")

    assert res.error?
    assert_includes res.to_s, "Missing required parameter 'command' for action 'start'."
  end

  def test_start_command_alias_normalization
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager, runtime_context: @context)

    res = tool.execute("action" => "start", "cmd" => 'ruby -e "sleep 5"')
    refute res.respond_to?(:error?) && res.error?
    assert_includes res.to_s, "Task started: task-1"
    assert_includes res.to_s, "Command: ruby -e \"sleep 5\""
    assert_includes res.to_s, "Status: RUNNING"
  end

  # =========================================================================
  # Action: list
  # =========================================================================

  def test_list_empty_tasks
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager)
    res = tool.execute("action" => "list")

    assert_equal "No background tasks currently running or tracked.", res.to_s
  end

  def test_list_multiple_tasks
    task1 = @task_manager.start('ruby -e "sleep 5"')
    task2 = @task_manager.start('ruby -e "exit 0"')

    deadline = Time.now + 5
    sleep 0.05 while task2.running? && Time.now < deadline

    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager)
    res = tool.execute("action" => "list")

    assert_includes res.to_s, "=== Background Tasks (2) ==="
    assert_includes res.to_s, "[#{task1.id}] RUNNING"
    assert_includes res.to_s, "[#{task2.id}] COMPLETED"
  end

  # =========================================================================
  # Action: status
  # =========================================================================

  def test_status_missing_task_id
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager)
    res = tool.execute("action" => "status")

    assert res.error?
    assert_includes res.to_s, "Missing required parameter 'task_id' for action 'status'."
  end

  def test_status_nonexistent_task
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager)
    res = tool.execute("action" => "status", "task_id" => "task-999")

    assert res.error?
    assert_includes res.to_s, "Task 'task-999' not found."
  end

  def test_status_task_id_camel_case_and_symbol_keys
    task = @task_manager.start('ruby -e "sleep 5"')
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager)

    res = tool.execute(action: "status", taskId: task.id)
    refute res.respond_to?(:error?) && res.error?
    assert_includes res.to_s, "Task: #{task.id}"
    assert_includes res.to_s, "Status: RUNNING"
    assert_includes res.to_s, "PID: #{task.pid}"
    assert_includes res.to_s, "Command: ruby -e \"sleep 5\""
  end

  # =========================================================================
  # Action: logs
  # =========================================================================

  def test_logs_missing_task_id
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager)
    res = tool.execute("action" => "logs")

    assert res.error?
    assert_includes res.to_s, "Missing required parameter 'task_id' for action 'logs'."
  end

  def test_logs_nonexistent_task
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager)
    res = tool.execute("action" => "logs", "task_id" => "task-999")

    assert res.error?
    assert_includes res.to_s, "Task 'task-999' not found."
  end

  def test_logs_empty_buffer
    task = @task_manager.start('ruby -e "sleep 5"')
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager)

    res = tool.execute("action" => "logs", "task_id" => task.id)
    assert_equal "No logs recorded for task '#{task.id}' yet.", res.to_s
  end

  def test_logs_with_tail_limit
    task = @task_manager.start('ruby -e "STDOUT.sync = true; 10.times { |i| puts %(line_) + i.to_s }"')

    deadline = Time.now + 5
    sleep 0.05 while task.running? && Time.now < deadline

    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager)
    res = tool.execute("action" => "logs", "task_id" => task.id, "tail" => 3)

    assert_includes res.to_s, "=== Logs for #{task.id} (last 3 lines) ==="
    assert_includes res.to_s, "line_7\nline_8\nline_9"
  end

  # =========================================================================
  # Action: send_input
  # =========================================================================

  def test_send_input_missing_parameters
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager)

    res1 = tool.execute("action" => "send_input")
    assert res1.error?
    assert_includes res1.to_s, "Missing required parameter 'task_id' for action 'send_input'."

    res2 = tool.execute("action" => "send_input", "task_id" => "task-1")
    assert res2.error?
    assert_includes res2.to_s, "Missing required parameter 'input' for action 'send_input'."
  end

  def test_send_input_success_and_failure
    mock_mgr = Minitest::Mock.new
    mock_mgr.expect(:send_input, true, ["task-1", "hello"])
    mock_mgr.expect(:send_input, false, ["task-2", "hello"])

    tool = Rubik::Tools::ManageTaskTool.new(task_manager: mock_mgr)

    res_ok = tool.execute("action" => "send_input", "task_id" => "task-1", "input" => "hello")
    assert_equal "Input sent to task 'task-1'.", res_ok.to_s

    res_fail = tool.execute("action" => "send_input", "task_id" => "task-2", "input" => "hello")
    assert res_fail.error?
    assert_includes res_fail.to_s, "Failed to send input to task 'task-2'. Task may not be running or stdin is closed."

    mock_mgr.verify
  end

  # =========================================================================
  # Action: kill
  # =========================================================================

  def test_kill_missing_task_id
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager)
    res = tool.execute("action" => "kill")

    assert res.error?
    assert_includes res.to_s, "Missing required parameter 'task_id' for action 'kill'."
  end

  def test_kill_nonexistent_task
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager)
    res = tool.execute("action" => "kill", "task_id" => "task-999")

    assert res.error?
    assert_includes res.to_s, "Task 'task-999' not found."
  end

  def test_kill_running_and_already_killed_task
    task = @task_manager.start('ruby -e "sleep 10"')
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager)

    res_kill = tool.execute("action" => "kill", "task_id" => task.id)
    assert_includes res_kill.to_s, "Task '#{task.id}' killed. (PID #{task.pid})"

    res_again = tool.execute("action" => "kill", "task_id" => task.id)
    assert_includes res_again.to_s, "Task '#{task.id}' is already KILLED"
  end

  # =========================================================================
  # Action: Unknown
  # =========================================================================

  def test_unknown_action
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager)
    res = tool.execute("action" => "fly")

    assert res.error?
    assert_includes res.to_s, "Unknown action 'fly'. Allowed actions: start, list, status, logs, send_input, kill."
  end

  # =========================================================================
  # Error Handling & Security Boundary
  # =========================================================================

  def test_handles_security_blocked_write_error
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager)
    res = tool.execute("action" => "start", "command" => "rm -rf /")

    assert res.error?
    assert_includes res.to_s, "Security blocked:"
  end

  def test_catches_standard_error_during_execution
    mock_mgr = Object.new
    def mock_mgr.list
      raise StandardError, "custom internal failure"
    end

    tool = Rubik::Tools::ManageTaskTool.new(task_manager: mock_mgr)
    res = tool.execute("action" => "list")

    assert res.error?
    assert_equal "manage_task error (list): custom internal failure", res.to_s
  end
end
