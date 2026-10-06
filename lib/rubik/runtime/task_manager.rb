# frozen_string_literal: true

require "open3"
require "monitor"
require "time"
require_relative "../platform"

module Rubik
  module Runtime
    # Bounded thread-safe ring buffer for capturing child process stdout/stderr
    # without risk of unbounded memory growth (Plan 93).
    class RingBuffer
      attr_reader :capacity

      def initialize(capacity = 500)
        @capacity = [capacity.to_i, 1].max
        @buffer = []
        @monitor = Monitor.new
      end

      def push(line)
        @monitor.synchronize do
          @buffer << line.to_s
          @buffer.shift while @buffer.size > @capacity
        end
        self
      end
      alias << push

      def tail(count = 50)
        @monitor.synchronize do
          limit = [count.to_i, 0].max
          @buffer.last(limit)
        end
      end

      def lines
        @monitor.synchronize { @buffer.dup }
      end

      def size
        @monitor.synchronize { @buffer.size }
      end

      def empty?
        @monitor.synchronize { @buffer.empty? }
      end

      def clear
        @monitor.synchronize { @buffer.clear }
      end
    end

    # Managed child process representation with lifecycle status and buffers.
    Task = Struct.new(
      :id, :command, :pid, :started_at, :ended_at, :status, :exit_code,
      :ring_buffer, :stdin_io, :wait_thread, :collector_threads,
      keyword_init: true
    ) do
      def running?
        status == :running
      end

      def uptime
        ((ended_at || Time.now) - started_at).to_f
      end

      def to_h
        {
          id: id, command: command, pid: pid, started_at: started_at,
          ended_at: ended_at, status: status, exit_code: exit_code,
          uptime_seconds: uptime.round(2)
        }
      end
    end

    # Manages asynchronous long-running background processes (servers, builders,
    # watchers) with deadlock-immune streaming, AST guard verification, and
    # context-mediated LIFO rollback (AGENTS.md §1.A/B, Plan 93).
    class TaskManager
      attr_reader :guard, :context, :root_dir, :max_buffer_lines
      attr_accessor :init

      @instances = []
      @at_exit_installed = false

      def self.register_instance(mgr)
        @instances << mgr
        return if @at_exit_installed

        @at_exit_installed = true
        at_exit do
          @instances.each(&:kill_all)
        end
      end

      def initialize(guard: nil, context: nil, root_dir: Dir.pwd, max_buffer_lines: 500, init: nil)
        @tasks = {}
        @task_counter = 0
        @monitor = Monitor.new
        @guard = guard
        @context = context
        @root_dir = File.expand_path(root_dir)
        @max_buffer_lines = max_buffer_lines
        @init = init
        self.class.register_instance(self)
        bind_context(@context)
      end

      def context=(ctx)
        @context = ctx
        bind_context(@context)
      end

      def start(command, chdir: @root_dir, ctx: nil)
        cmd_str = command.to_s.strip
        raise ArgumentError, "Command cannot be empty" if cmd_str.empty?

        @guard&.verify_command_safety!(cmd_str)

        # Each task carries its OWN child context, never the shared runtime
        # root: Kernel::Init#reap_dead_units! disposes a dead unit's context
        # by contract, so a root-carried ProcessUnit tears the whole runtime
        # down when the task terminates (services wiped, every subagent
        # cascade-killed) and the REPL then fails every turn with
        # ContextDisposedError on the next root extend. Non-Rubik duck-typed
        # hosts pass through unchanged (their #extend is Module#extend).
        parent_ctx = ctx || @context
        target_ctx = parent_ctx.is_a?(Rubik::Runtime::Context) ? parent_ctx.extend : parent_ctx

        task_id = nil
        @monitor.synchronize do
          @task_counter += 1
          task_id = "task-#{@task_counter}"
        end

        ring_buf = RingBuffer.new(@max_buffer_lines)
        begin
          stdin, stdout, stderr, wait_thr = Open3.popen3(cmd_str, chdir: chdir)
        rescue StandardError => e
          rollback_failed_start(target_ctx, nil, e)
          raise e
        end
        stdin.binmode if stdin.respond_to?(:binmode)
        stdin.sync = true if stdin.respond_to?(:sync=)

        task = Task.new(
          id: task_id,
          command: cmd_str,
          pid: wait_thr.pid,
          started_at: Time.now,
          ended_at: nil,
          status: :running,
          exit_code: nil,
          ring_buffer: ring_buf,
          stdin_io: stdin,
          wait_thread: wait_thr,
          collector_threads: []
        )

        task.collector_threads = []

        # Register before the wiring below can fail: once tracked, the task
        # stays reachable by kill/kill_all/at_exit and by the rollback
        # rescue. The registration MUST also precede the on_dispose inverse:
        # an inverse firing against an empty @tasks returns false and leaks
        # the only handle to the spawned process. (Ids are never reused —
        # @task_counter is monotonic — so the id-keyed inverse is exact.)
        @monitor.synchronize { @tasks[task.id] = task }

        begin
          t_out = Thread.new do
            stdout.each_line do |line|
              ring_buf.push(line.chomp)
            end
          rescue IOError
            nil
          ensure
            begin; stdout.close unless stdout.closed?; rescue IOError; nil; end
          end

          t_err = Thread.new do
            stderr.each_line do |line|
              ring_buf.push(line.chomp)
            end
          rescue IOError
            nil
          ensure
            begin; stderr.close unless stderr.closed?; rescue IOError; nil; end
          end

          task.collector_threads = [t_out, t_err]

          Thread.new do
            status = wait_thr.value
            @monitor.synchronize do
              if task.status == :running
                task.exit_code = status.exitstatus
                task.status = status.success? ? :completed : :failed
                task.ended_at = Time.now
              end
            end
            effective_init = @init || (target_ctx.respond_to?(:get) && Rubik::Coeffects.get(target_ctx, Rubik::Coeffects::INIT))
            effective_init&.get(task.id)&.sync_state!
            begin; stdin.close unless stdin.closed?; rescue IOError; nil; end
          end

          target_ctx.on_dispose { kill(task.id) } if target_ctx.respond_to?(:on_dispose)

          effective_init = @init || (target_ctx.respond_to?(:get) && Rubik::Coeffects.get(target_ctx, Rubik::Coeffects::INIT))
          effective_init&.register(Rubik::Kernel::ProcessUnit.new(task, task_manager: self, context: target_ctx))
        rescue StandardError => e
          rollback_failed_start(target_ctx, task.id, e)
          raise e
        end

        task
      end

      def list
        @monitor.synchronize { @tasks.values.dup }
      end

      def get(task_id)
        @monitor.synchronize { @tasks[task_id.to_s] }
      end
      alias [] get

      def status(task_id)
        task = get(task_id)
        task&.to_h
      end

      def logs(task_id, tail: 50)
        task = get(task_id)
        task&.ring_buffer&.tail(tail)
      end

      def send_input(task_id, input)
        @monitor.synchronize do
          task = @tasks[task_id.to_s]
          return false unless task && task.status == :running && task.stdin_io && !task.stdin_io.closed?

          text = input.to_s
          text += "\n" unless text.end_with?("\n")
          task.stdin_io.write(text)
          task.stdin_io.flush
          true
        rescue IOError, Errno::EPIPE
          false
        end
      end

      def kill(task_id)
        @monitor.synchronize do
          task = @tasks[task_id.to_s]
          return false unless task

          if task.status == :running
            task.status = :killed
            task.ended_at = Time.now
            begin
              task.stdin_io&.close unless task.stdin_io&.closed?
            rescue IOError
              nil
            end
            Rubik::Platform.kill_tree(task.pid) if task.pid
          end
          true
        end
      end

      def kill_all
        @monitor.synchronize do
          @tasks.each_key { |id| kill(id) }
        end
      end
      alias dispose kill_all

      private

      # Atomic rollback of a failed start (AGENTS.md §6): stop any process
      # already spawned, dispose the per-task scope, and re-raise the
      # ORIGINAL error — a rollback failure is reported (Log.warn), never
      # allowed to mask what the caller should actually debug.
      def rollback_failed_start(target_ctx, task_id, original)
        kill(task_id) if task_id
        begin
          target_ctx.dispose if target_ctx.respond_to?(:dispose)
        rescue StandardError => e
          Rubik::Log.warn(:runtime, "task spawn rollback failed: #{e.class}: #{e.message} (original error: #{original.class}: #{original.message})")
        end
      end

      def bind_context(ctx)
        return unless ctx.respond_to?(:on_dispose)

        ctx.on_dispose { kill_all }
      end
    end
  end
end
