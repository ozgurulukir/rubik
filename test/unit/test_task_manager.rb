# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestTaskManager < Minitest::Test
  def setup
    # Plan 111 F1: `ruby` is database-less and fail-closed at the command
    # gate — these tests play the operator allowlisting the interpreter.
    @guard = Rubik::Security::Guard.new(command_allowlist: ["ruby"])
    @context = Rubik::Runtime::Context.new
    @task_manager = Rubik::Runtime::TaskManager.new(guard: @guard, context: @context)
  end

  def teardown
    @task_manager&.kill_all
    @context&.dispose unless @context&.disposed?
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
    # The fixture must survive a POSIX shell: `$stdout` inside double quotes
    # is expanded by /bin/sh to the EMPTY string before ruby ever sees it,
    # leaving `.sync = true; ...` — an instant SyntaxError, exit 1 (#103).
    # STDOUT is the same object with no shell metacharacters; cmd.exe passes
    # it through byte-identically, so the fixture is platform-neutral.
    task = @task_manager.start('ruby -e "STDOUT.sync = true; puts %(READY); input = gets; puts %(RESPONSE:) + input.strip"')

    # State polling, not a fixed ready-sleep: READY in the ring buffer
    # proves the child booted and is blocked in gets — running? is then a
    # meaningful assertion even on a slow CI runner.
    deadline = Time.now + 5
    sleep 0.05 while task.ring_buffer.empty? && Time.now < deadline
    assert_includes @task_manager.logs(task.id), "READY"
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

    # 1. Action: start (STDOUT, not $stdout — the shell would expand the
    #    latter to nothing and the child would die with a SyntaxError, then
    #    lose the kill race as already-FAILED, #103)
    start_res = tool.execute("action" => "start", "command" => 'ruby -e "STDOUT.sync = true; puts %(TOOL_OK); sleep 10"')
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
      "command" => 'ruby -e "STDOUT.sync = true; puts %(RUN_CMD_BG); sleep 10"',
      "background" => true
    )
    assert_includes res.to_s, "Command dispatched to background task [task-1]"

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
    # Plan 111 F1: `ruby` is database-less and fail-closed — the fixture
    # plays the operator allowlisting the interpreter for this shell.
    shell.guard.set_allowed_commands(["ruby"])

    # List empty
    shell.execute_command(Rubik::REPL::CommandParser.parse("!tasks"))
    assert_includes out.string, "No background tasks currently running"

    # Start a task via tool (STDOUT: $stdout would be expanded away by the
    # POSIX shell — same fixture bug as #103)
    tool = shell.tool_registry.get("manage_task")
    tool.execute("action" => "start", "command" => 'ruby -e "STDOUT.sync = true; puts %(REPL_TASK); sleep 10"')

    out.reopen
    shell.execute_command(Rubik::REPL::CommandParser.parse("!tasks"))
    assert_includes out.string, "task-1"
    assert_includes out.string, "RUNNING"

    # Kill task via REPL command
    out.reopen
    shell.execute_command(Rubik::REPL::CommandParser.parse("!tasks kill task-1"))
    assert_includes out.string, "Task 'task-1' killed."

    # Status after kill via REPL
    out.reopen
    shell.execute_command(Rubik::REPL::CommandParser.parse("!tasks status task-1"))
    assert_includes out.string, "Task: task-1"
    assert_includes out.string, "Status:   killed"

    shell.stop
  end

  def test_start_with_empty_command_raises_argument_error
    assert_raises(ArgumentError) { @task_manager.start("   ") }
    assert_raises(ArgumentError) { @task_manager.start("") }
  end

  def test_task_uptime_freezes_on_completion
    task = @task_manager.start('ruby -e "sleep 0.05"')
    deadline = Time.now + 5
    sleep 0.05 while task.running? && Time.now < deadline

    refute task.running?
    uptime1 = task.uptime
    sleep 0.1
    uptime2 = task.uptime
    assert_equal uptime1, uptime2
  end

  def test_manage_task_tool_camel_case_and_aliases
    tool = Rubik::Tools::ManageTaskTool.new(task_manager: @task_manager, guard: @guard, runtime_context: @context)

    start_res = tool.execute("action" => "start", "cmd" => 'ruby -e "sleep 5"')
    assert_includes start_res, "Task started: task-1"

    status_res = tool.execute("action" => "status", "taskId" => "task-1")
    assert_includes status_res, "Task: task-1"

    kill_res = tool.execute("action" => "kill", "taskId" => "task-1")
    assert_includes kill_res, "killed"

    kill_again = tool.execute("action" => "kill", "taskId" => "task-1")
    assert_includes kill_again, "already KILLED"
  end

  def test_inspect_runtime_tasks_target
    runtime_mgr = Rubik::Runtime::Manager.new
    runtime_mgr.context.provide(Rubik::Coeffects::TASK_MANAGER, @task_manager)
    tool = Rubik::Tools::InspectRuntimeTool.new(runtime_mgr)

    @task_manager.start('ruby -e "sleep 5"')
    res = tool.execute("target" => "tasks")
    assert_includes res, "[Background Tasks (1 Tracked)]:"
    assert_includes res, "task-1"
  end

  def test_context_dispose_triggers_kill_all
    ctx = Rubik::Runtime::Context.new
    mgr = Rubik::Runtime::TaskManager.new(guard: @guard, context: ctx)

    task = mgr.start('ruby -e "sleep 10"')
    assert task.running?

    ctx.dispose
    refute task.running?, "Context disposal must invoke kill_all inverse and stop child process"
    assert_equal :killed, task.status
  end

  # =========================================================================
  # Scoped Task-Unit Context (js-tangram ContextDisposedError incident)
  #
  # Kernel::Init#reap_dead_units! disposes a dead unit's context by
  # contract, so a ProcessUnit carrying the SHARED runtime root tore the
  # whole runtime down whenever a background task terminated: services
  # wiped, every subagent cascade-killed, and every later turn failing
  # with ContextDisposedError on the next root extend.
  # =========================================================================

  def test_process_unit_carries_scoped_child_not_shared_root
    init = Rubik::Kernel::Init.new
    manager = Rubik::Runtime::TaskManager.new(guard: @guard, context: @context, init: init)

    task = manager.start('ruby -e "exit 0"', ctx: @context)
    unit = init.get(task.id)

    refute_nil unit, "Task must register a kernel unit when an Init is available"
    assert_same @context, unit.context.parent,
                "ProcessUnit must carry a scoped child of the caller's context"
    refute_same @context, unit.context
  ensure
    manager&.kill_all
    init&.reap_dead_units!
  end

  def test_completed_task_reaping_disposes_scoped_context_and_spares_shared_root
    init = Rubik::Kernel::Init.new
    manager = Rubik::Runtime::TaskManager.new(guard: @guard, context: @context, init: init)
    @context.provide("sentinel_service", Object.new)
    baseline = @context.disposable_count

    task = manager.start('ruby -e "exit 0"', ctx: @context)
    deadline = Time.now + 5
    sleep 0.05 while task.running? && Time.now < deadline

    reaped = init.reap_dead_units!
    assert_equal [task.id], reaped.map(&:id)

    unit = init.get(task.id)
    assert_predicate unit.context, :disposed?, "Reaping must dispose the unit's own scoped context"
    refute @context.disposed?, "Reaping a dead task must never dispose the shared runtime root"
    assert @context.has?("sentinel_service"), "Root services must survive task reaping"
    assert_equal baseline, @context.disposable_count,
                 "Reap must prune the per-task scope from the root accumulator (zero-restart)"
    @context.extend # the incident signature: ContextDisposedError if the root died
  ensure
    manager&.kill_all
  end

  def test_start_on_disposed_runtime_fails_fast_without_spawning
    @context.dispose

    assert_raises(Rubik::Runtime::ContextDisposedError) do
      @task_manager.start('ruby -e "sleep 30"')
    end
    assert_empty @task_manager.list, "A failed start must not leave a spawned task behind"
  end

  def test_spawn_failure_rolls_back_the_scoped_task_context
    init = Rubik::Kernel::Init.new
    manager = Rubik::Runtime::TaskManager.new(guard: @guard, context: @context, init: init)
    baseline = @context.disposable_count

    Open3.stub(:popen3, ->(*_args) { raise Errno::ENOENT, "stubbed spawn failure" }) do
      error = assert_raises(Errno::ENOENT) do
        manager.start('ruby -e "exit 0"', ctx: @context)
      end
      assert_includes error.message, "stubbed spawn failure", "the ORIGINAL spawn error must surface"
    end

    assert_empty manager.list
    assert_equal 0, init.size, "A failed spawn must not register a kernel unit"
    assert_equal baseline, @context.disposable_count,
                 "Failed spawn must roll back the child context (cascade inverse pruned)"
  end

  def test_assembly_failure_kills_process_and_rolls_back_scope
    init = Rubik::Kernel::Init.new
    manager = Rubik::Runtime::TaskManager.new(guard: @guard, context: @context, init: init)
    baseline = @context.disposable_count

    init.stop # Init#register now raises StateError mid-assembly, after the spawn
    error = assert_raises(Rubik::Kernel::Unit::StateError) do
      manager.start('ruby -e "sleep 30"', ctx: @context)
    end
    assert_includes error.message, "stopped"

    task = manager.get("task-1")
    assert_equal :killed, task.status, "Assembly failure must kill the already-spawned process"
    assert_equal baseline, @context.disposable_count,
                 "Assembly failure must dispose the per-task child context"
  ensure
    manager&.kill_all
  end
end
