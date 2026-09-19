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
      :id, :command, :pid, :started_at, :status, :exit_code,
      :ring_buffer, :stdin_io, :wait_thread, :collector_threads,
      keyword_init: true
    ) do
      def running?
        status == :running
      end

      def uptime
        Time.now - started_at
      end

      def to_h
        {
          id: id,
          command: command,
          pid: pid,
          started_at: started_at,
          status: status,
          exit_code: exit_code,
          uptime_seconds: uptime.round(2)
        }
      end
    end

    # Manages asynchronous long-running background processes (servers, builders,
    # watchers) with deadlock-immune streaming, AST guard verification, and
    # context-mediated LIFO rollback (AGENTS.md §1.A/B, Plan 93).
    class TaskManager
      attr_reader :guard, :context, :root_dir, :max_buffer_lines

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

      def initialize(guard: nil, context: nil, root_dir: Dir.pwd, max_buffer_lines: 500)
        @tasks = {}
        @task_counter = 0
        @monitor = Monitor.new
        @guard = guard
        @context = context
        @root_dir = File.expand_path(root_dir)
        @max_buffer_lines = max_buffer_lines
        self.class.register_instance(self)
      end

      def start(command, chdir: @root_dir, ctx: nil)
        cmd_str = command.to_s.strip
        @guard&.verify_command_safety!(cmd_str)

        task_id = nil
        @monitor.synchronize do
          @task_counter += 1
          task_id = "task-#{@task_counter}"
        end

        ring_buf = RingBuffer.new(@max_buffer_lines)
        stdin, stdout, stderr, wait_thr = Open3.popen3(cmd_str, chdir: chdir)
        stdin.binmode if stdin.respond_to?(:binmode)
        stdin.sync = true if stdin.respond_to?(:sync=)

        task = Task.new(
          id: task_id,
          command: cmd_str,
          pid: wait_thr.pid,
          started_at: Time.now,
          status: :running,
          exit_code: nil,
          ring_buffer: ring_buf,
          stdin_io: stdin,
          wait_thread: wait_thr,
          collector_threads: []
        )

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
            end
          end
          begin; stdin.close unless stdin.closed?; rescue IOError; nil; end
        end

        # Spatiotemporal composability: pair inverse by construction in Omega (AGENTS.md §1.A)
        target_ctx = ctx || @context
        target_ctx.on_dispose { kill(task.id) } if target_ctx.respond_to?(:on_dispose)

        @monitor.synchronize { @tasks[task.id] = task }
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
          return true unless task.status == :running

          task.status = :killed
          begin
            task.stdin_io&.close unless task.stdin_io&.closed?
          rescue IOError
            nil
          end
          Rubik::Platform.kill_tree(task.pid) if task.pid
          true
        end
      end

      def kill_all
        @monitor.synchronize do
          @tasks.each_key { |id| kill(id) }
        end
      end
    end
  end
end
