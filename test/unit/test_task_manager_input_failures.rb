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
    # Bounded wait, not a raw sleep: under parallel load the kill handshake
    # can outlast any fixed delay (issue #384).
    assert wait_until(5.0, step: 0.01) { !task.running? }

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
    # Bounded wait, not a raw-sleep poll: under parallel load the exit watcher
    # can lag any fixed deadline (issue #384).
    assert wait_until(5.0, step: 0.01) { !task.running? }
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

  class SyncBoomUnit
    def sync_state! = raise(ArgumentError, "state sync boom")
  end

  class SyncBoomInit
    def register(*) = nil

    def get(_id) = SyncBoomUnit.new
  end

  def test_completion_watcher_closes_stdin_when_state_sync_raises
    task = nil
    logged = []
    Rubik::Log.stub(:warn, ->(_subsystem, message) { logged << message }) do
      @task_manager.stub(:resolve_init, SyncBoomInit.new) do
        task = @task_manager.start('ruby -e "exit 0"')
        assert wait_until(5.0, step: 0.01) { !task.running? && task.stdin_io.closed? }
      end
    end

    assert task.stdin_io.closed?, "stdin must close even when state sync raises"
    assert(logged.any? { |message| message.include?("completion watcher") },
           "a failed state sync must be reported, not swallowed")
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

  # A child that never reads stdin (watcher, wedged build server) lets the
  # OS pipe buffer fill. send_input must give up within its deadline and
  # return false instead of parking forever — and must NOT hold the manager
  # monitor while writing, or kill/status/logs would deadlock behind it.
  def test_send_input_to_never_reading_child_returns_false_within_deadline
    task = @task_manager.start('ruby -e "sleep 30"')
    assert task.running?

    mgr_class = @task_manager.class
    mgr_class.send(:remove_const, :SEND_INPUT_TIMEOUT)
    mgr_class.const_set(:SEND_INPUT_TIMEOUT, 0.3)
    begin
      # 2 MB is far beyond the ~64KB pipe buffer, so the write must hit the
      # deadline rather than draining.
      result = @task_manager.send_input(task.id, "x" * 2_000_000)
      assert_equal false, result

      # The monitor survived: kill responds immediately afterwards.
      assert_equal true, @task_manager.kill(task.id)
      assert_equal :killed, task.status
    ensure
      mgr_class.send(:remove_const, :SEND_INPUT_TIMEOUT)
      mgr_class.const_set(:SEND_INPUT_TIMEOUT, 5.0)
    end
  end

  # Window between a successful spawn and task registration (binmode/sync/
  # Task.new): a failure there previously leaked the child — no @tasks
  # entry, no kill inverse, no at_exit coverage. The rollback must kill the
  # spawned process directly.
  def test_start_kills_spawned_child_when_task_construction_fails
    spawned_pid = nil
    real_popen3 = Open3.method(:popen3)
    stub_spawn = lambda { |*, **|
      stdin, stdout, stderr, wait_thr = real_popen3.call('ruby -e "sleep 30"')
      spawned_pid = wait_thr.pid
      [stdin, stdout, stderr, wait_thr]
    }

    Rubik::Runtime::Task.stub(:new, ->(*) { raise "task construction boom" }) do
      Open3.stub(:popen3, stub_spawn) do
        assert_raises(RuntimeError) { @task_manager.start('ruby -e "sleep 30"') }
      end
    end

    refute_nil spawned_pid
    # The child must be gone: waitpid either reaps it or reports it is not
    # our child anymore once the rollback kill landed.
    alive = -> { Process.kill(0, spawned_pid) }
    assert wait_until(5.0, step: 0.01) {
      begin
        alive.call
        false
      rescue Errno::ESRCH
        true
      end
    }
  end
end
