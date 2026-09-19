# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestTaskManager < Minitest::Test
  def setup
    @guard = Rubik::Security::Guard.new
    @context = Rubik::Runtime::Context.new
    @task_manager = Rubik::Runtime::TaskManager.new(guard: @guard, context: @context)
  end

  def teardown
    @task_manager&.kill_all
    @context&.dispose unless @context&.disposed
  end

  # =========================================================================
  # RingBuffer Tests
  # =========================================================================

  def test_ring_buffer_fifo_eviction
    buf = Rubik::Runtime::RingBuffer.new(5)
    10.times { |i| buf.push("line-#{i}") }

    assert_equal 5, buf.size
    assert_equal ["line-5", "line-6", "line-7", "line-8", "line-9"], buf.tail(10)
    assert_equal ["line-8", "line-9"], buf.tail(2)
  end

  def test_ring_buffer_thread_safety
    buf = Rubik::Runtime::RingBuffer.new(100)
    threads = 5.times.map do |t|
      Thread.new do
        20.times { |i| buf.push("t#{t}-#{i}") }
      end
    end
    threads.each(&:join)

    assert_equal 100, buf.size
  end

  def test_ring_buffer_clear_and_empty
    buf = Rubik::Runtime::RingBuffer.new(10)
    assert buf.empty?
    buf.push("hello")
    refute buf.empty?
    buf.clear
    assert buf.empty?
    assert_equal 0, buf.size
  end

  # =========================================================================
  # TaskManager Lifecycle Tests
  # =========================================================================

  def test_start_and_completion_of_successful_command
    task = @task_manager.start('ruby -e "puts %(RUBIK_TASK_OK)"')
    assert_equal "task-1", task.id
    assert task.pid.positive?

    # Wait briefly for process to finish
    deadline = Time.now + 5
    sleep 0.05 while task.running? && Time.now < deadline

    assert_equal :completed, task.status
    assert_equal 0, task.exit_code
    logs = @task_manager.logs(task.id)
    assert_includes logs, "RUBIK_TASK_OK"
  end

  def test_start_and_failure_of_erroneous_command
    task = @task_manager.start('ruby -e "exit 42"')

    deadline = Time.now + 5
    sleep 0.05 while task.running? && Time.now < deadline

    assert_equal :failed, task.status
    assert_equal 42, task.exit_code
  end

  def test_pipe_deadlock_immunity_with_large_output
    # Generate 5,000 lines (far exceeds typical OS pipe buffer capacity)
    task = @task_manager.start('ruby -e "5000.times { |i| puts %(chunk_line_) + i.to_s }"')

    deadline = Time.now + 10
    sleep 0.05 while task.running? && Time.now < deadline

    assert_equal :completed, task.status
    logs = @task_manager.logs(task.id, tail: 50)
    assert_equal 50, logs.size
    assert logs.last.start_with?("chunk_line_")
  end

  def test_stdin_data_interaction
    task = @task_manager.start('ruby -e "$stdout.sync = true; input = gets; puts %(RESPONSE:) + input.strip"')

    sleep 0.2 # allow process to start and wait for gets
    assert task.running?

    ok = @task_manager.send_input(task.id, "ping_from_test")
    assert ok

    deadline = Time.now + 5
    sleep 0.05 while task.running? && Time.now < deadline

    assert_equal :completed, task.status
    logs = @task_manager.logs(task.id)
    assert_includes logs, "RESPONSE:ping_from_test"
  end

  def test_kill_running_process
    task = @task_manager.start('ruby -e "sleep 30"')
    assert task.running?

    killed = @task_manager.kill(task.id)
    assert killed
    assert_equal :killed, task.status

    sleep 0.2
    refute task.running?
  end

  def test_spatiotemporal_context_rollback_kills_process
    scoped_ctx = @context.extend
    task = @task_manager.start('ruby -e "sleep 30"', ctx: scoped_ctx)
    assert task.running?

    # Disposing scoped context should trigger LIFO inverse kill
    scoped_ctx.dispose

    sleep 0.2
    assert_equal :killed, task.status
    refute task.running?
  end

  def test_security_guard_blocks_dangerous_command
    assert_raises(Rubik::Security::BlockedWriteError) do
      @task_manager.start("rm -rf /")
    end
    assert_empty @task_manager.list
  end

  # =========================================================================
  # ManageTaskTool Tests
  # =========================================================================

  def test_manage_task_tool_actions
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager, guard: @guard, runtime_context: @context)

    # 1. Action: start
    start_res = tool.execute("action" => "start", "command" => 'ruby -e "$stdout.sync = true; puts %(TOOL_OK); sleep 10"')
    assert_includes start_res, "Task started: task-1"
    assert_includes start_res, "RUNNING"

    # 2. Action: list
    list_res = tool.execute("action" => "list")
    assert_includes list_res, "=== Background Tasks (1) ==="
    assert_includes list_res, "[task-1] RUNNING"

    # 3. Action: status
    status_res = tool.execute("action" => "status", "task_id" => "task-1")
    assert_includes status_res, "Task: task-1"
    assert_includes status_res, "Status: RUNNING"

    # 4. Action: logs
    deadline = Time.now + 5
    task = @task_manager.get("task-1")
    sleep 0.05 while task&.ring_buffer&.empty? && Time.now < deadline

    logs_res = tool.execute("action" => "logs", "task_id" => "task-1")
    assert_includes logs_res, "TOOL_OK"

    # 5. Action: kill
    kill_res = tool.execute("action" => "kill", "task_id" => "task-1")
    assert_includes kill_res, "Task 'task-1' killed."

    # 6. Action: status after kill
    status_after = tool.execute("action" => "status", "task_id" => "task-1")
    assert_includes status_after, "Status: KILLED"
  end

  def test_manage_task_tool_validation_and_errors
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager, guard: @guard, runtime_context: @context)

    # Missing command
    res1 = tool.execute("action" => "start", "command" => "")
    assert_includes res1, "Missing required parameter 'command'"

    # Missing task_id
    res2 = tool.execute("action" => "status")
    assert_includes res2, "Missing required parameter 'task_id'"

    # Nonexistent task
    res3 = tool.execute("action" => "status", "task_id" => "nonexistent-99")
    assert_includes res3, "not found"

    # Blocked command
    res4 = tool.execute("action" => "start", "command" => "rm -rf /")
    assert(res4.include?("Security blocked:") || res4.include?("Dangerous command execution blocked"))
  end

  # =========================================================================
  # RunCommandTool Background Delegation
  # =========================================================================

  def test_run_command_tool_background_delegation
    runner = Rubik::Sandbox::Runner.new(root_dir: Dir.pwd)
    run_cmd = Rubik::Tools::RunCommandTool.new(
      guard: @guard,
      runner: runner,
      task_manager: @task_manager,
      runtime_context: @context
    )

    res = run_cmd.execute(
      "command" => 'ruby -e "$stdout.sync = true; puts %(RUN_CMD_BG); sleep 10"',
      "background" => true
    )
    assert_includes res, "Command dispatched to background task [task-1]"

    task = @task_manager.get("task-1")
    assert task
    assert task.running?

    @task_manager.kill(task.id)
  end

  # =========================================================================
  # REPL !tasks Command Tests
  # =========================================================================

  def test_repl_tasks_command
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(output: out)

    # List empty
    shell.execute_command(Rubik::REPL::CommandParser.parse("!tasks"))
    assert_includes out.string, "No background tasks currently running"

    # Start a task via tool
    tool = shell.tool_registry.get("manage_task")
    tool.execute("action" => "start", "command" => 'ruby -e "$stdout.sync = true; puts %(REPL_TASK); sleep 10"')

    out.reopen
    shell.execute_command(Rubik::REPL::CommandParser.parse("!tasks"))
    assert_includes out.string, "task-1"
    assert_includes out.string, "RUNNING"

    # Kill task via REPL command
    out.reopen
    shell.execute_command(Rubik::REPL::CommandParser.parse("!tasks kill task-1"))
    assert_includes out.string, "Task 'task-1' killed."

    shell.stop
  end
end
