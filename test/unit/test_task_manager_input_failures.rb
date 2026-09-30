# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "minitest/mock"

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

  # Collector fakes whose each_line and close both explode: the reader
  # threads must hit their IOError rescues and the ensure close its own,
  # without the spawn failing or leaking the failure into the caller.
  class BoomEachLineIO
    def each_line = raise IOError, "simulated closed stream"

    def closed? = false

    def close = raise IOError, "close boom"
  end

  # Wait-thread double: #value parks forever so the exit-watcher stays out
  # of the way and the task stays :running for the assertions.
  class ParkingWaiter
    def pid = 4_242_424

    def value = sleep 300

    def alive? = false
  end

  def test_collector_threads_survive_failing_streams
    task = nil
    Open3.stub(:popen3, ->(*, **) { [BoomEachLineIO.new, BoomEachLineIO.new, BoomEachLineIO.new, ParkingWaiter.new] }) do
      task = @task_manager.start('ruby -e "sleep 30"')
    end
    # Thread#value blocks until the collector exits: nil means the rescue arm
    # finished the block cleanly; a removed rescue would re-raise here.
    assert_nil task.collector_threads.first.value
    assert_nil task.collector_threads.last.value

    refute_equal :failed, task.status, "collector failures must not fail the task"
  end

  class CloseBoomIO
    def closed? = false

    def close = raise IOError, "close boom"
  end

  def test_kill_survives_stdin_close_failure
    task = @task_manager.start('ruby -e "sleep 30"')
    task.stdin_io = CloseBoomIO.new

    assert_equal true, @task_manager.kill(task.id)
    assert_equal :killed, task.status
  end
end
