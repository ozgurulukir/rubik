# frozen_string_literal: true

require_relative "../test_helper"

# G13 error-path coverage: Runtime::TaskManager input/kill edge paths (audit
# 2026-09-29, item 5). send_input on a dead pipe must return false (never
# raise into the agent loop); kill on an already-finished task is a benign
# idempotent true.
class TestTaskManagerInputFailures < Minitest::Test
  def setup
    # Plan 111 F1: `ruby` is database-less and fail-closed at the command
    # gate — these tests play the operator allowlisting the interpreter.
    @guard = Rubik::Security::Guard.new(command_allowlist: ["ruby"])
    @context = Rubik::Runtime::Context.new
    @task_manager = Rubik::Runtime::TaskManager.new(guard: @guard, context: @context)
  end

  def teardown
    @task_manager&.kill_all
    @context&.dispose unless @context.disposed?
  end

  def test_send_input_on_killed_task_returns_false
    task = @task_manager.start('ruby -e "sleep 30"')
    assert task.running?
    @task_manager.kill(task.id)
    sleep 0.2

    assert_equal false, @task_manager.send_input(task.id, "too late")
  end

  def test_send_input_on_broken_pipe_returns_false_not_raise
    task = @task_manager.start('ruby -e "sleep 30"')
    assert task.running?

    # close the pipe behind the manager's back; stub closed? so the guard
    # passes and the write genuinely hits the IOError/EPIPE rescue
    task.stdin_io.close
    result = false
    task.stdin_io.stub(:closed?, false) { result = @task_manager.send_input(task.id, "into the void") }
    assert_equal false, result
  ensure
    @task_manager.kill(task.id) if task&.running?
  end

  def test_kill_on_already_completed_task_returns_true_without_touching_exit
    task = @task_manager.start("ruby -e \"exit 0\"")
    deadline = Time.now + 5
    sleep 0.05 while task.running? && Time.now < deadline
    assert_equal :completed, task.status

    assert_equal true, @task_manager.kill(task.id)
    assert_equal :completed, task.status, "kill must not rewrite a finished task's status"
  end

  def test_kill_unknown_task_id_returns_false
    assert_equal false, @task_manager.kill("no-such-task")
  end
end
