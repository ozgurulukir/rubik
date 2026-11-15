# frozen_string_literal: true

require "open3"
require "timeout"
require_relative "../log"

module Rubik
  module Platform
    # Process and environment management (e.g. kill_tree, popen_capture).
    # Extracted from lib/rubik/platform.rb (Plan 86 D-4).
    module Process
      def self.included(base)
        base.extend self
      end

      # Default swallowed-IO-error observer for the popen3 drain core
      # (issue #444): reader-thread deaths are now visible via Log.debug
      # (adopting the adapter variant's log-on-swallow behavior) instead of
      # being swallowed silently, while stdin-close and reader-thread kill
      # failures stay silent teardown noise, as before. Log is error-isolated,
      # so the observer itself can never raise.
      DEFAULT_ON_IO_ERROR = lambda do |event, error|
        case event
        when :stdout_read
          Rubik::Log.debug(:platform, "stdout read failed during process execution: #{error.class}: #{error.message}")
        when :stderr_read
          Rubik::Log.debug(:platform, "stderr read failed during process execution: #{error.class}: #{error.message}")
        end
      end

      # Single-homed popen3 + dual reader-thread drain core (issue #444):
      # executes a command via Open3.popen3 with timeout, concurrent
      # stdout/stderr drain (prevents the OS pipe buffer from filling and
      # deadlocking the child), signal exit status mapping, and automatic
      # process-tree termination on timeout. Consumers: sandbox drivers and
      # Rubik::Adapter::ProcessRunner, which overrides on_io_error to keep
      # its legacy Log.debug(:adapter) trace of every swallowed IO error.
      #
      # on_io_error is invoked as (event, exception) for each IO error the
      # core must swallow to keep draining: :stdin_close, :stdout_read,
      # :stderr_read, :stdout_kill, :stderr_kill. For long-lived
      # line-oriented drains (LSP stderr) use Platform::IoDrain instead;
      # this core is the synchronous capture-to-string variant.
      def popen_capture(*, timeout: 15, chdir: Dir.pwd, timeout_message: nil, error_message: nil, on_io_error: nil)
        on_io_error ||= DEFAULT_ON_IO_ERROR
        start_time = Time.now
        stdout_str = ""
        stderr_str = ""
        exit_code = 127
        pid = nil
        watchdog = nil
        deadline_hit = false

        begin
          Open3.popen3(*, chdir: chdir) do |stdin, stdout, stderr, wait_thr|
            pid = wait_thr.pid if wait_thr.respond_to?(:pid)
            # Deadline watchdog (issue #479): kill the tree from a separate
            # thread the moment the deadline fires, so a hung child never
            # outlives `timeout`. The kill must NOT ride Timeout.timeout's
            # timer thread: its unwind races the kill, and if the unwind wins,
            # popen3's ensure joins the still-running child and the timeout
            # merely relabels the result instead of bounding the wall clock.
            # Instead the watchdog kills first and sets deadline_hit, and the
            # Timeout::Error is raised only after the block has returned.
            # Cancelled in the inner ensure to keep the watchdog from firing
            # into a recycled pid after normal exit.
            watchdog = Thread.new(pid, timeout.to_f) do |w_pid, w_deadline|
              sleep w_deadline
              deadline_hit = true
              kill_tree(w_pid)
            rescue StandardError
              deadline_hit = true
              nil
            end
            begin
              stdin.close
            rescue StandardError => e
              on_io_error.call(:stdin_close, e)
            end
            t_out = Thread.new do
              stdout.read
            rescue StandardError => e
              on_io_error.call(:stdout_read, e)
              ""
            end
            t_err = Thread.new do
              stderr.read
            rescue StandardError => e
              on_io_error.call(:stderr_read, e)
              ""
            end
            begin
              stdout_str = t_out.value.to_s
              stderr_str = t_err.value.to_s
              status = wait_thr.value
              exit_code = status.exitstatus || (status.signaled? ? (128 + (status.termsig || 1)) : 1)
            ensure
              begin
                watchdog&.kill
              rescue StandardError
                nil
              end
              begin
                t_out.kill
              rescue StandardError => e
                on_io_error.call(:stdout_kill, e)
              end
              begin
                t_err.kill
              rescue StandardError => e
                on_io_error.call(:stderr_kill, e)
              end
            end
          end
          raise Timeout::Error, "execution expired" if deadline_hit
        rescue Timeout::Error
          kill_tree(pid) if pid
          stderr_str = timeout_message || "Execution timed out after #{timeout} seconds"
          exit_code = 124
        rescue Errno::ENOENT => e
          stderr_str = "Binary not found: #{e.message}"
          exit_code = 127
        rescue StandardError => e
          msg_prefix = error_message ? "#{error_message}: " : "Execution error: "
          stderr_str = "#{msg_prefix}#{e.message}"
          exit_code = 1
        end

        duration = Time.now - start_time
        {
          ok: exit_code.zero?,
          exit_code: exit_code,
          stdout: stdout_str,
          stderr: stderr_str,
          output: [stdout_str, stderr_str].reject(&:empty?).join("\n"),
          duration: duration.round(4),
          pid: pid
        }
      end

      def kill_tree(pid)
        return unless pid&.positive?

        if windows?
          begin
            # Plan 55 D-1 ile tutarlı dizi-form çağrı: cmd.exe ara katmanı ve kabuk
            # yönlendirmesi ("> NUL 2>&1") yerine out:/err: seçenekleri kullanılır.
            system("taskkill", "/F", "/T", "/PID", pid.to_s, out: File::NULL, err: File::NULL)
          rescue StandardError
            nil
          end
        else
          # On Unix/Linux, collect descendant PIDs so child processes are not
          # orphaned when the parent process is killed. TERM gets a short
          # grace window before KILL escalates: back-to-back TERM→KILL gave
          # graceful shutdown no scheduling window, so lock/file/socket
          # holders were always hard-killed.
          targets = (descendant_pids(pid) + [pid]).uniq
          signal_all(targets, "TERM")

          # Escalate to KILL for whatever is still alive once the grace
          # window lapses (or the loop observes all targets gone early).
          # ::Process, not Process: this file defines Rubik::Platform::Process,
          # which would otherwise shadow the top-level constant.
          deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + KILL_TREE_GRACE_SECONDS
          still_alive = targets
          until ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) >= deadline
            still_alive = targets.select { |tpid| process_alive?(tpid) }
            break if still_alive.empty?

            sleep 0.01
          end
          signal_all(still_alive, "KILL")
        end
      end

      KILL_TREE_GRACE_SECONDS = 0.2

      # Collect all descendant process IDs recursively (leaves first).
      def descendant_pids(pid)
        return [] unless pid&.positive?

        collected = []
        queue = [pid]
        until queue.empty?
          curr = queue.shift
          children = direct_child_pids(curr)
          children.each do |cpid|
            next if collected.include?(cpid) || cpid == pid

            collected << cpid
            queue << cpid
          end
        end
        collected.reverse
      rescue StandardError
        []
      end

      # Deadline-bounded write to a (possibly blocking) pipe: converts a
      # never-draining reader — a child that stopped reading stdin — into an
      # Errno::EPIPE raise after `timeout` seconds instead of parking the
      # caller forever on a full OS pipe buffer. Uses write_nonblock + wait,
      # so the fd's blocking flag is irrelevant. Exposed via Rubik::Platform.
      def write_until(io, text, timeout: 5.0)
        deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout.to_f
        text = text.to_s
        until text.empty?
          written = io.write_nonblock(text, exception: false)
          case written
          when :wait_writable
            remaining = deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
            raise Errno::EPIPE, "pipe write exceeded #{timeout}s deadline" if remaining <= 0

            io.wait_writable(remaining) or raise Errno::EPIPE, "pipe write exceeded #{timeout}s deadline"
          when Integer
            text = text.byteslice(written..)
          end
        end
        nil
      end

      private

      def signal_all(pids, sig)
        pids.each do |tpid|
          ::Process.kill(sig, tpid)
        rescue StandardError
          nil
        end
      end

      def process_alive?(pid)
        ::Process.kill(0, pid)
        true
      rescue StandardError
        false
      end

      def direct_child_pids(pid)
        task_dir = "/proc/#{pid}/task"
        if File.directory?(task_dir)
          pids = []
          Dir.glob("#{task_dir}/*/children").each do |path|
            content = begin
              File.read(path)
            rescue StandardError
              nil
            end
            pids.concat(content.split.map(&:to_i)) if content
          end
          return pids.reject(&:zero?) unless pids.empty?
        end

        out, = begin
          Open3.capture2("pgrep", "-P", pid.to_s, err: File::NULL)
        rescue StandardError
          [nil, nil]
        end
        return out.lines.map(&:to_i).reject(&:zero?) if out && !out.empty?

        out, = begin
          Open3.capture2("ps", "--ppid", pid.to_s, "-o", "pid=", err: File::NULL)
        rescue StandardError
          [nil, nil]
        end
        return out.lines.map(&:to_i).reject(&:zero?) if out && !out.empty?

        []
      rescue StandardError
        []
      end

      extend self
    end
  end
end
